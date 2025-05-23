package hxsl;
import hxsl.Debug.traceDepth in debug;
using hxsl.Ast;

private class AllocatedVar {
	public var id : Int;
	public var v : TVar;
	public var path : String;
	public var merged : Array<TVar>;
	public var kind : Null<FunctionKind>;
	public var parent : AllocatedVar;
	public var rootShaderName : String;
	public var instanceIndex : Int;
	public function new() {
	}
}

private class ShaderInfos {
	static var UID = 0;
	public var uid : Int;
	public var name : String;
	public var priority : Int;
	public var body : TExpr;
	public var usedFunctions : Array<TFunction>;
	public var deps : Map<ShaderInfos, Bool>;
	public var readMap : Map<Int,AllocatedVar>;
	public var readVars : Array<AllocatedVar>;
	public var writeMap : Map<Int,AllocatedVar>;
	public var writeVars : Array<AllocatedVar>;
	public var processed : Map<Int, Bool>;
	public var vertex : Null<Bool>;
	public var onStack : Bool;
	public var hasDiscard : Bool;
	public var hasFragDepth : Bool;
	public var isCompute : Bool;
	public var hasSyntax : Bool;
	public var marked : Null<Bool>;
	public function new(n, v) {
		this.name = n;
		this.uid = UID++;
		this.vertex = v;
		processed = new Map();
		usedFunctions = [];
		readMap = new Map();
		readVars = [];
		writeMap = new Map();
		writeVars = [];
	}
}

class Linker {

	public var allVars : Array<AllocatedVar>;
	var varMap : Map<String,AllocatedVar>;
	var curShader : ShaderInfos;
	var shaders : Array<ShaderInfos>;
	var varIdMap : Map<Int,Int>;
	var locals : Map<Int,Bool>;
	var curInstance : Int;
	var mode : hxsl.RuntimeShader.LinkMode;
	var isBatchShader : Bool;
	var debugDepth = 0;

	public function new(mode) {
		this.mode = mode;
	}

	function error( msg : String, p : Position ) : Dynamic {
		return Error.t(msg, p);
	}

	function mergeVar( path : String, v : TVar, v2 : TVar, p : Position, shaderName : String ) {
		switch( v.kind ) {
		case Global, Input, Var, Local, Output:
			// shared vars
		case Param if ( shaderName != null && v2.hasBorrowQualifier(shaderName) ):
			// Other variable attempts to borrow.
		case Param, Function:
			throw "assert";
		}
		if( v.kind != v2.kind && v.kind != Local && v2.kind != Local )
			error("'" + path + "' kind does not match : " + v.kind + " should be " + v2.kind,p);
		switch( [v.type, v2.type] ) {
		case [TStruct(fl1), TStruct(fl2)]:
			for( f1 in fl1 ) {
				var ft = null;
				for( f2 in fl2 )
					if( f1.name == f2.name ) {
						ft = f2;
						break;
					}
				// add a new field
				if( ft == null )
					fl2.push(allocVar(f1,p, shaderName).v);
				else
					mergeVar(path + "." + ft.name, f1, ft, p, shaderName);
			}
		default:
			if( !v.type.equals(v2.type) )
				error("'" + path + "' type does not match : " + v.type.toString() + " should be " + v2.type.toString(),p);
		}
	}

	function allocVar( v : TVar, p : Position, ?shaderName : String, ?path : String, ?parent : AllocatedVar ) : AllocatedVar {
		if( v.parent != null && parent == null ) {
			parent = allocVar(v.parent, p, shaderName);
			var p = parent.v;
			path = p.name;
			p = p.parent;
			while( p != null ) {
				path = p.name + "." + path;
				p = p.parent;
			}
		}
		var key = (path == null ? v.name : path + "." + v.name);
		if( v.qualifiers != null )
			for( q in v.qualifiers )
				switch( q ) {
				case Name(n): key = n;
				default:
				}
		var ukey = key.toLowerCase();
		var v2 = varMap.get(ukey);
		var vname = v.name;
		if( v2 != null ) {
			for( vm in v2.merged )
				if( vm == v )
					return v2;
			inline function isUnique( v : TVar, borrowed : Bool ) {
				return (v.kind == Param && !borrowed && !v.hasQualifier(Shared) && !isBatchShader) || v.kind == Function || ((v.kind == Var || v.kind == Local) && v.hasQualifier(Private));
			}
			if( isUnique(v, v2.v.hasBorrowQualifier(shaderName)) || isUnique(v2.v, v.hasBorrowQualifier(v2.rootShaderName)) || (v.kind == Param && v2.v.kind == Param) /* two shared : one takes priority */ ) {
				// allocate a new unique name in the shader if already in use
				var k = 2;
				while( true ) {
					var a = varMap.get(ukey + k);
					if( a == null ) break;
					for( vm in a.merged )
						if( vm == v )
							return a;
					k++;
				}
				if( v.kind == Input ) {
					// it's not allowed to rename an input var, let's rename existing var instead
					varMap.remove(ukey);
					varMap.set(ukey + k, v2);
					v2.v.name += k;
					v2.path += k;
				} else {
					vname += k;
					key += k;
					ukey += k;
				}
			} else {
				v2.merged.push(v);
				mergeVar(key, v, v2.v, p, v2.rootShaderName);
				varIdMap.set(v.id, v2.id);
				return v2;
			}
		}
		var v2 : TVar = {
			id : Tools.allocVarId(),
			name : vname,
			type : v.type,
			kind : v.kind,
			qualifiers : v.qualifiers,
			parent : parent == null ? null : parent.v,
		};
		var a = new AllocatedVar();
		a.v = v2;
		a.merged = [v];
		a.path = key;
		a.id = v2.id;
		a.parent = parent;
		a.instanceIndex = curInstance;
		a.rootShaderName = shaderName;
		allVars.push(a);
		varMap.set(ukey, a);
		switch( v2.type ) {
		case TStruct(vl):
			v2.type = TStruct([for( v in vl ) allocVar(v, p, shaderName, key, a).v]);
		default:
		}
		return a;
	}

	function mapExprVar( e : TExpr ) {
		switch( e.e ) {
		case TVar(v) if( !locals.exists(v.id) ):
			var v = allocVar(v, e.p);
			if( curShader != null && !curShader.writeMap.exists(v.id) ) {
				debug(curShader.name + " read " + v.path);
				if( !curShader.readMap.exists(v.id) ) {
					curShader.readMap.set(v.id, v);
					curShader.readVars.push(v);
				}
				// if we read a varying, force into fragment
				if( curShader.vertex == null && v.v.kind == Var ) {
					debug("Force " + curShader.name+" into fragment (use varying)");
					curShader.vertex = false;
				}
			}
			return { e : TVar(v.v), t : v.v.type, p : e.p };
		case TBinop(op, e1, e2):
			switch( [op, e1.e] ) {
			case [OpAssign | OpAssignOp(_), TGlobal(FragDepth)]:
				if( curShader != null ) {
					curShader.hasFragDepth = true;
				}
				
				var e2 = mapExprVar(e2);
				switch(e2.e) {
					case TVar(v2):
						var v2 = allocVar(v2,e2.p);
						if( !curShader.readMap.exists(v2.id) ) {
							curShader.readMap.set(v2.id, v2);
							curShader.readVars.push(v2);
						}
					default:
				}

				return { e : TBinop(op, { e : TGlobal(FragDepth),t : TFloat, p : e.p }, e2), t : e.t, p : e.p };
			case [OpAssign, TVar(v)] if( !locals.exists(v.id) ):
				var e2 = mapExprVar(e2);
				var v = allocVar(v, e1.p);
				if( curShader != null && !curShader.writeMap.exists(v.id) ) {
					debug(curShader.name + " write " + v.path);
					curShader.writeMap.set(v.id, v);
					curShader.writeVars.push(v);
				}
				// don't read the var
				return { e : TBinop(op, { e : TVar(v.v), t : v.v.type, p : e.p }, e2), t : e.t, p : e.p };
			case [OpAssign | OpAssignOp(_), (TVar(v) | TSwiz( { e : TVar(v) }, _))] if( !locals.exists(v.id) ):
				// read the var
				var e1 = mapExprVar(e1);
				var e2 = mapExprVar(e2);

				var v = allocVar(v, e1.p);
				if( curShader != null && !curShader.writeMap.exists(v.id) ) {
					// TODO : mark as partial write if SWIZ
					debug(curShader.name + " write " + v.path);
					curShader.writeMap.set(v.id, v);
					curShader.writeVars.push(v);
				}
				return { e : TBinop(op, e1, e2), t : e.t, p : e.p };
			default:
			}
		case TDiscard:
			if( curShader != null ) {
				curShader.vertex = false;
				curShader.hasDiscard = true;
			}
		case TVarDecl(v, _):
			locals.set(v.id, true);
		case TFor(v, _, _):
			locals.set(v.id, true);
		case TSyntax(target, code, args):
			var mappedArgs: Array<SyntaxArg> = [];
			for ( arg in args ) {
				var e = switch ( arg.access ) {
					case Read:
						mapExprVar(arg.e);
					case Write:
						var e = curShader != null ? mapSyntaxWrite(arg.e) : arg.e;
						mapExprVar(e);
					case ReadWrite:
						// Make sure syntax writes are appended after reads.
						var e = mapExprVar(arg.e);
						if (curShader != null) e = mapSyntaxWrite(e);
						e;
				}
				mappedArgs.push({ e: e, access: arg.access });
			}
			if ( curShader != null ) curShader.hasSyntax = true;
			return { e : TSyntax(target, code, mappedArgs), t : e.t, p : e.p };
		default:
		}
		return e.map(mapExprVar);
	}

	function mapSyntaxWrite( e : TExpr ) {
		switch ( e.e ) {
			case TVar(v):
				var v = allocVar(v, e.p);
				if( !curShader.writeMap.exists(v.id) ) {
					debug(curShader.name + " syntax write " + v.path);
					curShader.writeMap.set(v.id, v);
					curShader.writeVars.push(v);
				}
				return { e : TVar(v.v), t : v.v.type, p : e.p };
			default:
				return e.map(mapSyntaxWrite);
		}
	}

	function addShader( name : String, vertex : Null<Bool>, e : TExpr, p : Int ) {
		var s = new ShaderInfos(name, vertex);
		curShader = s;
		s.priority = p;
		s.body = mapExprVar(e);
		shaders.push(s);
		curShader = null;
		debug("Adding shader "+name+" with priority "+p);
		return s;
	}

	function sortByPriorityDesc( s1 : ShaderInfos, s2 : ShaderInfos ) {
		if( s1.priority == s2.priority )
			return s1.uid - s2.uid;
		return s2.priority - s1.priority;
	}

	function buildDependency( s : ShaderInfos, v : AllocatedVar, isWritten : Bool ) {
		var found = !isWritten;
		for( parent in shaders ) {
			if( parent == s ) {
				found = true;
				continue;
			} else if( !found )
				continue;
			if( !parent.writeMap.exists(v.id) )
				continue;
			if( s.vertex ) {
				if( parent.vertex == false )
					continue;
				if( parent.vertex == null )
					parent.vertex = true;
			}
			debug(s.name + " => " + parent.name + " (" + v.path + ")");
			s.deps.set(parent, true);
			debugDepth++;
			initDependencies(parent);
			debugDepth--;
			if( !parent.readMap.exists(v.id) )
				return;
		}
		if( v.v.kind == Var )
			error("Variable " + v.path + " required by " + s.name + " is missing initializer", null);
	}

	function initDependencies( s : ShaderInfos ) {
		if( s.deps != null )
			return;
		s.deps = new Map();
		for( r in s.readVars )
			buildDependency(s, r, s.writeMap.exists(r.id));
	}

	function collect( cur : ShaderInfos, out : Array<ShaderInfos>, vertex : Bool ) {
		if( cur.onStack )
			error("Loop in shader dependencies ("+cur.name+")", null);
		if( cur.marked == vertex )
			return;
		cur.marked = vertex;
		cur.onStack = true;
		var deps = [for( d in cur.deps.keys() ) d];
		deps.sort(sortByPriorityDesc);
		for( d in deps )
			collect(d, out, vertex);
		if( cur.vertex == null ) {
			debug("MARK " + cur.name+" " + (vertex?"vertex":"fragment"));
			cur.vertex = vertex;
		}
		if( cur.vertex == vertex ) {
			debug("COLLECT " + cur.name + " " + (vertex?"vertex":"fragment"));
			out.push(cur);
		}
		cur.onStack = false;
	}

	public function link( shadersData : Array<ShaderData> ) : ShaderData {
		debug("---------------------- LINKING -----------------------");
		varMap = new Map();
		varIdMap = new Map();
		allVars = new Array();
		shaders = [];
		locals = new Map();

		var dupShaders = [];
		shadersData = [for( i => s in shadersData ) {
			if( shadersData.indexOf(s) < i ) {
				var s2 = Clone.shaderData(s);
				dupShaders.push({ origin : s, cloned : s2 });
				s2;
			} else {
				s;
			}
		}];

		// globalize vars
		curInstance = 0;
		var outVars = [];
		for( s in shadersData ) {
			isBatchShader = mode == Batch && StringTools.startsWith(s.name,"batchShader_");
			for( v in s.vars ) {
				var v2 = allocVar(v, null, s.name);
				if( isBatchShader && v2.v.kind == Param && !StringTools.startsWith(v2.path,"Batch_") ) {
					v2.v.kind = Local;
					if ( v2.v.qualifiers == null )
						v2.v.qualifiers = [];
					v2.v.qualifiers.push(Flat);
				}
				if( v.kind == Output ) outVars.push(v);
			}
			for( f in s.funs ) {
				var v = allocVar(f.ref, f.expr.p);
				v.kind = f.kind;
			}
			curInstance++;
		}

		// create shader segments
		var priority = 0;
		var initPrio = {
			init : [-3000],
			vert : [-2000],
			frag : [-1000],
			main : [-2500],
		};
		var shaderOffset = {
			vert : -1500,
			frag : -500,
		}
		for( s in shadersData ) {
			for( f in s.funs ) {
				var v = allocVar(f.ref, f.expr.p);
				if( v.kind == null ) throw "assert";
				switch( v.kind ) {
				case Vertex, Fragment:
					if( mode == Compute )
						throw "Unexpected "+v.kind.getName().toLowerCase()+"() function in compute shader";
					var offset = v.kind == Vertex ? shaderOffset.vert : shaderOffset.frag;
					addShader(s.name + "." + (v.kind == Vertex ? "vertex" : "fragment"), v.kind == Vertex, f.expr, priority + offset);
				case Main:
					if( mode != Compute )
						throw "Unexpected main() outside compute shader";
					addShader(s.name, true, f.expr, priority).isCompute = true;
				case Init:
					var prio : Array<Int>;
					var status : Null<Bool> = switch( f.ref.name ) {
					case "__init__vertex": prio = initPrio.vert; true;
					case "__init__fragment": prio = initPrio.frag; false;
					case "__init__main": prio = initPrio.main; false;
					default: prio = initPrio.init; null;
					}
					switch( f.expr.e ) {
					case TBlock(el):
						var index = 0;
						for( e in el )
							addShader(s.name+"."+f.ref.name+(index++),status,e, prio[0]++);
					default:
						addShader(s.name+"."+f.ref.name,status,f.expr, prio[0]++);
					}
				case Helper:
					throw "Unexpected helper function in linker "+v.v.name;
				}
			}
			priority++;
		}
		shaders.sort(sortByPriorityDesc);

		var uid = 0;
		for( s in shaders )
			s.uid = uid++;

		#if shader_debug_dump
		for( s in shaders )
			debug("Found shader "+s.name+":"+s.uid);
		#end

		// build dependency tree
		var entry = new ShaderInfos("<entry>", false);
		entry.deps = new Map();
		for( v in outVars )
			buildDependency(entry, allocVar(v,null), false);

		// force shaders containing discard to be included
		for( s in shaders )
			if( s.hasDiscard || s.isCompute || s.hasFragDepth) {
				initDependencies(s);
				entry.deps.set(s, true);
			}

		// force shaders reading only params into fragment shader
		// (pixelColor = color with no effect in BaseMesh)
		for( s in shaders ) {
			if( s.vertex != null ) continue;
			var onlyParams = true;
			for( r in s.readVars )
				if( r.v.kind != Param ) {
					onlyParams = false;
					break;
				}
			if( onlyParams ) {
				debug("Force " + s.name + " into fragment since it only reads params");
				s.vertex = false;
			}
		}

		for( s in shaders ) {
			if ( s.deps == null)
				continue;
			// propagate fragment flag
			if( s.vertex == null )
				for( d in s.deps.keys() )
					if( d.vertex == false ) {
						debug(s.name + " marked as fragment because of " + d.name);
						s.vertex = false;
						break;
					}
			// propagate vertex flag
			if( s.vertex )
				for( d in s.deps.keys() )
					if( d.vertex == null ) {
						debug(d.name + " marked as vertex because of " + s.name);
						d.vertex = true;
					}
		}

		// collect needed dependencies
		var v = [], f = [];
		collect(entry, v, true);
		collect(entry, f, false);
		if( f.pop() != entry ) throw "assert";

		// check that all dependencies are matched
		for( s in shaders )
			s.marked = null;
		for( s in v.concat(f) ) {
			for( d in s.deps.keys() )
				if( d.marked == null )
					error(d.name + " needed by " + s.name + " is unreachable", null);
			s.marked = true;
		}

		// build resulting vars
		var outVars = [];
		var varMap = new Map();
		function addVar(v:AllocatedVar) {
			if( varMap.exists(v.id) )
				return;
			varMap.set(v.id, true);
			if( v.v.parent != null )
				addVar(v.parent);
			else
				outVars.push(v.v);
		}
		for( s in v.concat(f) ) {
			for( v in s.readVars )
				addVar(v);
			for( v in s.writeVars )
				addVar(v);
		}
		// cleanup unused structure vars
		function cleanVar( v : TVar ) {
			switch( v.type ) {
			case TStruct(vl) if( v.kind != Input ):
				var vout = [];
				for( v in vl )
					if( varMap.exists(v.id) ) {
						cleanVar(v);
						vout.push(v);
					}
				v.type = TStruct(vout);
			default:
			}
		}
		for( v in outVars )
			cleanVar(v);
		// build resulting shader functions
		function build(kind, name, a:Array<ShaderInfos> ) : TFunction {
			var v : TVar = {
				id : Tools.allocVarId(),
				name : name,
				type : TFun([ { ret : TVoid, args : [] } ]),
				kind : Function,
			};
			outVars.push(v);
			var exprs = [];
			for( s in a )
				switch( s.body.e ) {
				case TBlock(el):
					for( e in el ) exprs.push(e);
				default:
					exprs.push(s.body);
				}
			var expr = { e : TBlock(exprs), t : TVoid, p : exprs.length == 0 ? null : exprs[0].p };
			return {
				kind : kind,
				ref : v,
				ret : TVoid,
				args : [],
				expr : expr,
			};
		}
		var funs = mode == Compute ? [build(Main,"main",v)] : [
			build(Vertex, "vertex", v),
			build(Fragment, "fragment", f),
		];

		// make sure the first merged var is the original for duplicate shaders
		for( d in dupShaders ) {
			for( i in 0...d.cloned.vars.length )
				allocVar(d.cloned.vars[i],null).merged.unshift(d.origin.vars[i]);
		}

		return { name : "out", vars : outVars, funs : funs };
	}

}