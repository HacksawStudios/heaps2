package hxd.fmt.fbx;
using hxd.fmt.fbx.Data;
import h3d.col.Point;

enum AnimationMode {
	FrameAnim;
	LinearAnim;
}

class TmpObject {
	public var index : Int;
	public var model : FbxNode;
	public var parent : TmpObject;
	public var isJoint : Bool;
	public var isMesh : Bool;
	public var childs : Array<TmpObject>;
	#if !(dataOnly || macro)
	public var obj : h3d.scene.Object;
	public var joint : h3d.anim.Skin.Joint;
	#end
	public function new() {
		childs = [];
	}
}

private class AnimCurve {
	public var def : DefaultMatrixes;
	public var object : String;
	public var t : { t : Array<Float>, x : Array<Float>, y : Array<Float>, z : Array<Float> };
	public var r : { t : Array<Float>, x : Array<Float>, y : Array<Float>, z : Array<Float> };
	public var s : { t : Array<Float>, x : Array<Float>, y : Array<Float>, z : Array<Float> };
	public var a : { t : Array<Float>, v : Array<Float> };
	public var uv : Array<{ t : Float, u : Float, v : Float }>;
	public function new(def, object) {
		this.def = def;
		this.object = object;
	}
}

class DefaultMatrixes {
	public var trans : Null<Point>;
	public var scale : Null<Point>;
	public var rotate : Null<Point>;
	public var preRot : Null<Point>;
	public var wasRemoved : Null<Int>;

	public function new() {
	}

	public static inline function rightHandToLeft( m : h3d.Matrix ) {
		// if [x,y,z] is our original point and M the matrix
		// in right hand we have [x,y,z] * M = [x',y',z']
		// we need to ensure that left hand matrix convey the x axis flip,
		// in order to have [-x,y,z] * M = [-x',y',z']
		m._12 *= -1;
		m._13 *= -1;
		m._21 *= -1;
		m._31 *= -1;
		m._41 *= -1;
	}

	public function toMatrix(leftHand) {
		var m = new h3d.Matrix();
		m.identity();
		if( scale != null ) m.scale(scale.x, scale.y, scale.z);
		if( rotate != null ) m.rotate(rotate.x, rotate.y, rotate.z);
		if( preRot != null ) m.rotate(preRot.x, preRot.y, preRot.z);
		if( trans != null ) m.translate(trans.x, trans.y, trans.z);
		if( leftHand ) rightHandToLeft(m);
		return m;
	}

}

class BaseLibrary {

	var root : FbxNode;
	var ids : Map<Int,FbxNode>;
	var connect : Map<Int,Array<Int>>;
	var namedConnect : Map<Int,Map<String,Int>>;
	var invConnect : Map<Int,Array<Int>>;
	var leftHand : Bool;
	var defaultModelMatrixes : Map<String,DefaultMatrixes>;
	var uvAnims : Map<String, Array<{ t : Float, u : Float, v : Float }>>;

	/**
		Allows to prevent some terminal unskinned joints to be removed, for instance if we want to track their position
	**/
	public var keepJoints : Map<String,Bool>;

	/**
		Allows to skip some objects from being processed as if they were not part of the FBX
	**/
	public var skipObjects : Map<String,Bool>;

	/**
		Set how many bones per vertex should be created in skin data in makeObject(). Default is 3
	**/
	public var bonesPerVertex = 3;

	/**
		If there are too many bones, the model will be split in separate render passes.
	**/
	public var maxBonesPerSkin = 34;

	/**
		Consider unskinned joints to be simple objects
	**/
	public var unskinnedJointsAsObjects : Bool;

	public var allowVertexColor : Bool = true;

	public function new() {
		root = { name : "Root", props : [], childs : [] };
		keepJoints = new Map();
		skipObjects = new Map();
		reset();
	}

	function reset() {
		ids = new Map();
		connect = new Map();
		namedConnect = new Map();
		invConnect = new Map();
		defaultModelMatrixes = new Map();
	}

	public function loadTextFile( data : String ) {
		load(Parser.parse(data));
	}

	public function load( root : FbxNode ) {
		reset();
		this.root = root;
		for( c in root.childs )
			init(c);
	}

	public function loadXtra( data : String ) {
		var xml = Xml.parse(data).firstElement();
		if( uvAnims == null ) uvAnims = new Map();
		for( e in new haxe.xml.Fast(xml).elements ) {
			var obj = e.att.name;
			var frames = [for( f in e.elements ) { var f = f.innerData.split(" ");  { t : Std.parseFloat(f[0]) * 9622116.25, u : Std.parseFloat(f[1]), v : Std.parseFloat(f[2]) }} ];
			uvAnims.set(obj, frames);
		}
	}

	function convertPoints( a : Array<Float> ) {
		var p = 0;
		for( i in 0...Std.int(a.length / 3) ) {
			a[p] = -a[p]; // inverse X axis
			p += 3;
		}
	}

	public function leftHandConvert() {
		if( leftHand ) return;
		leftHand = true;
		for( g in root.getAll("Objects.Geometry") ) {
			for( v in g.getAll("Vertices") )
				convertPoints(v.getFloats());
			for( v in g.getAll("LayerElementNormal.Normals") )
				convertPoints(v.getFloats());
		}
	}

	function init( n : FbxNode ) {
		switch( n.name ) {
		case "Connections":
			for( c in n.childs ) {
				if( c.name != "C" )
					continue;
				var child = c.props[1].toInt();
				var parent = c.props[2].toInt();
				var name = c.props[3];

				var c = connect.get(parent);
				if( c == null ) {
					c = [];
					connect.set(parent, c);
				}
				c.push(child);

				if( name != null ) {
					var nc = namedConnect.get(parent);
					if( nc == null ) {
						nc = new Map();
						namedConnect.set(parent, nc);
					}
					nc.set(name.toString(), child);
				}

				if( parent == 0 )
					continue;

				var c = invConnect.get(child);
				if( c == null ) {
					c = [];
					invConnect.set(child, c);
				}
				c.push(parent);
			}
		case "Objects":
			for( c in n.childs )
				ids.set(c.getId(), c);
		default:
		}
	}

	public function getGeometry( name : String = "" ) {
		var geom = null;
		for( g in root.getAll("Objects.Geometry") )
			if( g.hasProp(PString("Geometry::" + name)) ) {
				geom = g;
				break;
			}
		if( geom == null )
			throw "Geometry " + name + " not found";
		return new Geometry(this, geom);
	}

	public function getParent( node : FbxNode, nodeName : String, ?opt : Bool ) {
		var p = getParents(node, nodeName);
		if( p.length > 1 )
			throw node.getName() + " has " + p.length + " " + nodeName + " parents "+[for( o in p ) o.getName()].join(",");
		if( p.length == 0 && !opt )
			throw "Missing " + node.getName() + " " + nodeName + " parent";
		return p[0];
	}

	public function getChild( node : FbxNode, nodeName : String, ?opt : Bool ) {
		var c = getChilds(node, nodeName);
		if( c.length > 1 )
			throw node.getName() + " has " + c.length + " " + nodeName + " childs "+[for( o in c ) o.getName()].join(",");
		if( c.length == 0 && !opt )
			throw "Missing " + node.getName() + " " + nodeName + " child";
		return c[0];
	}

	public function getSpecChild( node : FbxNode, name : String ) {
		var nc = namedConnect.get(node.getId());
		if( nc == null )
			return null;
		var id = nc.get(name);
		if( id == null )
			return null;
		return ids.get(id);
	}

	public function getChilds( node : FbxNode, ?nodeName : String ) {
		var c = connect.get(node.getId());
		var subs = [];
		if( c != null )
			for( id in c ) {
				var n = ids.get(id);
				if( n == null ) throw id + " not found";
				if( nodeName != null && n.name != nodeName ) continue;
				subs.push(n);
			}
		return subs;
	}

	public function getParents( node : FbxNode, ?nodeName : String ) {
		var c = invConnect.get(node.getId());
		var pl = [];
		if( c != null )
			for( id in c ) {
				var n = ids.get(id);
				if( n == null ) throw id + " not found";
				if( nodeName != null && n.name != nodeName ) continue;
				pl.push(n);
			}
		return pl;
	}

	public function getRoot() {
		return root;
	}

	public function ignoreMissingObject( name : String ) {
		var def = defaultModelMatrixes.get(name);
		if( def == null ) {
			def = new DefaultMatrixes();
			def.wasRemoved = -1;
			defaultModelMatrixes.set(name, def);
		}
	}

	function buildHierarchy() {
		// init objects
		var oroot = new TmpObject();
		var objects = new Array<TmpObject>();
		var hobjects = new Map<Int, TmpObject>();

		hobjects.set(0, oroot);
		for( model in root.getAll("Objects.Model") ) {
			if( skipObjects.get(model.getName()) )
				continue;
			var mtype = model.getType();
			var isJoint = mtype == "LimbNode" && (!unskinnedJointsAsObjects || !isNullJoint(model));
			var o = new TmpObject();
			o.model = model;
			o.isJoint = isJoint;
			o.isMesh = mtype == "Mesh";
			hobjects.set(model.getId(), o);
			objects.push(o);
		}

		// build hierarchy
		for( o in objects ) {
			var p = getParent(o.model, "Model", true);
			var pid = if( p == null ) 0 else p.getId();
			var op = hobjects.get(pid);
			if( op == null ) op = oroot; // if parent has been removed
			op.childs.push(o);
			o.parent = op;
		}

		// propagates joint flags
		var changed = true;
		while( changed ) {
			changed = false;
			for( o in objects ) {
				if( o.isJoint || o.isMesh ) continue;
				if( o.parent.isJoint ) {
					o.isJoint = true;
					changed = true;
					continue;
				}
				var hasJoint = false;
				for( c in o.childs )
					if( c.isJoint ) {
						hasJoint = true;
						break;
					}
				if( hasJoint )
					for( c in o.parent.childs )
						if( c.isJoint ) {
							o.isJoint = true;
							changed = true;
							break;
						}
			}
		}
		return { root : oroot, objects : objects };
	}

	function getObjectCurve( curves : Map < Int, AnimCurve > , model : FbxNode, curveName : String, animName : String ) : AnimCurve {
		var c = curves.get(model.getId());
		if( c != null )
			return c;
		var name = model.getName();
		if( skipObjects.get(name) )
			return null;
		// if it's an empty model with no sub nodes, let's ignore it (ex : Camera)
		if( model.getType() == "Null" && getChilds(model, "Model").length == 0 )
			return null;
		var def = defaultModelMatrixes.get(name);
		if( def == null )
			throw "Object "+name+" used in anim "+animName+" was not found in library";
		// if it's a move animation on a terminal unskinned joint, let's skip it
		if( def.wasRemoved != null ) {
			if( curveName != "Visibility" && curveName != "UV" )
				return null;
			// apply it on the skin instead
			model = ids.get(def.wasRemoved);
			name = model.getName();
			c = curves.get(def.wasRemoved);
			def = defaultModelMatrixes.get(name);
			// todo : change behavior not to remove the mesh but the skin instead!
			if( def == null ) throw "assert";
		}
		if( c == null ) {
			c = new AnimCurve(def, name);
			curves.set(model.getId(), c);
		}
		return c;
	}


	public function mergeModels( modelNames : Array<String> ) {
		if( modelNames.length == 0 )
			return;
		var models = root.getAll("Objects.Model");
		function getModel(name) {
			for( m in models )
				if( m.getName() == name )
					return m;
			throw "Model not found " + name;
			return null;
		}
		var m = getModel(modelNames[0]);
		var geom = new Geometry(this, getChild(m, "Geometry"));
		var def = getChild(geom.getRoot(), "Deformer", true);
		var subDefs = getChilds(def, "Deformer");
		for( i in 1...modelNames.length ) {
			var name = modelNames[i];
			var m2 = getModel(name);
			var geom2 = new Geometry(this, getChild(m2, "Geometry"));
			var vcount = Std.int(geom.getVertices().length / 3);

			skipObjects.set(name, true);

			// merge materials
			var mindex = [];
			var materials = getChilds(m, "Material");
			for( mat in getChilds(m2, "Material") ) {
				var idx = materials.indexOf(mat);
				if( idx < 0 ) {
					idx = materials.length;
					materials.push(mat);
					addLink(m, mat);
				}
				mindex.push(idx);
			}

			// merge geometry
			geom.merge(geom2, mindex);

			// merge skinning
			var def2 = getChild(geom2.getRoot(), "Deformer", true);
			if( def2 != null ) {
				if( def == null ) throw m.getName() + " does not have a deformer but " + name + " has one";
				for( subDef in getChilds(def2, "Deformer") ) {
					var subModel = getChild(subDef, "Model");
					var prevDef = null;
					for( s in subDefs )
						if( getChild(s, "Model") == subModel ) {
							prevDef = s;
							break;
						}

					if( prevDef != null )
						removeLink(subDef, subModel);

					var idx = subDef.get("Indexes", true);
					if( idx == null ) continue;

					if( prevDef == null ) {
						addLink(def, subDef);
						removeLink(def2, subDef);
						subDefs.push(subDef);
						var idx = idx.getInts();
						for( i in 0...idx.length )
							idx[i] += vcount;
					} else {
						var pidx = prevDef.get("Indexes").getInts();
						for( i in idx.getInts() )
							pidx.push(i + vcount);
						var weights = prevDef.get("Weights").getFloats();
						for( w in subDef.get("Weights").getFloats() )
							weights.push(w);
					}
				}
			}
		}
	}

	function addLink( parent : FbxNode, child : FbxNode ) {
		var pid = parent.getId();
		var nid = child.getId();
		connect.get(pid).push(nid);
		invConnect.get(nid).push(pid);
	}

	function removeLink( parent : FbxNode, child : FbxNode ) {
		var pid = parent.getId();
		var nid = child.getId();
		connect.get(pid).remove(nid);
		invConnect.get(nid).remove(pid);
	}


	public function loadAnimation( mode : AnimationMode, ?animName : String, ?root : FbxNode, ?lib : BaseLibrary ) : h3d.anim.Animation {
		if( lib != null ) {
			lib.defaultModelMatrixes = defaultModelMatrixes;
			return lib.loadAnimation(mode,animName);
		}
		if( root != null ) {
			var l = new BaseLibrary();
			l.load(root);
			if( leftHand ) l.leftHandConvert();
			l.defaultModelMatrixes = defaultModelMatrixes;
			return l.loadAnimation(mode,animName);
		}
		var animNode = null;
		for( a in this.root.getAll("Objects.AnimationStack") )
			if( animName == null || a.getName()	== animName ) {
				if( animName == null )
					animName = a.getName();
				animNode = getChild(a, "AnimationLayer");
				break;
			}
		if( animNode == null ) {
			if( animName != null )
				throw "Animation not found " + animName;
			if( uvAnims == null )
				return null;
		}

		var curves = new Map();
		var P0 = new Point();
		var P1 = new Point(1, 1, 1);
		var F = Math.PI / 180;
		var allTimes = new Map();

		if( animNode != null ) for( cn in getChilds(animNode, "AnimationCurveNode") ) {
			var model = getParent(cn, "Model",true);
			if(model==null) continue; //morph support

			var c = getObjectCurve(curves, model, cn.getName(), animName);
			if( c == null ) continue;
			var data = getChilds(cn, "AnimationCurve");
			var cname = cn.getName();
			// collect all the timestamps
			var times = data[0].get("KeyTime").getFloats();
			for( i in 0...times.length ) {
				var t = times[i];
				// fix rounding error
				if( t % 100 != 0 ) {
					t += 100 - (t % 100);
					times[i] = t;
				}
				// this should give significant-enough key
				var it = Std.int(t / 200000);
				allTimes.set(it, t);
			}
			// handle special curves
			if( data.length != 3 ) {
				switch( cname ) {
				case "Visibility":
					c.a = {
						v : data[0].get("KeyValueFloat").getFloats(),
						t : times,
					};
					continue;
				default:
				}
				throw model.getName()+"."+cname + " has " + data.length + " curves";
			}
			// handle TRS curves
			var data = {
				x : data[0].get("KeyValueFloat").getFloats(),
				y : data[1].get("KeyValueFloat").getFloats(),
				z : data[2].get("KeyValueFloat").getFloats(),
				t : times,
			};
			// this can happen when resampling anims due to rounding errors, let's ignore it for now
			//if( data.y.length != times.length || data.z.length != times.length )
			//	throw "Unsynchronized curve components on " + model.getName()+"."+cname+" (" + data.x.length + "/" + data.y.length + "/" + data.z.length + ")";
			// optimize empty animations out
			var E = 1e-10, M = 1.0;
			var def = switch( cname ) {
			case "T": if( c.def.trans == null ) P0 else c.def.trans;
			case "R": M = F; if( c.def.rotate == null ) P0 else c.def.rotate;
			case "S": if( c.def.scale == null ) P1 else c.def.scale;
			default:
				throw "Unknown curve " + model.getName()+"."+cname;
			}
			var hasValue = false;
			for( v in data.x )
				if( v*M < def.x-E || v*M > def.x+E ) {
					hasValue = true;
					break;
				}
			if( !hasValue ) {
				for( v in data.y )
					if( v*M < def.y-E || v*M > def.y+E ) {
						hasValue = true;
						break;
					}
			}
			if( !hasValue ) {
				for( v in data.z )
					if( v*M < def.z-E || v*M > def.z+E ) {
						hasValue = true;
						break;
					}
			}
			// no meaningful value found
			if( !hasValue )
				continue;
			switch( cname ) {
			case "T": c.t = data;
			case "R": c.r = data;
			case "S": c.s = data;
			default: throw "assert";
			}
		}

		// process UVs
		if( uvAnims != null ) {
			var modelByName = new Map();
			for( obj in this.root.getAll("Objects.Model") )
				modelByName.set(obj.getName(), obj);
			for( obj in uvAnims.keys() ) {
				var frames = uvAnims.get(obj);
				var model = modelByName.get(obj);
				if( model == null ) throw "Missing model '" + obj + "' requires by UV animation";
				var c = getObjectCurve(curves, model, "UV", animName);
				if( c == null ) continue;
				c.uv = frames;
				for( f in frames )
					allTimes.set(Std.int(f.t / 200000), f.t);
			}
		}

		var allTimes = [for( a in allTimes ) a];
		allTimes.sort(sortDistinctFloats);
		var maxTime = allTimes[allTimes.length - 1];
		var minDT = maxTime;
		var curT = allTimes[0];
		for( i in 1...allTimes.length ) {
			var t = allTimes[i];
			var dt = t - curT;
			if( dt < minDT ) minDT = dt;
			curT = t;
		}
		var numFrames = maxTime == 0 ? 1 : 1 + Std.int((maxTime - allTimes[0]) / minDT);
		var sampling = 15.0 / (minDT / 3079077200); // this is the DT value we get from Max when using 15 FPS export

		switch( mode ) {
		case FrameAnim:
			var anim = new h3d.anim.FrameAnimation(animName, numFrames, sampling);

			for( c in curves ) {
				var frames = c.t == null && c.r == null && c.s == null ? null : new haxe.ds.Vector(numFrames);
				var alpha = c.a == null ? null : new haxe.ds.Vector(numFrames);
				var uvs = c.uv == null ? null : new haxe.ds.Vector(numFrames * 2);
				// skip empty curves
				if( frames == null && alpha == null && uvs == null )
					continue;
				var ctx = c.t == null ? null : c.t.x;
				var cty = c.t == null ? null : c.t.y;
				var ctz = c.t == null ? null : c.t.z;
				var ctt = c.t == null ? [-1.] : c.t.t;
				var crx = c.r == null ? null : c.r.x;
				var cry = c.r == null ? null : c.r.y;
				var crz = c.r == null ? null : c.r.z;
				var crt = c.r == null ? [-1.] : c.r.t;
				var csx = c.s == null ? null : c.s.x;
				var csy = c.s == null ? null : c.s.y;
				var csz = c.s == null ? null : c.s.z;
				var cst = c.s == null ? [ -1.] : c.s.t;
				var cav = c.a == null ? null : c.a.v;
				var cat = c.a == null ? null : c.a.t;
				var cuv = c.uv;
				var def = c.def;
				var tp = 0, rp = 0, sp = 0, ap = 0, uvp = 0;
				var curMat = null;
				for( f in 0...numFrames ) {
					var changed = curMat == null;
					if( allTimes[f] == ctt[tp] ) {
						changed = true;
						tp++;
					}
					if( allTimes[f] == crt[rp] ) {
						changed = true;
						rp++;
					}
					if( allTimes[f] == cst[sp] ) {
						changed = true;
						sp++;
					}
					if( changed ) {
						var m = new h3d.Matrix();
						m.identity();
						if( c.s == null || sp == 0 ) {
							if( def.scale != null )
								m.scale(def.scale.x, def.scale.y, def.scale.z);
						} else
							m.scale(csx[sp-1], csy[sp-1], csz[sp-1]);

						if( c.r == null || rp == 0 ) {
							if( def.rotate != null )
								m.rotate(def.rotate.x, def.rotate.y, def.rotate.z);
						} else
							m.rotate(crx[rp-1] * F, cry[rp-1] * F, crz[rp-1] * F);

						if( def.preRot != null )
							m.rotate(def.preRot.x, def.preRot.y, def.preRot.z);

						if( c.t == null || tp == 0 ) {
							if( def.trans != null )
								m.translate(def.trans.x, def.trans.y, def.trans.z);
						} else
							m.translate(ctx[tp-1], cty[tp-1], ctz[tp-1]);

						if( leftHand )
							DefaultMatrixes.rightHandToLeft(m);

						curMat = m;
					}
					if( frames != null )
						frames[f] = curMat;
					if( alpha != null ) {
						if( allTimes[f] == cat[ap] )
							ap++;
						alpha[f] = cav[ap - 1];
					}
					if( uvs != null ) {
						if( allTimes[f] == cuv[uvp].t )
							uvp++;
						uvs[f<<1] = cuv[uvp - 1].u;
						uvs[(f<<1)|1] = cuv[uvp - 1].v;
					}
				}

				if( frames != null )
					anim.addCurve(c.object, frames);
				if( alpha != null )
					anim.addAlphaCurve(c.object, alpha);
				if( uvs != null )
					anim.addUVCurve(c.object, uvs);
			}
			return anim;

		case LinearAnim:

			var anim = new h3d.anim.LinearAnimation(animName, numFrames, sampling);
			var q = new h3d.Quat(), q2 = new h3d.Quat();

			for( c in curves ) {
				var frames = c.t == null && c.r == null && c.s == null ? null : new haxe.ds.Vector(numFrames);
				var alpha = c.a == null ? null : new haxe.ds.Vector(numFrames);
				var uvs = c.uv == null ? null : new haxe.ds.Vector(numFrames * 2);
				// skip empty curves
				if( frames == null && alpha == null && uvs == null )
					continue;
				var ctx = c.t == null ? null : c.t.x;
				var cty = c.t == null ? null : c.t.y;
				var ctz = c.t == null ? null : c.t.z;
				var ctt = c.t == null ? [-1.] : c.t.t;
				var crx = c.r == null ? null : c.r.x;
				var cry = c.r == null ? null : c.r.y;
				var crz = c.r == null ? null : c.r.z;
				var crt = c.r == null ? [-1.] : c.r.t;
				var csx = c.s == null ? null : c.s.x;
				var csy = c.s == null ? null : c.s.y;
				var csz = c.s == null ? null : c.s.z;
				var cst = c.s == null ? [ -1.] : c.s.t;
				var cav = c.a == null ? null : c.a.v;
				var cat = c.a == null ? null : c.a.t;
				var cuv = c.uv;
				var def = c.def;
				var tp = 0, rp = 0, sp = 0, ap = 0, uvp = 0;
				var curFrame = null;
				for( f in 0...numFrames ) {
					var changed = curFrame == null;
					if( allTimes[f] == ctt[tp] ) {
						changed = true;
						tp++;
					}
					if( allTimes[f] == crt[rp] ) {
						changed = true;
						rp++;
					}
					if( allTimes[f] == cst[sp] ) {
						changed = true;
						sp++;
					}
					if( changed ) {
						var f = new h3d.anim.LinearAnimation.LinearFrame();
						if( c.s == null || sp == 0 ) {
							if( def.scale != null ) {
								f.sx = def.scale.x;
								f.sy = def.scale.y;
								f.sz = def.scale.z;
							} else {
								f.sx = 1;
								f.sy = 1;
								f.sx = 1;
							}
						} else {
							f.sx = csx[sp - 1];
							f.sy = csy[sp - 1];
							f.sz = csz[sp - 1];
						}

						if( c.r == null || rp == 0 ) {
							if( def.rotate != null ) {
								q.initRotate(def.rotate.x, def.rotate.y, def.rotate.z);
							} else
								q.identity();
						} else
							q.initRotate(crx[rp-1] * F, cry[rp-1] * F, crz[rp-1] * F);

						if( def.preRot != null ) {
							q2.initRotate(def.preRot.x, def.preRot.y, def.preRot.z);
							q.multiply(q,q2);
						}

						f.qx = q.x;
						f.qy = q.y;
						f.qz = q.z;
						f.qw = q.w;

						if( c.t == null || tp == 0 ) {
							if( def.trans != null ) {
								f.tx = def.trans.x;
								f.ty = def.trans.y;
								f.tz = def.trans.z;
							} else {
								f.tx = 0;
								f.ty = 0;
								f.tz = 0;
							}
						} else {
							f.tx = ctx[tp - 1];
							f.ty = cty[tp - 1];
							f.tz = ctz[tp - 1];
						}

						if( leftHand ) {
							f.tx *= -1;
							f.qy *= -1;
							f.qz *= -1;
						}

						curFrame = f;
					}
					if( frames != null )
						frames[f] = curFrame;
					if( alpha != null ) {
						if( allTimes[f] == cat[ap] )
							ap++;
						alpha[f] = cav[ap - 1];
					}
					if( uvs != null ) {
						if( uvp < cuv.length && allTimes[f] == cuv[uvp].t )
							uvp++;
						uvs[f<<1] = cuv[uvp - 1].u;
						uvs[(f<<1)|1] = cuv[uvp - 1].v;
					}
				}

				if( frames != null )
					anim.addCurve(c.object, frames, c.r != null || def.rotate != null, c.s != null || def.scale != null);
				if( alpha != null )
					anim.addAlphaCurve(c.object, alpha);
				if( uvs != null )
					anim.addUVCurve(c.object, uvs);
			}
			return anim;

		}
	}

	function sortDistinctFloats( a : Float, b : Float ) {
		return if( a > b ) 1 else -1;
	}

	function isNullJoint( model : FbxNode ) {
		if( getParents(model, "Deformer").length > 0 )
			return false;
		var parent = getParent(model, "Model", true);
		if( parent == null )
			return true;
		var t = parent.getType();
		if( t == "LimbNode" || t == "Root" )
			return false;
		return true;
	}

	function getModelPath( model : FbxNode ) {
		var parent = getParent(model, "Model", true);
		var name = model.getName();
		if( parent == null )
			return name;
		return getModelPath(parent) + "." + name;
	}

	function autoMerge() {
		// if we have multiple deformers on the same joint, let's merge the geometries
		var toMerge = [], mergeGroups = new Map<Int,Array<FbxNode>>();
		for( model in root.getAll("Objects.Model") ) {
			if( skipObjects.get(model.getName()) )
				continue;
			var mtype = model.getType();
			var isJoint = mtype == "LimbNode" && (!unskinnedJointsAsObjects || !isNullJoint(model));
			if( !isJoint ) continue;
			var deformers = getParents(model, "Deformer");
			if( deformers.length <= 1 ) continue;
			var group = [];
			for( d in deformers ) {
				var def = getParent(d, "Deformer");
				if( def == null ) continue;
				var geom = getParent(def, "Geometry");
				if( geom == null ) continue;
				var model2 = getParent(geom, "Model");
				if( model2 == null ) continue;
				var id = model2.getId();
				var g = mergeGroups.get(id);
				if( g != null ) {
					for( g in g ) {
						group.remove(g);
						group.push(g);
					}
					toMerge.remove(g);
				}
				group.remove(model2);
				group.push(model2);
				mergeGroups.set(id, group);
			}
			toMerge.push(group);
		}
		for( group in toMerge ) {
			group.sort(function(m1, m2) return Reflect.compare(m1.getName(), m2.getName()));
			mergeModels([for( g in group ) g.getName()]);
		}
	}

	function keepJoint( j : h3d.anim.Skin.Joint ) {
		return keepJoints.get(j.name);
	}

	function createSkin( hskins : Map<Int,h3d.anim.Skin>, hgeom : Map<Int,#if (dataOnly || macro) {function getVerticesCount():Int;function setSkin(s:h3d.anim.Skin):Void;} #else h3d.prim.FBXModel #end>, rootJoints : Array<h3d.anim.Skin.Joint>, bonesPerVertex ) {
		var allJoints = [];
		function collectJoints(j:h3d.anim.Skin.Joint) {
			// collect subs first (allow easy removal of terminal unskinned joints)
			for( j in j.subs )
				collectJoints(cast j);
			allJoints.push(j);
		}
		for( j in rootJoints )
			collectJoints(j);
		var skin = null;
		var geomTrans = null;
		var iterJoints = allJoints.copy();
		for( j in iterJoints ) {
			var jModel = ids.get(j.index);
			var subDef = getParent(jModel, "Deformer", true);
			var defMat = defaultModelMatrixes.get(jModel.getName());
			j.defMat = defMat.toMatrix(leftHand);

			if( subDef == null ) {
				// if we have skinned subs, we need to keep in joint hierarchy
				if( j.subs.length > 0 || keepJoint(j) )
					continue;
				// otherwise we're an ending bone, we can safely be removed
				if( j.parent == null )
					rootJoints.remove(j);
				else
					j.parent.subs.remove(j);
				allJoints.remove(j);
				// ignore key frames for this joint
				defMat.wasRemoved = -1;
				continue;
			}
			// create skin
			if( skin == null ) {
				var def = getParent(subDef, "Deformer");
				skin = hskins.get(def.getId());
				// shared skin between same instances
				if( skin != null )
					return skin;
				var geom = hgeom.get(getParent(def, "Geometry").getId());
				skin = new h3d.anim.Skin(geom.getVerticesCount(), bonesPerVertex);
				geom.setSkin(skin);
				hskins.set(def.getId(), skin);
			}
			j.transPos = h3d.Matrix.L(subDef.get("Transform").getFloats());
			if( leftHand ) DefaultMatrixes.rightHandToLeft(j.transPos);

			var weights = subDef.getAll("Weights");
			if( weights.length > 0 ) {
				var weights = weights[0].getFloats();
				var vertex = subDef.get("Indexes").getInts();
				for( i in 0...vertex.length ) {
					var w = weights[i];
					if( w < 0.01 )
						continue;
					skin.addInfluence(vertex[i], j, w);
				}
			}
		}
		if( skin == null )
			throw "No joint is skinned ("+[for( j in iterJoints ) j.name].join(",")+")";
		allJoints.reverse();
		for( i in 0...allJoints.length )
			allJoints[i].index = i;
		skin.setJoints(allJoints, rootJoints);
		skin.initWeights();
		return skin;
	}

	function getDefaultMatrixes( model : FbxNode ) {
		var d = new DefaultMatrixes();
		var F = Math.PI / 180;
		for( p in model.getAll("Properties70.P") )
			switch( p.props[0].toString() ) {
			case "GeometricTranslation":
				// handle in Geometry directly
			case "PreRotation":
				d.preRot = new Point(p.props[4].toFloat() * F, p.props[5].toFloat() * F, p.props[6].toFloat() * F);
			case "Lcl Rotation":
				d.rotate = new Point(p.props[4].toFloat() * F, p.props[5].toFloat() * F, p.props[6].toFloat() * F);
			case "Lcl Translation":
				d.trans = new Point(p.props[4].toFloat(), p.props[5].toFloat(), p.props[6].toFloat());
			case "Lcl Scaling":
				d.scale = new Point(p.props[4].toFloat(), p.props[5].toFloat(), p.props[6].toFloat());
			default:
			}
		defaultModelMatrixes.set(model.getName(), d);
		return d;
	}

}
