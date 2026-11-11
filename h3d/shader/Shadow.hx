package h3d.shader;

class Shadow extends hxsl.Shader {

	static var SRC = {
		@global @const var SHADOW_PCF_SAMPLES : Int;
		@global var shadow : {
			var map : Channel;
			@const var usePCF : Bool;
			var pcfOffsets : Array<Vec4, SHADOW_PCF_SAMPLES>;
			var pcfScale : Float;
			var resolution : Vec2;
			var proj : Mat3x4;
			var color : Vec3;
			var power : Float;
			var bias : Float;
		};
		var pixelColor : Vec4;
		var transformedPosition : Vec3;
		var pixelTransformedPosition : Vec3;
		@private var shadowPos : Vec3;

		function sampleDepth(uv : Vec2) : Float {
			var outside = uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
			return outside ? 1.0 : shadow.map.getLod(uv, 0).r;
		}

		function fragment() {
			var shadowPos = pixelTransformedPosition * shadow.proj;
			var uv = screenToUv(shadowPos.xy);
			var zMax = shadowPos.z.saturate();
			var shade : Float;
			if( shadow.usePCF ) {
				shade = 0.0;
				var offsetScale = shadow.pcfScale / shadow.resolution;
				for( i in 0...SHADOW_PCF_SAMPLES ) {
					var depth = sampleDepth(uv + shadow.pcfOffsets[i].xy * offsetScale);
					shade += zMax - shadow.bias > depth ? 0.0 : 1.0;
				}
				shade /= SHADOW_PCF_SAMPLES;
			} else {
				var depth = sampleDepth(uv);
				var delta = (depth + shadow.bias).min(zMax) - zMax;
				shade = exp(shadow.power * delta).saturate();
			}
			pixelColor.rgb *= (1 - shade) * shadow.color.rgb + shade;
		}
	};

	public function new() {
		super();
	}

}