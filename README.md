# odin-slug

GPU Bezier text rendering for Odin. An implementation of Eric Lengyel's [Slug algorithm](https://jcgt.org/published/0006/02/02/) -- resolution-independent text and vector icons rendered by evaluating quadratic Bezier curves per-pixel in the fragment shader.

Crisp at any size, rotation, or zoom. No texture atlases, no SDF artifacts, no mipmaps.

## Why Slug?

Traditional text rendering rasterizes glyphs into bitmaps at fixed sizes. Scale up and you get blur. SDF fonts improve on this but break down at sharp corners and small sizes.

Slug skips rasterization entirely. The GPU evaluates the actual Bezier curves of each glyph per-pixel, computing exact coverage via winding numbers. Text stays sharp at any resolution, rotation, or zoom because there's nothing pre-rasterized to degrade.

## Features

- **Resolution-independent text** -- crisp at any size, rotation, or zoom
- **SVG vector icons** -- parse SVG paths into the same GPU pipeline as text
- **Text effects** -- rainbow, wobble, shake, rotation, circular, wave, shadow, typewriter
- **Kerning** -- automatic kern pair adjustment
- **Multi-font** -- up to 4 fonts loaded simultaneously, batched draw calls
- **GPU-agnostic core** -- backends for OpenGL 3.3, Raylib, and Vulkan
- **No external dependencies** -- only `vendor:stb/truetype` (ships with Odin)

## Quick Start

### 1. Get the library

Clone or copy the `slug/` directory into your project:

```
your_project/
├── src/main.odin
└── libs/
    └── slug/            <-- copy this directory
        ├── slug.odin
        ├── ttf.odin
        ├── glyph.odin
        ├── svg.odin
        ├── text.odin
        ├── effects.odin
        └── backends/
            └── opengl/
                └── opengl.odin
```

### 2. Build with the collection flag

```sh
odin build src/ -collection:libs=./libs
```

### 3. Import and use

```odin
import "libs:slug"
import slug_gl "libs:slug/backends/opengl"

// Initialize (heap-allocate -- slug.Context is ~1.5MB)
renderer := new(slug_gl.Renderer)
slug_gl.init(renderer)
slug_gl.load_font(renderer, 0, "myfont.ttf")
defer slug_gl.destroy(renderer)

// Per frame
slug.begin(&renderer.ctx)
slug.draw_text(&renderer.ctx, "Hello, Slug!", 100, 100, 32, {1, 1, 1, 1})
slug.draw_text_rainbow(&renderer.ctx, "Rainbow!", 100, 200, 24, time)
slug.end(&renderer.ctx)
slug_gl.flush(renderer, screen_width, screen_height)
```

### Raylib Integration

The Raylib backend wraps the OpenGL backend and handles GL function pointer loading and batch flushing automatically.

```odin
import rl "vendor:raylib"
import "libs:slug"
import slug_rl "libs:slug/backends/raylib"

// After rl.InitWindow():
renderer := new(slug_rl.Renderer)
slug_rl.init(renderer)
slug_rl.load_font(renderer, 0, "myfont.ttf")
ctx := slug_rl.ctx(renderer)

// In your render loop:
rl.BeginDrawing()
rl.ClearBackground(rl.DARKGRAY)

// Normal Raylib drawing
rl.DrawRectangle(10, 10, 200, 100, rl.BLUE)

// Slug text -- flush() handles Raylib batch flushing internally
slug.begin(ctx)
slug.draw_text(ctx, "Crisp GPU text!", 100, 100, 32, {1,1,1,1})
slug.end(ctx)
slug_rl.flush(renderer, rl.GetScreenWidth(), rl.GetScreenHeight())

rl.EndDrawing()
```

## Package Structure

```
slug/                          Core library (package slug)
├── slug.odin                  Context, types, constants, lifecycle
├── ttf.odin                   TTF loading, glyph extraction, kerning
├── glyph.odin                 Band acceleration, texture packing, f16
├── svg.odin                   SVG path parser, icon loading
├── text.odin                  draw_text, measure_text, vertex packing
├── effects.odin               Text effects (rainbow, wobble, shadow, etc.)
├── shaders/                   GLSL shader source files
│   ├── slug_330.vert/.frag    OpenGL 3.3
│   └── slug_450.vert/.frag    Vulkan
└── backends/
    ├── opengl/                OpenGL 3.3 backend (~580 lines)
    │   └── opengl.odin        Shader, VAO/VBO, texture upload, draw
    ├── raylib/                Raylib backend (thin wrapper over OpenGL)
    │   └── raylib.odin        GL loader + batch flush automation
    └── vulkan/                Vulkan backend (~1700 lines)
        ├── renderer.odin      Pipeline, swapchain, command buffers
        └── helpers.odin       Buffer/texture/shader utilities

examples/
├── demo_opengl/main.odin      Standalone GLFW + OpenGL 3.3 demo
├── demo_raylib/main.odin      Raylib + slug integration demo
├── demo_vulkan/main.odin      Standalone SDL3 + Vulkan demo
└── assets/fonts/              Liberation font family (bundled)

docs/
└── DESIGN.md                  Architecture and design rationale
```

## API Reference

### Core (package slug)

| Proc | Purpose |
|------|---------|
| `begin(ctx)` | Reset quad counter for new frame |
| `end(ctx)` | Finalize per-font quad ranges |
| `draw_text(ctx, text, x, y, size, color)` | Draw a string at baseline position |
| `draw_icon(ctx, slot, x, y, size, color)` | Draw an SVG icon centered at position |
| `measure_text(font, text, size)` | Returns pixel width and height |
| `use_font(ctx, slot)` | Switch active font slot |
| `active_font(ctx)` | Pointer to current font |
| `vertex_count(ctx)` | Vertices written this frame |
| `font_load(path)` | Load a TTF file |
| `font_load_with_icons(path, icons)` | Load font + ASCII + SVG icons + process (all-in-one) |
| `font_load_ascii(font)` | Load glyphs 32-126 |
| `font_load_glyph(font, codepoint)` | Load a single glyph |
| `font_get_kerning(font, left, right)` | Kerning adjustment between two glyphs |
| `font_process(font)` | Process glyphs + pack textures |
| `register_font(ctx, slot, font)` | Register a loaded font into a context slot |
| `svg_load_into_font(font, slot, path)` | Load SVG icon into glyph slot |
| `unload_font(ctx, slot)` | Free a single font slot at runtime |
| `destroy(ctx)` | Free all fonts and glyph data |

### Text Effects (package slug)

| Proc | Effect |
|------|--------|
| `draw_text_rainbow(ctx, text, x, y, size, time)` | Per-character hue cycling |
| `draw_text_wobble(ctx, text, x, y, size, time)` | Vertical sine wave bounce |
| `draw_text_shake(ctx, text, x, y, size, intensity, time)` | Pseudo-random jitter |
| `draw_text_rotated(ctx, text, cx, cy, size, angle, color)` | Rotated around center |
| `draw_text_on_circle(ctx, text, cx, cy, radius, angle, size, color)` | Along circular path |
| `draw_text_on_wave(ctx, text, x, y, size, amplitude, wavelength, phase, color)` | Along sine wave |
| `draw_text_shadow(ctx, text, x, y, size, color)` | Drop shadow beneath text |
| `draw_text_typewriter(ctx, text, x, y, size, color, time)` | Character-by-character reveal |

### OpenGL Backend (package slug_opengl)

| Proc | Purpose |
|------|---------|
| `init(renderer)` | Compile shaders, create GL objects |
| `load_font(renderer, slot, path)` | Load font + upload textures (all-in-one) |
| `upload_font_textures(renderer, slot, pack)` | Upload pre-packed textures (advanced) |
| `flush(renderer, width, height)` | Upload vertices, draw all font batches |
| `destroy(renderer)` | Delete GL objects, free slug context |

### Raylib Backend (package slug_raylib)

Wraps the OpenGL backend. Handles GL function pointer loading and Raylib batch flushing.

| Proc | Purpose |
|------|---------|
| `init(renderer)` | Load GL function pointers + compile shaders (call after `rl.InitWindow`) |
| `ctx(renderer)` | Get pointer to slug context for draw calls |
| `load_font(renderer, slot, path)` | Load font + upload textures (all-in-one) |
| `upload_font_textures(renderer, slot, pack)` | Upload pre-packed textures (advanced) |
| `flush(renderer, width, height)` | Flush Raylib batch + upload vertices + draw |
| `destroy(renderer)` | Delete GL objects, free slug context |

### Vulkan Backend (package slug_vulkan)

| Proc | Purpose |
|------|---------|
| `init(renderer, window)` | Create Vulkan instance, device, pipeline, buffers |
| `load_font(renderer, slot, path, name)` | Load font + upload textures + create descriptor set |
| `upload_font_textures(renderer, slot, pack, name)` | Upload pre-packed textures (advanced, for SVG icons) |
| `begin_frame(renderer)` | Wait for GPU, reset quad counter |
| `end_frame(renderer)` | Finalize per-font quad ranges |
| `use_font(renderer, slot)` | Switch active font slot |
| `draw_frame(renderer)` | Copy vertices to GPU, record commands, submit, present |
| `destroy(renderer)` | Destroy all Vulkan resources and slug context |

## Architecture

### Core / Backend Split

The library separates the **GPU-agnostic core** from **thin backends**:

- **Core** (`slug/`): Everything that doesn't touch a graphics API -- font loading, Bezier curve extraction, band acceleration, texture data packing, vertex buffer packing, text measurement. Produces raw vertex and texture data for backends to consume.

- **Backends** (`slug/backends/*/`): Take the core's output and render it. The OpenGL backend is ~580 lines. The Raylib backend wraps OpenGL with automatic GL loader and batch flush handling. A backend just compiles the shader, uploads textures, uploads vertices, and draws.

This means:
- New backends (Metal, DirectX, WebGPU) need ~300-500 lines
- The core works without any graphics API linked
- Custom rendering pipelines can read `ctx.vertices` directly

### Vertex Format

Each glyph is a screen-space quad (4 vertices, 80 bytes each):

| Attribute | Layout | Contents |
|-----------|--------|----------|
| `pos` | vec4 | Screen position + dilation normal |
| `tex` | vec4 | Em-space texcoord + packed glyph location |
| `jac` | vec4 | 2x2 inverse Jacobian (screen -> em-space) |
| `bnd` | vec4 | Band transform (em coord -> band index) |
| `col` | vec4 | Vertex color RGBA |

### GPU Textures

Two textures per font, sampled with `texelFetch` (integer coordinates):

| Texture | Format | Contents |
|---------|--------|----------|
| Curve | `RGBA16F` | Bezier control points (2 texels per curve) |
| Band | `RG16UI` | Band headers + curve index lists |

### Font Slot Constraint

Draw all content for each font contiguously. You can't switch back to a font that already has quads -- the per-font quad ranges are recorded sequentially.

```odin
// Correct: all font 0, then font 1
slug.draw_text(ctx, "Font 0 text", ...)
slug.draw_text(ctx, "More font 0", ...)
slug.use_font(ctx, 1)
slug.draw_text(ctx, "Font 1 text", ...)

// WRONG: switching back to font 0 after font 1 has quads
slug.use_font(ctx, 0)  // This would overwrite font 0's quad range!
```

## SVG Icon Support

Load SVG icons into unused glyph slots (128+) to render vector art through the same pipeline as text:

```odin
// Before font_process:
slug.svg_load_into_font(&font, 128, "icons/shield.svg")
slug.svg_load_into_font(&font, 129, "icons/sword.svg")

// After processing, draw like any glyph:
slug.draw_icon(ctx, 128, x, y, 48.0, {1, 1, 1, 1})
```

Supports SVG path commands: M, L, H, V, C, S, Q, T, Z (and lowercase relative variants). Cubic Beziers are subdivided into quadratic approximations.

## Building

### Prerequisites

- [Odin compiler](https://odin-lang.org/) (includes `vendor:stb/truetype` and `vendor:OpenGL`)
- OpenGL 3.3+ capable GPU (for the OpenGL backend/demos)
- Vulkan SDK (optional, for the Vulkan backend)
- A TTF font file

### Build Scripts

```sh
# Linux / macOS
./build.sh check     # Verify all packages compile
./build.sh opengl    # Build OpenGL/GLFW demo
./build.sh raylib    # Build Raylib demo
./build.sh vulkan    # Compile shaders + build Vulkan/SDL3 demo
./build.sh shaders   # Compile GLSL 4.50 -> SPIR-V only (requires glslc)
./build.sh all       # Build all examples
./build.sh clean     # Remove build artifacts
```

```bat
:: Windows (cmd)
build.bat check
build.bat opengl
build.bat raylib
build.bat vulkan
build.bat all
build.bat clean
```

```powershell
# Windows (PowerShell)
.\build.ps1 check
.\build.ps1 opengl
.\build.ps1 raylib
.\build.ps1 vulkan
```

### Manual Build

```sh
# Check that packages compile
odin check slug/ -no-entry-point                     # core
odin check slug/backends/opengl/ -no-entry-point     # OpenGL backend
odin check slug/backends/raylib/ -no-entry-point     # Raylib backend
odin check slug/backends/vulkan/ -no-entry-point     # Vulkan backend

# Build examples
odin build examples/demo_opengl/ -out:demo_opengl -collection:libs=.
odin build examples/demo_raylib/ -out:demo_raylib -collection:libs=.

# Vulkan demo (requires glslc for shader compilation)
glslc slug/shaders/slug_450.vert -o slug/shaders/slug_vert.spv
glslc slug/shaders/slug_450.frag -o slug/shaders/slug_frag.spv
odin build examples/demo_vulkan/ -out:demo_vulkan -collection:libs=.
```

### Demo Controls

| Input | Action |
|-------|--------|
| ESC | Quit (all demos) |

### Platform Notes

**Linux** (tested): Install Odin per [odin-lang.org/docs/install](https://odin-lang.org/docs/install/). Build the stb vendor lib if not already done:
```sh
make -C $(odin root)/vendor/stb/src unix
```
GLFW and Raylib vendor libraries ship with Odin. For the Vulkan demo: `sudo pacman -S vulkan-devel shaderc sdl3` (Arch) or `sudo apt install libvulkan-dev glslc libsdl3-dev` (Debian/Ubuntu).

**Windows** (untested): Install Odin. From a Developer Command Prompt, build the stb vendor lib:
```cmd
cd %ODIN_ROOT%\vendor\stb\src
nmake -f Windows.mak
```
Vendor libraries (OpenGL, GLFW, Raylib) are included. Vulkan SDK from [lunarg.com](https://vulkan.lunarg.com/) if using the Vulkan backend. Build scripts (`build.bat`, `build.ps1`) are provided but have not been tested — please report issues.

**macOS** (untested): Install Odin. Build the stb vendor lib: `make -C $(odin root)/vendor/stb/src unix`. OpenGL backend works (macOS supports OpenGL 4.1). Vulkan requires MoltenVK. Not yet tested — please report issues.

### Troubleshooting

**Linker errors mentioning `stb_truetype` symbols**
- Build the stb vendor library first -- see platform notes above. Most common first-build issue.

**Font not found / no text visible**
- Demos load fonts from `examples/assets/fonts/` with relative paths. Run from the project root.

**OpenGL errors on startup**
- Make sure your GPU supports OpenGL 3.3+. On Linux: `glxinfo | grep "OpenGL version"`.

## Dependencies

| Dependency | Source | Used By |
|------------|--------|---------|
| `vendor:stb/truetype` | Ships with Odin | Core (TTF parsing) |
| `vendor:OpenGL` | Ships with Odin | OpenGL backend |
| `vendor:vulkan` | Ships with Odin | Vulkan backend |
| `vendor:sdl3` | Ships with Odin | Vulkan backend (windowing) |
| `vendor:glfw` | Ships with Odin | OpenGL demo only |
| `vendor:raylib` | Ships with Odin | Raylib demo only |

## License

MIT. See [LICENSE](LICENSE).

### Patent Status

The Slug algorithm was patented by Eric Lengyel (US Patent 10,936,792). On March 17, 2026, Lengyel dedicated the patent to the public domain via a Terminal Disclaimer. This implementation is free to use in any project.

## AI Disclosure

Built with **Claude Code** (Anthropic's Claude Opus). I provided direction, architecture, and testing; Claude wrote the implementation. The core algorithm was ported from Eric Lengyel's publicly available shader code.

## Roadmap

### Near-term

- [ ] **Text wrapping** -- line breaking via `measure_text()` for UI panels and dialogue
- [ ] **Outlined text** -- dilated quads for outline/stroke (similar to existing drop shadow)
- [ ] **UI scaling API** -- uniform scale factor for all text (accessibility, HiDPI)
- [ ] **Static text caching** -- skip re-emitting vertices for unchanged text between frames

### Medium-term

- [ ] **Unicode beyond ASCII** -- on-demand glyph loading for codepoints > 255 (currently `MAX_CACHED_GLYPHS = 256`)
- [ ] **Subpixel positioning** -- fractional pixel offsets for tighter character spacing
- [ ] **Shared font atlases** -- pack multiple fonts into shared curve/band textures to cut texture binds
- [ ] **WebGPU backend** -- for browser-based Odin projects via wasm

### Long-term

- [ ] **Text shaping** -- HarfBuzz integration for complex scripts (Arabic, Devanagari, CJK vertical)
- [ ] **GPU compute preprocessing** -- band generation and curve sorting in compute shaders
- [ ] **Instanced rendering** -- one draw call per glyph type instead of per-instance quads
- [ ] **Subpixel rendering** -- per-RGB-subpixel coverage for LCD antialiasing

## Credits

- **Algorithm**: Eric Lengyel -- [Slug: Resolution-Independent GPU Text](https://jcgt.org/published/0006/02/02/)
- **Reference implementation**: SlugVibes demo (Vulkan + Odin proof-of-concept)
- **SVG icons**: [game-icons.net](https://game-icons.net/) (CC BY 3.0)
- **Fonts**: Liberation font family (SIL Open Font License)
