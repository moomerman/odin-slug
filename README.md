# odin-slug

GPU Bezier text rendering for Odin. An implementation of Eric Lengyel's [Slug algorithm](https://jcgt.org/published/0006/02/02/) — resolution-independent text and vector icons rendered by evaluating quadratic Bezier curves per-pixel in the fragment shader.

Text is crisp at any size, rotation, or zoom level. No texture atlases, no SDF artifacts, no mipmaps.

## Status

**Core library: complete.** The `slug/` package provides all CPU-side functionality:

- TTF font loading via stb_truetype
- Glyph outline extraction (quadratic + cubic Bezier curves)
- Band acceleration structure generation
- GPU texture packing (curve + band textures as raw data)
- CPU-side vertex buffer packing
- SVG path parsing (game-icons.net style single-path icons)
- Text effects (rainbow, wobble, shake, rotation, circular, wave, shadow, typewriter)
- Kerning support
- Text measurement

**Backends: coming soon.**

- `slug/backends/vulkan/` — Vulkan 1.x (extracted from the [SlugVibes](../slugvibes) demo)
- `slug/backends/opengl/` — OpenGL 3.3 (compatible with Raylib via rlgl)

## Quick Start

Clone or copy the `slug/` directory into your project:

```
your_project/
  src/main.odin
  libs/
    slug/          <-- this directory
```

Build with:

```sh
odin build src/ -collection:libs=./libs
```

Import and use:

```odin
import "libs:slug"

// Load a font
font, ok := slug.font_load("assets/myfont.ttf")
slug.font_load_ascii(&font)

// Process for GPU (generates texture data for your backend to upload)
pack := slug.process_font(&font)
defer slug.pack_result_destroy(&pack)
// ... upload pack.curve_data and pack.band_data to GPU textures ...

// Create context and add font
ctx: slug.Context
ctx.fonts[0] = font
ctx.font_loaded[0] = true
ctx.font_count = 1

// Per frame
slug.begin(&ctx)
slug.draw_text(&ctx, "Hello, Slug!", 100, 100, 32, {1, 1, 1, 1})
slug.draw_text_rainbow(&ctx, "Rainbow!", 100, 200, 24, time)
slug.draw_text_shadow(&ctx, "Shadows", 100, 300, 28, {0.8, 0.9, 1, 1})
slug.end(&ctx)

// Read vertices for GPU upload:
//   ctx.vertices[:slug.vertex_count(&ctx)]
// Draw per-font batches using:
//   ctx.font_quad_start[slot], ctx.font_quad_count[slot]
```

## Package Structure

```
slug/
├── slug.odin      Context, types, constants, lifecycle
├── ttf.odin       TTF font loading, glyph extraction, kerning
├── glyph.odin     Band acceleration, texture packing, f16 conversion
├── svg.odin       SVG path parser, icon loading
├── text.odin      draw_text, measure_text, vertex packing
└── effects.odin   Rainbow, wobble, shake, rotation, wave, shadow, typewriter
```

All files are `package slug`. Zero graphics API imports — the core is completely GPU-agnostic.

## Vertex Format

Each glyph quad is 4 vertices, 80 bytes each:

| Attribute | Contents |
|-----------|----------|
| `pos` (vec4) | Screen position + dilation normal |
| `tex` (vec4) | Em-space texcoord + packed glyph/band texture location |
| `jac` (vec4) | 2x2 inverse Jacobian (screen -> em-space) |
| `bnd` (vec4) | Band transform (em coord -> band index) |
| `col` (vec4) | Vertex color RGBA |

## Shader Requirements

The fragment shader evaluates quadratic Bezier curves per-pixel. You need:
- A curve texture: `R16G16B16A16_SFLOAT` (OpenGL: `GL_RGBA16F`)
- A band texture: `R16G16_UINT` (OpenGL: `GL_RG16UI`)
- Both sampled with `texelFetch` (integer coordinates, no filtering)

GLSL shader source for both 3.30 (OpenGL) and 4.50 (Vulkan) will be provided in `slug/shaders/`.

## Dependencies

- `vendor:stb/truetype` — ships with the Odin compiler, no external install needed

## License

MIT. See [LICENSE](LICENSE).

The Slug algorithm patent (US 10,373,352) expired in 2024 and is now public domain.

## Credits

- Algorithm: Eric Lengyel, [Slug GPU text rendering](https://jcgt.org/published/0006/02/02/)
- Reference implementation: [SlugVibes](../slugvibes) demo
- SVG icons: [game-icons.net](https://game-icons.net/) (CC BY 3.0)
- Fonts: Liberation font family (SIL Open Font License)
