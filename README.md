# Heaps
_High Performance Game Framework_

[![Build Status](https://travis-ci.org/HeapsIO/heaps.svg?branch=master)](https://travis-ci.org/HeapsIO/heaps)
[![](https://img.shields.io/discord/162395145352904705.svg?logo=discord)](https://discordapp.com/invite/sWCGm33)

[![Heaps.io logo](https://raw.githubusercontent.com/HeapsIO/heaps.io/master/assets/logo/logo-heaps-color.png)](http://heaps.io)

**Heaps** is a cross platform graphics engine designed for high performance games. It's designed to leverage modern GPUs that are commonly available on desktop, mobile and consoles.

Heaps is currently working on:
- HTML5 (requires WebGL)
- Mobile (iOS, tvOS and Android)
- Desktop with OpenGL (Win/Linux/OSX) or DirectX (Windows only)
- Consoles (Nintendo Switch, Sony PS4, XBox One - requires being a registered developer)
- Flash Stage3D


Community
---------

Ask questions or discuss on <https://community.heaps.io>

Chat on Discord <https://discord.gg/sWCGm33> or Gitter <https://gitter.im/heapsio/Lobby>

Samples
-------

In order to compile the samples, go to the `samples` directory and run `haxe gen.hxml`, this will generate a `build` directory containing project files for all samples.

To compile:
- For JS/WebGL: run `haxe [sample]_js.hxml`, then open `index.html` to run
- For [HashLink](https://hashlink.haxe.org): run `haxe [sample]_hl.hxml` then run `hl <sample>.hl` to run (will use SDL, replace `-lib hlsdl` by `-lib hldx` in hxml to use DirectX)
- For Flash: run `haxe [sample]_swf.hxml`, then open `<sample>.swf` to run
- For Consoles, contact us: nicolas@haxe.org

Project files for [Visual Studio Code](https://code.visualstudio.com/) are also generated.

Get started!
------------
* [Installation](https://heaps.io/documentation/installation.html)
* [Live samples with source code](https://heaps.io/samples/)
* [Documentation](https://heaps.io/documentation/home.html)
* [API documentation](https://heaps.io/api/)

FBX material colors
-------------------

FBX-to-HMD conversion preserves explicitly exported `Properties70` material
`DiffuseColor`, multiplied by `DiffuseFactor` when present (FBX default: 1).
The HMD loader applies this RGB value as the material tint, including on textured
materials. Explicit material setup and application code can override it. Materials
without an exported diffuse color retain the material setup's default color.

The color is stored in the appended HMD `DiffuseColor` property (index 8).
Existing HMD files remain readable; files containing this property require the
updated reader. The FBX converter cache version is incremented to regenerate
cached models.

FBX blend shapes
----------------

Connected Blender `BlendShape` / `BlendShapeChannel` / `Geometry` (`Shape`)
exports are imported as HMD shapes using channel names. Each channel must
contain exactly one target; progressive multi-target channels fail conversion.
Skeleton discovery considers only `Skin` deformers. Set shape weights on the
loaded mesh with `setBlendshapeWeight(name, weight)` (0 for the base, 1 for
the full shape).

Forward material shadow filtering
---------------------------------

`h3d.pass.DefaultShadowMap` forwards `samplingKind = PCF`, `pcfQuality`,
`pcfScale`, and the actual shadow-map resolution to `h3d.shader.Shadow`.
Quality 1 uses 4 samples, quality 2 uses 12, and quality 3 uses 64, sharing
the directional shadow shader's Poisson offsets. `pcfScale` sets the sampling
radius in shadow-map texels. Set `blur.radius = 0` when using PCF: filter
visibility comparisons rather than raw depths. Non-PCF material shadows retain
the existing exponential comparison.
