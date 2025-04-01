package h3d.scene;
class BatchData {

	public var paramsCount : Int;
	public var maxInstance : Int;
	public var matIndex : Int;
	public var indexCount : Int;
	public var indexStart : Int;
	public var instanceBuffers : Array<h3d.impl.InstanceBuffer>;
	public var buffers : Array<h3d.Buffer> = [];
	public var bufferFormat : hxd.BufferFormat;
	public var data : hxd.FloatBuffer;
	public var params : hxsl.RuntimeShader.AllocParam;
	public var shader : hxsl.BatchShader;
	public var shaders : Array<hxsl.Shader>;
	public var pass : h3d.mat.Pass;
	public var computePass : h3d.mat.Pass;
	public var commandBuffers : Array<h3d.Buffer>;
	public var countBuffers : Array<h3d.Buffer>;
	public var next : BatchData;

	public function new() {
	}

}

class MeshBatchPart {
	public var indexStart : Int;
	public var indexCount : Int;
	public var lodIndexStart : Array<Int>;
	public var lodIndexCount : Array<Int>;
	public var lodConfig : Array<Float>;
	public var baseVertex : Int;
	public var bounds : h3d.col.Bounds;
	public function new() {
	}

	public function clone() {
		var cl = new MeshBatchPart();
		cl.indexStart = indexStart;
		cl.indexCount = indexCount;
		cl.lodIndexStart = lodIndexStart;
		cl.lodIndexCount = lodIndexCount;
		cl.lodConfig = lodConfig;
		cl.baseVertex = baseVertex;
		cl.bounds = bounds;
		return cl;
	}
}

enum MeshBatchFlag {
	EnableGpuCulling;
	EnableLod;
	EnableResizeDown;
	EnableGpuUpdate;
	EnableStorageBuffer;
}

/**
	h3d.scene.MeshBatch allows to draw multiple meshed in a single draw call.
	See samples/MeshBatch.hx for an example.
**/
class MeshBatch extends MultiMaterial {

	static var modelViewID = hxsl.Globals.allocID("global.modelView");
	static var modelViewInverseID = hxsl.Globals.allocID("global.modelViewInverse");
	static var previousModelViewID = hxsl.Globals.allocID("global.previousModelView");
	static var MAX_BUFFER_ELEMENTS = 4096;
	static var MAX_STORAGE_BUFFER_ELEMENTS = 128 * 1024 * 1024 >> 2;
	static var BATCH_START_FMT = hxd.BufferFormat.make([{ name : "Batch_Start", type : DFloat }]);

	var instanced : h3d.prim.Instanced;
	var dataPasses : BatchData;
	var needUpload = false;
	var instancedParams : hxsl.Cache.BatchInstanceParams;

	// used if gpu lod or gpu culling
	static var INDIRECT_DRAW_ARGUMENTS_FMT = hxd.BufferFormat.make([{ name : "", type : DVec4 }, { name : "", type : DFloat }]);
	static var INSTANCE_OFFSETS_FMT = hxd.BufferFormat.make([{ name : "", type : DFloat }]);
	
	var matInfos : h3d.Buffer;
	var emittedSubParts : Array<MeshBatchPart>;
	var currentSubParts : Int;
	var currentMaterialOffset : Int;
	var instanceOffsetsCpu : haxe.io.Bytes;
	var instanceOffsetsGpu : h3d.Buffer;
	var subPartsInfos : h3d.Buffer;
	var countBytes : haxe.io.Bytes;

	/**
		Set if shader list or shader constants has changed, before calling begin()
	**/
	public var shadersChanged = true;

	/**
		The number of instances on this batch
	**/
	public var instanceCount(default,null) : Int = 0;

	/**
	 * 	If set, use this position in emitInstance() instead MeshBatch absolute position
	**/
	public var worldPosition : Matrix;
	var invWorldPosition : Matrix;

	/**
		Tells the mesh batch to draw only a subpart of the primitive
	**/
	public var primitiveSubPart : MeshBatchPart;
	var primitiveSubBytes : haxe.io.Bytes;

	/**
		If set, exact bounds will be recalculated during emitInstance (default true)
	**/
	public var calcBounds = true;

	/**
	 * If set, this distance is used to compute screen ratio and lod on all the instances this frame
	 */
	public var lodDistance : Float;

	/**
	 * If set, and gpu update is enabled, clip all instanced behind this distance.
	 */
	public var maxDistance : Float = -1;

	public var meshBatchFlags(default, null) : haxe.EnumFlags<MeshBatchFlag>;

	public function new( primitive, ?material, ?parent ) {
		instanced = new h3d.prim.Instanced();
		instanced.commands = new h3d.impl.InstanceBuffer();
		instanced.setMesh(primitive);
		super(instanced, material == null ? null : [material], parent);
		for( p in this.material.getPasses() )
			@:privateAccess p.batchMode = true;
	}

	function gpuLodEnabled() return meshBatchFlags.has(EnableLod);
	function gpuCullingEnabled() return meshBatchFlags.has(EnableGpuCulling);
	function storageBufferEnabled() return meshBatchFlags.has(EnableStorageBuffer);
	function mustCalcBufferFormat() return meshBatchFlags.has(EnableGpuUpdate) || gpuCullingEnabled() || gpuLodEnabled();

	public function begin( emitCountTip = -1, ?flags : haxe.EnumFlags<MeshBatchFlag> ) {
		if ( flags != null ) {
			#if (!js && !(hldx && !dx12))
			var allowedLOD = flags.has(EnableLod) && ( primitiveSubPart != null || @:privateAccess instanced.primitive.lodCount() > 1 );
			flags.setTo(EnableLod, allowedLOD);
			#else
			flags.setTo(EnableLod, false);
			flags.setTo(EnableGpuCulling, false);
			#end
			// Set flags non-related to shaders
			meshBatchFlags.setTo( EnableResizeDown, flags.has(EnableResizeDown) );
			if ( meshBatchFlags != flags )
				shadersChanged = true;
			meshBatchFlags = flags;
			meshBatchFlags.setTo( EnableStorageBuffer, mustCalcBufferFormat() || storageBufferEnabled() );
		}

		instanceCount = 0;
		instanced.initBounds();
		if( shadersChanged ) {
			initShadersMapping();
			shadersChanged = false;
		}

		if( emitCountTip < 0 )
			emitCountTip = 128;
		var p = dataPasses;
		var alloc = hxd.impl.Allocator.get();
		while( p != null ) {
			var size = emitCountTip * p.paramsCount * 4;
			if( p.data == null || p.data.length < size || ( meshBatchFlags.has(EnableResizeDown) && p.data.length > size << 1) ) {
				if( p.data != null ) alloc.disposeFloats(p.data);
				p.data = alloc.allocFloats(size);
			}
			p = p.next;
		}
		if ( primitiveSubPart != null && ( gpuCullingEnabled() || gpuLodEnabled() ) && instanceOffsetsCpu == null ) {
			var size = emitCountTip * 2 * 4;
			instanceOffsetsCpu = haxe.io.Bytes.alloc(size);
		}
	}

	function initShadersMapping() {
		var scene = getScene();
		if( scene == null ) return;
		cleanPasses();
		for( index in 0...materials.length ) {
			var mat = materials[index];
			if( mat == null ) continue;
			var matCount = @:privateAccess instanced.primitive.getMaterialIndexCount(index);
			var matStart = @:privateAccess instanced.primitive.getMaterialIndexStart(index);
			for( p in mat.getPasses() ) @:privateAccess {
				var ctx = scene.renderer.getPassByName(p.name);
				if( ctx == null ) throw "Could't find renderer pass "+p.name;

				var output = ctx.output;
				var shaders = p.getShadersRec();
				var rt = output.compileShaders(scene.ctx.globals, shaders, Default);
				var shader = output.shaderCache.makeBatchShader(rt, shaders, instancedParams);

				var b = new BatchData();
				b.indexCount = matCount;
				b.indexStart = matStart;
				b.paramsCount = shader.paramsSize;
				b.maxInstance = Std.int( ( storageBufferEnabled() ? MAX_STORAGE_BUFFER_ELEMENTS : MAX_BUFFER_ELEMENTS ) / b.paramsCount);
				b.bufferFormat = hxd.BufferFormat.VEC4_DATA;
				if( b.maxInstance <= 0 )
					throw "Mesh batch shaders needs at least one perInstance parameter";
				b.params = shader.params;
				b.shader = shader;
				b.pass = p;
				b.matIndex = index;
				b.shaders = [null/*link shader*/];
				p.dynamicParameters = true;
				p.batchMode = true;

				if( mustCalcBufferFormat() ) {
					var pl = [];
					var p = b.params;
					while( p != null ) {
						pl.push(p);
						p = p.next;
					}
					pl.sort(function(p1,p2) return p1.pos - p2.pos);
					var fmt : Array<hxd.BufferFormat.BufferInput> = [];
					var curPos = 0;
					var paddingIndex = 0;
					for( p in pl ) {
						var paddingSize = p.pos - curPos;
						if ( paddingSize > 0 ) {
							var paddingType : hxsl.Ast.Type = switch ( paddingSize ) {
							case 0:
								TFloat;
							case 1,2,3:
								TVec(paddingSize, VFloat);
							default:
								throw "Buffer has padding";
							}
							var t = hxd.BufferFormat.InputFormat.fromHXSL(paddingType);
							fmt.push(new hxd.BufferFormat.BufferInput("padding_"+paddingIndex,t));
							paddingIndex++;
							curPos = p.pos;
						}
						var name = p.name;
						var prev = fmt.length;
						switch( p.type ) {
						case TMat3:
							for( i in 0...3 )
								fmt.push(new hxd.BufferFormat.BufferInput(name+"__m"+i,DVec3));
						case TMat3x4:
							for( i in 0...3 )
								fmt.push(new hxd.BufferFormat.BufferInput(name+"__m"+i,DVec4));
						case TMat4:
							for( i in 0...4 )
								fmt.push(new hxd.BufferFormat.BufferInput(name+"__m"+i,DVec4));
						default:
							var t = hxd.BufferFormat.InputFormat.fromHXSL(p.type);
							fmt.push(new hxd.BufferFormat.BufferInput(p.name,t));
						}
						for( i in prev...fmt.length )
							curPos += fmt[i].getBytesSize() >> 2;
					}
					if ( curPos & 3 != 0)
						throw "Buffer has padding";
					b.bufferFormat = hxd.BufferFormat.make(fmt);
				}

				b.next = dataPasses;
				dataPasses = b;

				var sl = shaders;
				while( sl != null ) {
					b.shaders.push(sl.s);
					sl = sl.next;
				}
				shader.Batch_UseStorage = storageBufferEnabled();
				shader.Batch_Count = storageBufferEnabled() ? 0 : b.maxInstance * b.paramsCount;
				shader.Batch_HasOffset = primitiveSubPart != null || gpuLodEnabled() || gpuCullingEnabled();
				shader.constBits = (shader.Batch_Count << 2) | (shader.Batch_UseStorage ? ( 1 << 1 ) : 0) | (shader.Batch_HasOffset ? 1 : 0);
				shader.updateConstants(null);
			}
		}

		// add batch shaders
		var p = dataPasses;
		while( p != null ) {
			@:privateAccess p.pass.addSelfShader(p.shader);
			p = p.next;
		}
	}

	public function emitInstance() {
		if( worldPosition == null ) syncPos();
		var ps = primitiveSubPart;
		if( ps != null ) @:privateAccess {
			if(calcBounds) {
				instanced.tmpBounds.load(primitiveSubPart.bounds);
				instanced.tmpBounds.transform(worldPosition == null ? absPos : worldPosition);
				instanced.bounds.add(instanced.tmpBounds);
			}
			if ( gpuLodEnabled() || gpuCullingEnabled() ) {
				if (emittedSubParts == null) {
					currentSubParts = 0;
					currentMaterialOffset = 0;
					emittedSubParts = [ primitiveSubPart.clone() ];
				} else {
					var currentIndexStart = emittedSubParts[currentSubParts].indexStart;
					if ( currentIndexStart != primitiveSubPart.indexStart  ) {
						currentSubParts = -1;
						currentIndexStart = primitiveSubPart.indexStart;
						currentMaterialOffset = 0;
						for ( i => part in emittedSubParts ) {
							if ( part.indexStart == currentIndexStart ) {
								currentSubParts = i;
								break;
							}
							currentMaterialOffset += part.lodIndexCount.length + 1;
						}
						if ( currentSubParts < 0 ) {
							currentSubParts = emittedSubParts.length;
							emittedSubParts.push( primitiveSubPart.clone() );
						}
					}
				}
				var maxInstanceID = ( instanceCount + 1 ) * 2;
				if ( instanceOffsetsCpu.length < maxInstanceID * 4 ) {
					var next = haxe.io.Bytes.alloc(Std.int(instanceOffsetsCpu.length*3/2));
					next.blit(0, instanceOffsetsCpu, 0, instanceOffsetsCpu.length);
					instanceOffsetsCpu = next;
				}
				instanceOffsetsCpu.setInt32((instanceCount * 2 + 0) * 4, currentMaterialOffset);
				instanceOffsetsCpu.setInt32((instanceCount * 2 + 1) * 4, currentSubParts);
			} else {
				if( primitiveSubBytes == null ) {
					primitiveSubBytes = haxe.io.Bytes.alloc(128);
					instanced.commands = null;
				}
				if( primitiveSubBytes.length < (instanceCount+1) * 20 ) {
					var next = haxe.io.Bytes.alloc(Std.int(primitiveSubBytes.length*3/2));
					next.blit(0, primitiveSubBytes, 0, instanceCount * 20);
					primitiveSubBytes = next;
				}
				var p = instanceCount * 20;
				primitiveSubBytes.setInt32(p, ps.indexCount);
				primitiveSubBytes.setInt32(p + 4, 1);
				primitiveSubBytes.setInt32(p + 8, ps.indexStart);
				primitiveSubBytes.setInt32(p + 12, ps.baseVertex);
				primitiveSubBytes.setInt32(p + 16, 0);
			}
		} else if (calcBounds)
			instanced.addInstanceBounds(worldPosition == null ? absPos : worldPosition);
		var p = dataPasses;
		while( p != null ) {
			syncData(p);
			p = p.next;
		}
		instanceCount++;
	}

	override function sync(ctx:RenderContext) {
		super.sync(ctx);
		if( instanceCount == 0 ) return;
		flush();
	}

	public function flush() {
		var p = dataPasses;
		var alloc = hxd.impl.Allocator.get();
		var psBytes = primitiveSubBytes;

		var prim = @:privateAccess instanced.primitive;
		var hmd = Std.downcast(prim, h3d.prim.HMDModel);
		var materialCount = materials.length;
		var lodCount = ( gpuLodEnabled() ) ? prim.lodCount() : 1;

		if ( gpuLodEnabled() || gpuCullingEnabled() ) {
			if ( emittedSubParts != null ) {
				var upload = needUpload;
				var vertex = instanceCount * 2;
				if ( instanceOffsetsGpu == null || instanceOffsetsGpu.isDisposed() || vertex > instanceOffsetsGpu.vertices ) {
					if ( instanceOffsetsGpu != null)
						alloc.disposeBuffer( instanceOffsetsGpu );
					instanceOffsetsGpu = alloc.allocBuffer( vertex, INSTANCE_OFFSETS_FMT, UniformReadWrite );
					upload = true;
				}
				if ( upload )
					instanceOffsetsGpu.uploadBytes( instanceOffsetsCpu, 0, vertex );

				if ( matInfos == null ) {
					materialCount = 0;
					var tmpSubPartInfos = alloc.allocFloats( 2 * emittedSubParts.length );
					var pos = 0;
					for ( subPart in emittedSubParts ) {
						var lodCount = subPart.lodIndexCount.length + 1;
						tmpSubPartInfos[pos++] = lodCount;
						tmpSubPartInfos[pos++] = subPart.bounds.dimension() * 0.5;
						materialCount += lodCount;
					}
					subPartsInfos = alloc.ofFloats( tmpSubPartInfos, hxd.BufferFormat.VEC4_DATA, Uniform );
					alloc.disposeFloats(tmpSubPartInfos);

					var tmpMatInfos = alloc.allocFloats( 4 * ( materialCount + emittedSubParts.length ) );
					pos = 0;
					for ( subPart in emittedSubParts ) {
						var maxLod = subPart.lodIndexCount.length;
						var lodConfig = subPart.lodConfig;
						tmpMatInfos[pos++] = subPart.indexCount;
						tmpMatInfos[pos++] = subPart.indexStart;
						tmpMatInfos[pos++] = ( 0 < lodConfig.length ) ? lodConfig[0] : 0.0;
						tmpMatInfos[pos++] = ( maxLod < lodConfig.length && maxLod > 0 ) ? lodConfig[lodConfig.length - 1] : 0.0;
						for ( i in 0...maxLod ) {
							tmpMatInfos[pos++] = subPart.lodIndexCount[i];
							tmpMatInfos[pos++] = subPart.lodIndexStart[i];
							tmpMatInfos[pos++] = ( i + 1 < lodConfig.length ) ? lodConfig[i + 1] : 0.0;
							pos++;
						}
					}

					matInfos = alloc.ofFloats( tmpMatInfos, hxd.BufferFormat.VEC4_DATA, Uniform );
					alloc.disposeFloats(tmpMatInfos);
				}
			} else if ( matInfos == null ) {
				if ( gpuLodEnabled() ) {
					var tmpMatInfos = alloc.allocFloats( 4 * materialCount * lodCount );
					matInfos = alloc.allocBuffer( materialCount * lodCount, hxd.BufferFormat.VEC4_DATA, Uniform );
					var lodConfig = hmd.getLodConfig();
					var startIndex : Int = 0;
					var lodConfigHasCulling = lodConfig.length > lodCount - 1;
					var minScreenRatioCulling = lodConfigHasCulling ? lodConfig[lodConfig.length-1] : 0.0;
					for ( i => lod in @:privateAccess hmd.lods ) {
						for ( j in 0...materialCount ) {
							var indexCount = lod.indexCounts[j];
							var matIndex = i + j * lodCount;
							tmpMatInfos[matIndex * 4 + 0] = indexCount;
							tmpMatInfos[matIndex * 4 + 1] = startIndex;
							tmpMatInfos[matIndex * 4 + 2] = ( i < lodConfig.length ) ? lodConfig[i] : 0.0;
							tmpMatInfos[matIndex * 4 + 3] = minScreenRatioCulling;
							startIndex += indexCount;
						}
					}
					matInfos.uploadFloats( tmpMatInfos, 0, materialCount * lodCount );
					alloc.disposeFloats( tmpMatInfos );
				} else {
					var tmpMatInfos = alloc.allocFloats( 4 * materialCount );
					matInfos = alloc.allocBuffer( materialCount, hxd.BufferFormat.VEC4_DATA, Uniform );
					var pos : Int = 0;
					for ( i in 0...materials.length ) {
						tmpMatInfos[pos++] = prim.getMaterialIndexCount(i);
						tmpMatInfos[pos++] = prim.getMaterialIndexStart(i);
						pos += 2;
					}
					matInfos.uploadFloats( tmpMatInfos, 0, materialCount );
					alloc.disposeFloats( tmpMatInfos );
				}
			}
		}

		while( p != null ) {
			var index = 0;
			var start = 0;
			while( start < instanceCount ) {
				var upload = needUpload;
				var buf = p.buffers[index];
				var count = instanceCount - start;
				if( count > p.maxInstance )
					count = p.maxInstance;

				var maxVertexCount = ( mustCalcBufferFormat() ) ? p.maxInstance : ( storageBufferEnabled() ? MAX_STORAGE_BUFFER_ELEMENTS : MAX_BUFFER_ELEMENTS );
				var vertexCount = Std.int( count * (( 4 * p.paramsCount ) / p.bufferFormat.stride) );
				var vertexCountAllocated = #if js Std.int( MAX_BUFFER_ELEMENTS * 4 / p.bufferFormat.stride ) #else hxd.Math.imin( hxd.Math.nextPOT( vertexCount ), maxVertexCount ) #end;

				if( buf == null || buf.isDisposed() || buf.vertices < vertexCountAllocated ) {
					var bufferFlags : hxd.impl.Allocator.BufferFlags = storageBufferEnabled() ? UniformReadWrite : UniformDynamic;
					if ( buf != null )
						alloc.disposeBuffer(buf);
					buf = alloc.allocBuffer( vertexCountAllocated, p.bufferFormat,bufferFlags );
					p.buffers[index] = buf;
					upload = true;
				}
				if( upload )
					buf.uploadFloats(p.data, start * p.paramsCount * 4, vertexCount);
				if( psBytes != null ) {
					if( p.instanceBuffers == null )
						p.instanceBuffers = [];
					var buf = p.instanceBuffers[index];
					if ( buf != null && buf.commandCount != count ) {
						buf.dispose();
						buf = null;
					}
					if( buf == null ) {
						buf = new h3d.impl.InstanceBuffer();
						var sub = psBytes.sub(start*20,count*20);
						for( i in 0...count )
							sub.setInt32(i*20+16, i);
						buf.setBuffer(count, sub);
						p.instanceBuffers[index] = buf;
					}
				}

				var commandCountAllocated = hxd.Math.imin( hxd.Math.nextPOT( count ), p.maxInstance );

				if ( gpuLodEnabled() || gpuCullingEnabled() ) {
					if ( p.commandBuffers == null) {
						p.commandBuffers = [];
						p.countBuffers = [];
					}
					var buf = p.commandBuffers[index];
					var cbuf = p.countBuffers[index];
					if ( buf == null ) {
						buf = alloc.allocBuffer( commandCountAllocated, INDIRECT_DRAW_ARGUMENTS_FMT, UniformReadWrite );
						cbuf = alloc.allocBuffer( 1, hxd.BufferFormat.VEC4_DATA, UniformReadWrite );
						p.commandBuffers[index] = buf;
						p.countBuffers[index] = cbuf;
					}
					else if ( buf.vertices < commandCountAllocated ) {
						alloc.disposeBuffer( buf );
						buf = alloc.allocBuffer( commandCountAllocated, INDIRECT_DRAW_ARGUMENTS_FMT, UniformReadWrite );
						p.commandBuffers[index] = buf;
					}
				}
				start += count;
				index++;
			}
			if ( ( gpuLodEnabled() || gpuCullingEnabled() ) ) {
				var computeShader;
				if( p.computePass == null ) {
					computeShader = new h3d.shader.InstanceIndirect();
					var computePass = new h3d.mat.Pass("batchUpdate");
					computePass.addShader(computeShader);
					addComputeShaders(computePass);
					p.computePass = computePass;
				} else {
					computeShader = p.computePass.getShader(h3d.shader.InstanceIndirect);
				}

				computeShader.ENABLE_LOD = gpuLodEnabled();
				computeShader.ENABLE_CULLING = gpuCullingEnabled();
				computeShader.ENABLE_DISTANCE_CLIPPING = maxDistance >= 0;
				computeShader.radius = prim.getBounds().dimension() * 0.5;
				computeShader.maxDistance = maxDistance;
				computeShader.matInfos = matInfos;
				computeShader.lodCount = lodCount;
				computeShader.materialCount = materialCount;
				computeShader.MAX_MATERIAL_COUNT = 16;
				while ( materialCount * lodCount > computeShader.MAX_MATERIAL_COUNT )
					computeShader.MAX_MATERIAL_COUNT = computeShader.MAX_MATERIAL_COUNT + 16;

				if ( emittedSubParts != null ) {
					computeShader.USING_SUB_PART = true;
					computeShader.subPartCount = emittedSubParts.length;
					computeShader.subPartInfos = subPartsInfos;
					computeShader.instanceOffsets = instanceOffsetsGpu;
					computeShader.MAX_SUB_PART_BUFFER_ELEMENT_COUNT = 16;
					var maxSubPartsElement = hxd.Math.ceil( emittedSubParts.length / 2 );
					while ( maxSubPartsElement > computeShader.MAX_SUB_PART_BUFFER_ELEMENT_COUNT )
						computeShader.MAX_SUB_PART_BUFFER_ELEMENT_COUNT = computeShader.MAX_SUB_PART_BUFFER_ELEMENT_COUNT + 16;
				}
			}
			while( p.buffers.length > index )
				alloc.disposeBuffer( p.buffers.pop() );
			p = p.next;
		}
		if( psBytes != null || gpuLodEnabled() || gpuCullingEnabled() ) {
			var offsets = @:privateAccess instanced.primitive.resolveBuffer("Batch_Start");
			if( offsets == null || offsets.vertices < instanceCount || offsets.isDisposed() ) {
				if( offsets != null ) {
					offsets.dispose();
					@:privateAccess instanced.primitive.removeBuffer(offsets);
				}
				var tmp = haxe.io.Bytes.alloc(4 * instanceCount);
				for( i in 0...instanceCount )
					tmp.setFloat(i<<2, i);
				offsets = new h3d.Buffer(instanceCount, BATCH_START_FMT);
				offsets.uploadBytes(tmp,0,instanceCount);
				@:privateAccess instanced.primitive.addBuffer(offsets);
			}
		}
		needUpload = false;
	}

	function syncData( batch : BatchData ) {

		var startPos = batch.paramsCount * instanceCount << 2;
		// in case we are bigger than emitCountTip
		if( startPos + (batch.paramsCount<<2) > batch.data.length )
			batch.data.grow(batch.data.length << 1);

		var p = batch.params;
		var buf = batch.data;
		var shaders = batch.shaders;

		var calcInv = false;
		while( p != null ) {
			var pos = startPos + p.pos;
			inline function addMatrix(m:h3d.Matrix) {
				buf[pos++] = m._11;
				buf[pos++] = m._21;
				buf[pos++] = m._31;
				buf[pos++] = m._41;
				buf[pos++] = m._12;
				buf[pos++] = m._22;
				buf[pos++] = m._32;
				buf[pos++] = m._42;
				buf[pos++] = m._13;
				buf[pos++] = m._23;
				buf[pos++] = m._33;
				buf[pos++] = m._43;
				buf[pos++] = m._14;
				buf[pos++] = m._24;
				buf[pos++] = m._34;
				buf[pos++] = m._44;
			}
			if( p.perObjectGlobal != null ) {
				if ( p.perObjectGlobal.gid == modelViewID ) {
					addMatrix(worldPosition != null ? worldPosition : absPos);
				} else if ( p.perObjectGlobal.gid == modelViewInverseID ) {
					if( worldPosition == null )
						addMatrix(getInvPos());
					else {
						if( !calcInv ) {
							calcInv = true;
							if( invWorldPosition == null ) invWorldPosition = new h3d.Matrix();
							invWorldPosition.initInverse(worldPosition);
						}
						addMatrix(invWorldPosition);
					}
				} else if ( p.perObjectGlobal.gid == previousModelViewID )
					addMatrix( worldPosition != null ? worldPosition : absPos );
				else
					throw "Unsupported global param "+p.perObjectGlobal.path;
				p = p.next;
				continue;
			}
			var curShader = shaders[p.instance];
			switch( p.type ) {
			case TVec(size, _):
				switch( size ) {
				case 2:
					var v : h3d.Vector = curShader.getParamValue(p.index);
					buf[pos++] = v.x;
					buf[pos++] = v.y;
				case 3:
					var v : h3d.Vector = curShader.getParamValue(p.index);
					buf[pos++] = v.x;
					buf[pos++] = v.y;
					buf[pos++] = v.z;
				case 4:
					var v : h3d.Vector4 = curShader.getParamValue(p.index);
					buf[pos++] = v.x;
					buf[pos++] = v.y;
					buf[pos++] = v.z;
					buf[pos++] = v.w;
				}
			case TFloat:
				buf[pos++] = curShader.getParamFloatValue(p.index);
			case TMat4:
				var m : h3d.Matrix = curShader.getParamValue(p.index);
				addMatrix(m);
			default:
				throw "Unsupported batch type "+p.type;
			}
			p = p.next;
		}
		needUpload = true;
	}

	override function emit(ctx:RenderContext) {
		if( instanceCount == 0 ) return;
		calcScreenRatio(ctx);
		var p = dataPasses;
		while( p != null ) {
			var pass = p.pass;

			// check that the pass is still enable
			var material = materials[p.matIndex];
			if( material != null && material.getPass(pass.name) != null ) {
				var emittedCount = 0;
				for( i => buf in p.buffers ) {
					ctx.emitPass(pass, this).index = i | (p.matIndex << 16);
					if ( p.commandBuffers != null && p.commandBuffers.length > 0 ) {
						var count = hxd.Math.imin( instanceCount - p.maxInstance * i, p.maxInstance);
						var computeShader = p.computePass.getShader(h3d.shader.InstanceIndirect);
						if ( gpuCullingEnabled() )
							computeShader.frustum = ctx.getCameraFrustumBuffer();
						computeShader.instanceData = buf;
						computeShader.matIndex = p.matIndex;
						computeShader.commandBuffer = p.commandBuffers[i];
						if ( countBytes == null ) {
							countBytes = haxe.io.Bytes.alloc(4*4);
							countBytes.setInt32(0, 0);
						}
						p.countBuffers[i].uploadBytes(countBytes, 0, 1);
						computeShader.countBuffer = p.countBuffers[i];
						computeShader.startInstanceOffset = emittedCount;
						computeShader.ENABLE_COUNT_BUFFER = isCountBufferAllowed();
						ctx.computeList(@:privateAccess p.computePass.shaders);
						ctx.computeDispatch(count);
						emittedCount += count;
					}
				}
			}
			p = p.next;
		}
	}

	override function draw(ctx:RenderContext) {
		var p = dataPasses;
		while( true ) {
			if( p.pass == ctx.drawPass.pass ) {
				var bufferIndex = ctx.drawPass.index & 0xFFFF;
				if ( storageBufferEnabled() )
					p.shader.Batch_StorageBuffer = p.buffers[bufferIndex];
				else
					p.shader.Batch_Buffer = p.buffers[bufferIndex];
				if( p.instanceBuffers == null ) {
					var count = hxd.Math.imin( instanceCount - p.maxInstance * bufferIndex, p.maxInstance );
					instanced.setCommand(p.matIndex, instanced.screenRatioToLod(curScreenRatio), count);
					if ( p.commandBuffers != null && p.commandBuffers.length > 0 ) {
						@:privateAccess instanced.commands.data = p.commandBuffers[bufferIndex].vbuf;
						@:privateAccess instanced.commands.countBuffer = p.countBuffers[bufferIndex].vbuf;
					}
				} else
					instanced.commands = p.instanceBuffers[bufferIndex];
				break;
			}
			p = p.next;
		}
		ctx.uploadParams();
		var prev = ctx.drawPass.index;
		ctx.drawPass.index >>= 16;
		super.draw(ctx);
		ctx.drawPass.index = prev;
	}

	override function calcScreenRatio(ctx:RenderContext) {
		curScreenRatio = @:privateAccess instanced.primitive.getBounds().dimension() / ( 2.0 * hxd.Math.max(lodDistance, 0.0001) );
	}

	override function addBoundsRec( b : h3d.col.Bounds, relativeTo: h3d.Matrix ) {
		var old = primitive;
		primitive = null;
		super.addBoundsRec(b, relativeTo);
		primitive = old;
		if( primitive == null || flags.has(FIgnoreBounds) )
			return;
		// already transformed in absolute
		var bounds = primitive.getBounds();
		if( relativeTo == null )
			b.add(bounds);
		else
			b.addTransform(bounds, relativeTo);
	}

	function addComputeShaders( pass : h3d.mat.Pass ) {}

	inline function isCountBufferAllowed() {
		#if hlsdl
		return h3d.impl.GlDriver.hasMultiIndirectCount;
		#else
		return true;
		#end
	}

	override function onRemove() {
		super.onRemove();
		cleanPasses();
	}

	public function disposeBuffers() {
		if( instanceCount == 0 ) return;
		var p = dataPasses;
		var alloc = hxd.impl.Allocator.get();
		while( p != null ) {
			for ( b in p.buffers )
				alloc.disposeBuffer(b);
			p.buffers.resize(0);
			p = p.next;
		}
	}

	function cleanPasses() {
		var alloc = hxd.impl.Allocator.get();
		while( dataPasses != null ) {
			dataPasses.pass.removeShader(dataPasses.shader);
			for( b in dataPasses.buffers )
				alloc.disposeBuffer(b);

			if ( dataPasses.commandBuffers != null && dataPasses.commandBuffers.length > 0 ) {
				@:privateAccess instanced.commands.data = null;
				for ( buf in dataPasses.commandBuffers )
					alloc.disposeBuffer(buf);
				dataPasses.commandBuffers.resize(0);
				for ( buf in dataPasses.countBuffers )
					alloc.disposeBuffer(buf);
				dataPasses.countBuffers.resize(0);
				dataPasses.computePass = null;
			}

			if( dataPasses.instanceBuffers != null ) {
				for( b in dataPasses.instanceBuffers )
					b.dispose();
			}
			alloc.disposeFloats(dataPasses.data);
			dataPasses = dataPasses.next;
		}
		if ( matInfos != null ) {
			alloc.disposeBuffer(matInfos);
			matInfos = null;
		}
		if( instanced.commands != null )
			instanced.commands.dispose();

		if ( subPartsInfos != null )
			alloc.disposeBuffer(subPartsInfos);

		if ( instanceOffsetsGpu != null )
			alloc.disposeBuffer(instanceOffsetsGpu);
		instanceOffsetsCpu = null;

		primitiveSubBytes = null;
		emittedSubParts = null;
		countBytes = null;
		shadersChanged = true;
	}
}