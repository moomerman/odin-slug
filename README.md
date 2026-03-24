# odin-slug

GPU Bezier text rendering for Odin. An implementation of Eric Lengyel's [Slug algorithm](https://jcgt.org/published/0006/02/02/) -- resolution-independent text and vector icons rendered by evaluating quadratic Bezier curves per-pixel in the fragment shader.

Crisp at any size, rotation, or zoom. No texture atlases, no SDF artifacts, no mipmaps.

## Why Slug?

Traditional text rendering rasterizes glyphs into bitmaps at fixed sizes. Scale up and you get blur. SDF fonts improve on this but break down at sharp corners and small sizes.

Slug skips rasterization entirely. The GPU evaluates the actual Bezier curves of each glyph per-pixel, computing exact coverage via winding numbers. Text stays sharp at any resolution, rotation, or zoom because there's nothing pre-rasterized to degrade.

## Features

**Rendering**
- Resolution-independent text -- crisp at any size, rotation, or zoom
- SVG vector icons -- parse SVG paths into the same GPU pipeline as text
- Background rectangles -- solid-color rects drawn behind text in a single pass
- Bordered rectangles -- outlined and filled-with-border rects for panels and UI
- Progress bars -- animated fill with border and centered label overlay
- GPU scissor clipping -- restrict rendering to screen-space regions

**Text Layout**
- Measurement -- per-character, per-string, monospace grid, and line height helpers
- Word wrapping -- automatic line breaking with height measurement for sizing containers
- Alignment -- left, centered, right-aligned, and justified text
- Truncation -- character or word-boundary clipping with custom ellipsis
- Text selection -- background highlight over a rune range
- Letter spacing (tracking), tab stops, line height multiplier
- Grid layout -- fixed-width cell placement for roguelike maps and tables
- Columnar layout -- per-column widths and alignment for inventory tables, stat displays
- Subscript / superscript -- inline sub/super with configurable scale and shift

**Effects**
- Rainbow, wobble, shake, rotation, circular, wave path
- Shadow, outline, fade, gradient, pulse, typewriter reveal
- Floating damage numbers (rise + fade with configurable duration)
- Per-glyph transform callback for custom animations

**Text Systems**
- Rich text markup -- `{red:text}`, `{#rrggbb:text}`, `{bg:color:text}`, `{icon:slot:color}`
- Static text caching -- cache vertex data for unchanged text, draw with a single memcopy
- Rich text wrapping -- word-wrap markup text in fixed-width panels
- Rich text scrolling -- scrollable message log with inline colors and markup
- Scrollable text regions -- viewport-clipped wrapped text with scroll utilities
- Message log -- timestamped, auto-fading message display for game UI
- Text input -- cursor positioning by index, click-to-position hit testing, blinking cursor
- Font fallback chains -- automatic glyph lookup across fonts for missing codepoints

**Infrastructure**
- Multi-font -- up to 4 fonts loaded simultaneously with batched draw calls
- Shared font atlases -- pack all fonts into one texture pair for single-draw-call rendering
- UI scaling -- global scale factor for DPI awareness and accessibility
- Camera panning -- pixel-offset camera applied to all draw calls
- Kerning -- automatic kern pair adjustment (toggleable per call)
- Font hot-reloading -- swap fonts at runtime via unload + reload

**Backends**
- OpenGL 3.3 (standalone, GLFW)
- Raylib (thin wrapper over OpenGL, automatic batch flush)
- Vulkan 1.x (standalone, SDL3 windowing)
- SDL3 GPU (cross-platform: Vulkan/D3D12/Metal via SDL3)
- Karl2D (thin wrapper over OpenGL, callback-based batch flush)
- Sokol GFX (standalone, GL backend with GLSL 430)

**Dependencies**
- Core library: only `vendor:stb/truetype` (ships with Odin)
- Backends use Odin vendor packages (OpenGL, Vulkan, SDL3, Raylib, GLFW)
- Karl2D and Sokol require external packages via `-collection:` flags

## Quick Start

### 1. Get the library

Clone or copy the `slug/` directory into your project:

```
your_project/
├── src/main.odin
└── libs/
    └── slug/            <-- copy this directory
        ├── slug.odin
        ├── text.odin
        ├── effects.odin
        └── backends/
            ├── opengl/
            ├── raylib/
            ├── vulkan/
            ├── sdl3gpu/
            ├── karl2d/
            └── sokol/
```

### 2. Build with the collection flag

```sh
odin build src/ -collection:libs=./libs
```

### 3. Import and use (OpenGL example)

```odin
import "libs:slug"
import slug_gl "libs:slug/backends/opengl"

// Initialize (heap-allocate -- slug.Context is ~1.5MB)
renderer := new(slug_gl.Renderer)
slug_gl.init(renderer)
slug_gl.load_font(renderer, 0, "myfont.ttf")
defer { slug_gl.destroy(renderer); free(renderer) }

// Per frame
slug.begin(&renderer.ctx)
slug.draw_text(&renderer.ctx, "Hello, Slug!", 100, 100, 32, {1, 1, 1, 1})
slug.draw_text_rainbow(&renderer.ctx, "Rainbow!", 100, 200, 24, time = elapsed)
slug.end(&renderer.ctx)
slug_gl.flush(renderer, screen_width, screen_height)
```

### Backend Quick Reference

Each backend follows the same pattern: init, load fonts, per-frame draw, flush, destroy.

**Raylib** -- wraps OpenGL, handles GL loader and batch flush:
```odin
import slug_rl "libs:slug/backends/raylib"

renderer := new(slug_rl.Renderer)
slug_rl.init(renderer)  // call after rl.InitWindow()
ctx := slug_rl.ctx(renderer)
slug_rl.load_font(renderer, 0, "myfont.ttf")

// In render loop:
rl.BeginDrawing()
slug.begin(ctx)
slug.draw_text(ctx, "Crisp GPU text!", 100, 100, 32, {1, 1, 1, 1})
slug.end(ctx)
slug_rl.flush(renderer, rl.GetScreenWidth(), rl.GetScreenHeight())
rl.EndDrawing()
```

**Karl2D** -- wraps OpenGL, takes batch flush callback:
```odin
import slug_k2 "libs:slug/backends/karl2d"
import k2 "karl2d:karl2d"

renderer := new(slug_k2.Renderer)
slug_k2.init(renderer, k2.draw_current_batch)  // call after k2.init()
ctx := slug_k2.ctx(renderer)

// In render loop:
slug.begin(ctx)
slug.draw_text(ctx, "Hello!", 100, 100, 32, {1, 1, 1, 1})
slug.end(ctx)
slug_k2.flush(renderer, width, height)
```

**Sokol GFX** -- standalone, issues draw calls inside your pass:
```odin
import slug_sokol "libs:slug/backends/sokol"
import sg "sokol:gfx"

renderer := new(slug_sokol.Renderer)
slug_sokol.init(renderer)  // call after sg.setup()
ctx := slug_sokol.ctx(renderer)

// In render loop:
sg.begin_pass(...)
slug.begin(ctx)
slug.draw_text(ctx, "Hello!", 100, 100, 32, {1, 1, 1, 1})
slug.end(ctx)
slug_sokol.flush(renderer, width, height)
sg.end_pass()
sg.commit()
```

**Vulkan** and **SDL3 GPU** -- own their frame lifecycle:
```odin
// Vulkan:
slug_vk.begin_frame(renderer)
slug.begin(&renderer.ctx)
// ... draw calls ...
slug.end(&renderer.ctx)
slug_vk.flush(renderer)
slug_vk.present_frame(renderer)

// SDL3 GPU:
slug_sdl3.begin_frame(renderer)
slug.begin(&renderer.ctx)
// ... draw calls ...
slug.end(&renderer.ctx)
slug_sdl3.flush(renderer)
slug_sdl3.present_frame(renderer)
```

## Package Structure

```
slug/                              Core library (package slug)
├── slug.odin                      Context, types, constants, lifecycle
├── text.odin                      Text drawing, measurement, wrapping, alignment
├── effects.odin                   Animations (rainbow, wobble, shadow, outline, etc.)
├── cache.odin                     Static text caching
├── scroll.odin                    Scrollable text regions
├── richtext.odin                  Rich text markup parsing ({color:text}, {bg:}, {icon:})
├── log.odin                       Message log (timestamped, auto-fading)
├── ttf.odin                       TTF loading, glyph extraction, kerning
├── glyph.odin                     Band acceleration, texture packing, f16
├── svg.odin                       SVG path parser, icon loading
├── shaders/                       GLSL shader source files
│   ├── slug_330.*                 OpenGL 3.3
│   ├── slug_450.* / rect_450.*   Vulkan (push constants)
│   └── slug_sdl3.* / rect_sdl3.* SDL3 GPU (UBO uniforms)
└── backends/
    ├── opengl/opengl.odin         OpenGL 3.3 (GLFW)
    ├── raylib/raylib.odin         Raylib (thin wrapper over OpenGL)
    ├── karl2d/karl2d.odin         Karl2D (thin wrapper over OpenGL)
    ├── sokol/sokol.odin           Sokol GFX (GL backend, GLSL 430)
    ├── sdl3gpu/sdl3gpu.odin       SDL3 GPU (Vulkan/D3D12/Metal)
    └── vulkan/                    Vulkan 1.x (SDL3 windowing)
        ├── renderer.odin          Pipeline, swapchain, command buffers
        └── helpers.odin           Buffer/texture/shader utilities

examples/
├── demo_opengl/main.odin          GLFW + OpenGL 3.3
├── demo_raylib/main.odin          Raylib integration
├── demo_vulkan/main.odin          SDL3 + Vulkan
├── demo_sdl3gpu/main.odin         SDL3 GPU (cross-platform)
├── demo_karl2d/main.odin          Karl2D integration
├── demo_sokol/main.odin           Sokol App + Sokol GFX
└── assets/
    ├── fonts/                     Liberation font family (bundled)
    └── icons/                     SVG game icons (bundled)
```

## API Reference

### Core (package slug)

All text drawing, measurement, and effects live in the core package. They work identically across all backends -- the core never touches the GPU.

#### Drawing

| Proc | Purpose |
|------|---------|
| `begin(ctx)` | Reset counters for new frame |
| `end(ctx)` | Finalize per-font quad ranges |
| `draw_text(ctx, text, x, y, size, color, tracking?)` | Draw a string at baseline position (optional letter spacing) |
| `draw_text_centered(ctx, text, x, y, size, color)` | Centered at x |
| `draw_text_right(ctx, text, x, y, size, color)` | Right-aligned ending at x |
| `draw_text_justified(ctx, text, x, y, size, width, color)` | Fill column width with even word spacing |
| `draw_text_wrapped(ctx, text, x, y, size, max_width, color, line_spacing?)` | Word wrap (optional line height multiplier), returns total height |
| `draw_text_truncated(ctx, text, x, y, size, max_width, color, ellipsis?)` | Clip with ellipsis (custom string optional), returns drawn width |
| `draw_text_truncated_word(ctx, text, x, y, size, max_width, color, ellipsis?)` | Word-boundary truncation with ellipsis |
| `draw_text_selection(ctx, text, x, y, size, text_color, sel_start, sel_end, sel_color)` | Highlight a rune range with background color |
| `draw_text_grid(ctx, text, x, y, size, cell_w, cell_h, color)` | Fixed-width grid (roguelike maps) |
| `draw_text_sub(ctx, text, x, y, size, color)` | Subscript |
| `draw_text_super(ctx, text, x, y, size, color)` | Superscript |
| `draw_text_styled(ctx, text, x, y, style)` | Draw with a Text_Style bundle (underline, strikethrough, independent decoration colors) |
| `draw_text_highlighted(ctx, text, x, y, size, text_color, bg_color)` | Background highlight + text |
| `draw_text_underlined(ctx, text, x, y, size, color, line_color?)` | Underline decoration (independent color optional) |
| `draw_text_strikethrough(ctx, text, x, y, size, color, line_color?)` | Strikethrough decoration (independent color optional) |
| `draw_text_transformed(ctx, text, x, y, size, color, callback, userdata)` | Per-glyph custom transform |
| `draw_icon(ctx, slot, x, y, size, color)` | Draw SVG icon centered at position |
| `draw_rect(ctx, x, y, w, h, color)` | Solid background rectangle (drawn behind text) |
| `draw_rect_outline(ctx, x, y, w, h, color, thickness?)` | Rectangle outline (4 rects, no corner overlap) |
| `draw_rect_bordered(ctx, x, y, w, h, fill, border, thickness?)` | Filled rect with border |
| `draw_bar(ctx, x, y, w, h, value, max, fill, bg, border, label?, size?, color?)` | Progress bar with animated fill and centered label |
| `draw_cursor(ctx, x, y, h, color, time, blink_rate?)` | Blinking text cursor rectangle |
| `draw_text_columns(ctx, columns, x, y, size, color)` | Tabular layout with per-column width and alignment |

#### Effects

| Proc | Effect |
|------|--------|
| `draw_text_rainbow(ctx, text, x, y, size, time)` | Per-character hue cycling |
| `draw_text_wobble(ctx, text, x, y, size, time, amplitude)` | Vertical sine wave bounce |
| `draw_text_shake(ctx, text, x, y, size, intensity, time)` | Pseudo-random jitter |
| `draw_text_rotated(ctx, text, cx, cy, size, angle, color)` | Rotated around center point |
| `draw_text_on_circle(ctx, text, cx, cy, radius, angle, size, color)` | Along circular arc |
| `draw_text_on_wave(ctx, text, x, y, size, amplitude, wavelength, phase, color)` | Along sine wave path |
| `draw_text_shadow(ctx, text, x, y, size, color, offset)` | Drop shadow beneath text |
| `draw_text_outlined(ctx, text, x, y, size, color, thickness, outline_color)` | 8-direction outline |
| `draw_text_fade(ctx, text, x, y, size, color, alpha)` | Alpha fade |
| `draw_text_gradient(ctx, text, x, y, size, top_color, bottom_color)` | Per-character vertical blend |
| `draw_text_pulse(ctx, text, x, y, size, color, time)` | Per-character scale oscillation |
| `draw_text_float(ctx, text, x, y, size, color, age, duration)` | Rising + fading damage number |
| `draw_text_typewriter(ctx, text, x, y, size, color, time, chars_per_sec)` | Character-by-character reveal |

#### Measurement

| Proc | Purpose |
|------|---------|
| `measure_text(font, text, size)` | Returns (width, height) in pixels |
| `measure_text_wrapped(ctx, text, size, max_width)` | Returns (height, line_count) of wrapped text |
| `measure_text_styled(ctx, text, style)` | Measure with a Text_Style |
| `char_advance(font, ch, size)` | Advance width of a single character |
| `line_height(font, size)` | Vertical distance between lines |
| `mono_width(font, size)` | Max glyph width for grid alignment |
| `coord_snap(v)` | Round coordinate to nearest pixel |

#### Cursor and Hit Testing

| Proc | Purpose |
|------|---------|
| `cursor_x_from_index(font, text, size, index)` | Pixel x-offset of cursor at character index |
| `index_from_x(font, text, size, target_x)` | Character index closest to pixel x-offset |
| `text_hit_test(font, text, x, y, size, mouse_x, mouse_y)` | Click-to-position (returns index, hit) |

#### Rich Text Markup

Inline markup format: `{color:text}`, `{#rrggbb:text}`, `{bg:color:text}`, `{icon:slot:color}`. Named colors: red, green, blue, yellow, cyan, magenta, orange, white, black, gray. Escaped brace: `{{`.

| Proc | Purpose |
|------|---------|
| `draw_rich_text(ctx, text, x, y, size, default_color)` | Draw with inline markup |
| `draw_rich_text_centered(ctx, text, x, y, size, default_color)` | Centered rich text |
| `draw_rich_text_wrapped(ctx, text, x, y, size, max_width, color, line_spacing?)` | Word-wrapped rich text, returns (height, lines) |
| `measure_rich_text(font, text, size)` | Measure with markup stripped |
| `measure_rich_text_wrapped(ctx, text, size, max_width)` | Returns (height, lines) for wrapped rich text |
| `rich_text_plain_length(text)` | Plain text byte length |

#### Scrollable Text

| Proc / Type | Purpose |
|-------------|---------|
| `Scroll_Region` | Struct: x, y, width, height, scroll_offset |
| `draw_text_scrolled(ctx, text, &region, size, color)` | Viewport-clipped wrapped text |
| `draw_rich_text_scrolled(ctx, text, &region, size, color)` | Viewport-clipped wrapped rich text with markup |
| `scroll_by(&region, delta, content_height)` | Apply scroll delta with clamping |
| `scroll_clamp(&region, content_height)` | Clamp offset to valid range |
| `scroll_fraction(&region, content_height)` | Scroll position as 0.0--1.0 |
| `scroll_visible_fraction(&region, content_height)` | Visible fraction (scroll thumb size) |

#### Message Log

| Proc / Type | Purpose |
|-------------|---------|
| `Message_Log` | Struct: timestamped message entries with auto-fade |
| `log_init(&log, fade_time, fade_duration, max_visible)` | Initialize with timing config |
| `log_push(&log, text, color, timestamp)` | Add a new message |
| `draw_message_log(ctx, &log, x, y, size, current_time)` | Draw visible messages with fade |
| `log_visible_count(&log, current_time)` | Count of currently visible messages |

#### Caching

| Proc | Purpose |
|------|---------|
| `cache_text(ctx, text, x, y, size, color)` | Capture vertex data for static text |
| `draw_cached(ctx, &cache)` | Emit cached vertices (fast memcopy) |
| `draw_cached_at(ctx, &cache, x, y)` | Emit at a different position |
| `cache_destroy(&cache)` | Free cached vertex memory |

#### Font Management

| Proc | Purpose |
|------|---------|
| `font_load(path)` | Load a TTF file, returns (Font, bool) |
| `font_load_ascii(font)` | Load glyphs 32--126 |
| `font_load_range(font, first, last)` | Load a codepoint range |
| `font_load_glyph(font, codepoint)` | Load a single glyph |
| `font_load_with_icons(path, icons)` | All-in-one: load + ASCII + icons + process |
| `font_get_kerning(font, left, right)` | Kerning adjustment (em-space) |
| `font_process(font)` | Process glyphs, returns Texture_Pack_Result |
| `fonts_process_shared(ctx)` | Process all fonts into shared atlas |
| `register_font(ctx, slot, font)` | Register font into context slot |
| `font_set_fallback(ctx, slot, fallback_slot)` | Set fallback chain for missing glyphs |
| `use_font(ctx, slot)` | Switch active font slot |
| `active_font(ctx)` | Pointer to current font |
| `unload_font(ctx, slot)` | Free font slot for hot-reloading |
| `svg_load_into_font(font, slot, path)` | Load SVG icon into glyph slot |

#### Context

| Proc | Purpose |
|------|---------|
| `set_ui_scale(ctx, scale)` | Set global UI scale factor |
| `scaled_size(ctx, size)` | Apply UI scale to a font size |
| `active_font_index(ctx)` | Get current active font slot index |
| `set_camera(ctx, x, y)` | Set camera offset for canvas panning |
| `vertex_count(ctx)` | Vertices written this frame |
| `destroy(ctx)` | Free all fonts and glyph data |

### Backend API (all backends)

Every backend exposes this common API surface:

| Proc | Purpose |
|------|---------|
| `init(renderer, ...)` | Create shaders, pipelines, buffers |
| `load_font(renderer, slot, path)` | Load font + upload textures (all-in-one) |
| `load_fonts_shared(renderer, paths)` | Load multiple fonts into shared atlas |
| `upload_font_textures(renderer, slot, pack)` | Upload pre-packed textures (advanced) |
| `upload_shared_textures(renderer, pack)` | Upload shared atlas textures (advanced) |
| `unload_font(renderer, slot)` | Free GPU textures + CPU data |
| `flush(renderer, width, height, scissor?)` | Upload vertices and issue draw calls |
| `destroy(renderer)` | Release all GPU resources |

The Raylib, Karl2D, and Sokol backends also provide `ctx(renderer) -> ^slug.Context`.

The Vulkan and SDL3 GPU backends additionally provide `begin_frame`, `present_frame`, and `use_font` since they manage their own frame lifecycle.

## Shared Font Atlases

Pack all fonts into a single pair of GPU textures. This gives you one texture bind, one draw call, and free font interleaving -- no restriction on `use_font` switching order.

```odin
// Load fonts into context slots
slug.register_font(ctx, 0, font_sans)
slug.register_font(ctx, 1, font_serif)

// Set up fallback chain: missing glyphs in font 0 fall back to font 1
slug.font_set_fallback(ctx, 0, 1)

// Pack all fonts into one shared atlas
pack := slug.fonts_process_shared(ctx)
defer slug.pack_result_destroy(&pack)
backend.upload_shared_textures(renderer, &pack)

// Now you can freely interleave fonts:
slug.draw_text(ctx, "Sans text", ...)
slug.use_font(ctx, 1)
slug.draw_text(ctx, "Serif text", ...)
slug.use_font(ctx, 0)   // switching back is fine!
slug.draw_text(ctx, "Sans again", ...)
```

All backends also provide `load_fonts_shared(renderer, paths)` as a one-liner convenience.

Without shared atlases, each font gets its own texture pair and you must draw all content for each font contiguously -- switching back to a font that already has quads will fail.

## SVG Icon Support

Load SVG icons into unused glyph slots (128+) to render vector art through the same pipeline as text:

```odin
// Before font_process or fonts_process_shared:
slug.svg_load_into_font(&font, 128, "icons/shield.svg")
slug.svg_load_into_font(&font, 129, "icons/sword.svg")

// After processing, draw like any glyph:
slug.draw_icon(ctx, 128, x, y, 48.0, {1, 1, 1, 1})
```

Supports all SVG path commands: M, L, H, V, C, S, Q, T, A, Z (and lowercase relative variants). Cubic Beziers are subdivided into quadratic approximations. Arc commands are converted via SVG spec F.6 formulas.

## Architecture

### Core / Backend Split

The library separates the **GPU-agnostic core** from **thin backends**:

- **Core** (`slug/`): Font loading, Bezier curve extraction, band acceleration, texture data packing, vertex buffer packing, text measurement, effects, rich text, scrolling. Produces raw vertex and texture data for backends to consume. Zero GPU dependencies.

- **Backends** (`slug/backends/*/`): Compile shaders, upload textures, upload vertices, draw. A typical backend is 300--600 lines. The Raylib and Karl2D backends are even thinner -- they wrap the OpenGL backend with GL loader and batch flush handling.

This means:
- New backends need ~300-600 lines of code
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

Two textures per font (or one shared pair):

| Texture | Format | Contents |
|---------|--------|----------|
| Curve | `RGBA16F` | Bezier control points (2 texels per curve) |
| Band | `RG16UI` | Band headers + curve index lists |

Both are sampled with `texelFetch` (integer coordinates, nearest filtering).

## Building

### Prerequisites

- [Odin compiler](https://odin-lang.org/) (includes `vendor:stb/truetype`, `vendor:OpenGL`, `vendor:raylib`, etc.)
- OpenGL 3.3+ capable GPU (for GL-based backends)
- For Vulkan backend: Vulkan SDK + `glslc` shader compiler
- For SDL3 GPU backend: SDL3 + `glslc`
- For Karl2D backend: [Karl2D](https://github.com/nicoepp/karl2d) source
- For Sokol backend: [sokol-odin](https://github.com/floooh/sokol-odin) clone (build C libs first)

### Build Script

```sh
./build.sh check      # Verify all packages compile
./build.sh opengl     # Build OpenGL/GLFW demo
./build.sh raylib     # Build Raylib demo
./build.sh vulkan     # Compile shaders + build Vulkan/SDL3 demo
./build.sh sdl3gpu    # Compile shaders + build SDL3 GPU demo
./build.sh shaders    # Compile GLSL 4.50 -> SPIR-V only (requires glslc)
./build.sh all        # Build all standard examples

# External dependency backends (auto-detect sibling dirs, or set paths):
./build.sh karl2d     # Auto-detects ../karl2d/, or: KARL2D_PATH=/path/to ./build.sh karl2d
./build.sh sokol      # Auto-detects ../sokol-odin/sokol/, or: SOKOL_PATH=/path/to/sokol ./build.sh sokol

./build.sh clean      # Remove build artifacts
```

### Manual Build

```sh
# Check that packages compile
odin check slug/ -no-entry-point
odin check slug/backends/opengl/ -no-entry-point
odin check slug/backends/raylib/ -no-entry-point
odin check slug/backends/vulkan/ -no-entry-point
odin check slug/backends/sdl3gpu/ -no-entry-point
odin check slug/backends/karl2d/ -no-entry-point
odin check slug/backends/sokol/ -no-entry-point -collection:sokol=$SOKOL_PATH

# Build examples
odin build examples/demo_opengl/ -out:demo_opengl -collection:libs=.
odin build examples/demo_raylib/ -out:demo_raylib -collection:libs=.

# Vulkan (requires glslc for shader compilation)
./build.sh shaders
odin build examples/demo_vulkan/ -out:demo_vulkan -collection:libs=.

# SDL3 GPU (also requires compiled shaders)
odin build examples/demo_sdl3gpu/ -out:demo_sdl3gpu -collection:libs=.

# Karl2D (external dependency)
odin build examples/demo_karl2d/ -out:demo_karl2d -collection:libs=. -collection:karl2d=$KARL2D_PATH

# Sokol GFX (external dependency)
odin build examples/demo_sokol/ -out:demo_sokol -collection:libs=. -collection:sokol=$SOKOL_PATH
```

### Demo Controls

| Input | Action |
|-------|--------|
| ESC | Quit |
| Up / Down | Adjust UI scale |
| Tab | Toggle zoom-to-fit |
| WASD | Camera pan |
| Middle mouse drag | Camera pan |
| R | Reset camera |
| Mouse wheel | Zoom (over canvas) or scroll (over scroll region) |
| Left / Right arrows | Move cursor in cursor demo |
| Left click | Position cursor in cursor demo |

### Platform Notes

**Linux** (tested): Install Odin per [odin-lang.org](https://odin-lang.org/docs/install/). Build the stb vendor lib if needed:
```sh
make -C $(odin root)/vendor/stb/src unix
```
GLFW, Raylib, and OpenGL vendor libraries ship with Odin. For Vulkan/SDL3 GPU: install `vulkan-devel shaderc sdl3` (Arch) or `libvulkan-dev glslc libsdl3-dev` (Debian/Ubuntu).

**Windows** (community tested): Install Odin. From a Developer Command Prompt:
```cmd
cd %ODIN_ROOT%\vendor\stb\src
nmake -f Windows.mak
```
Vendor libraries (OpenGL, GLFW, Raylib) are included. Vulkan SDK from [lunarg.com](https://vulkan.lunarg.com/) if using Vulkan. Raylib backend may need `-define:RAYLIB_SHARED=true` on some setups.

**macOS** (untested): Install Odin. Build stb vendor lib: `make -C $(odin root)/vendor/stb/src unix`. OpenGL backend works (macOS supports OpenGL 4.1). Vulkan requires MoltenVK. Not yet tested -- please report issues.

### Troubleshooting

**Linker errors mentioning `stb_truetype` symbols** -- Build the stb vendor library first (see platform notes above).

**Font not found / no text visible** -- Demos load fonts from `examples/assets/fonts/` with relative paths. Run from the project root.

**OpenGL errors on startup** -- Ensure your GPU supports OpenGL 3.3+. On Linux: `glxinfo | grep "OpenGL version"`.

**Raylib GL loader returns NULL on Windows** -- Try building with `-define:RAYLIB_SHARED=true`.

## Dependencies

| Dependency | Source | Used By |
|------------|--------|---------|
| `vendor:stb/truetype` | Ships with Odin | Core (TTF parsing) |
| `vendor:OpenGL` | Ships with Odin | OpenGL, Raylib, Karl2D backends |
| `vendor:vulkan` | Ships with Odin | Vulkan backend |
| `vendor:sdl3` | Ships with Odin | Vulkan and SDL3 GPU backends (windowing) |
| `vendor:glfw` | Ships with Odin | OpenGL demo only |
| `vendor:raylib` | Ships with Odin | Raylib demo only |
| [sokol-odin](https://github.com/floooh/sokol-odin) | External | Sokol backend + demo |
| [Karl2D](https://github.com/nicoepp/karl2d) | External | Karl2D backend + demo |

## License

MIT. See [LICENSE](LICENSE).

### Patent Status

The Slug algorithm was patented by Eric Lengyel (US Patent 10,936,792). On March 17, 2026, Lengyel dedicated the patent to the public domain via a Terminal Disclaimer. This implementation is free to use in any project.

## AI Disclosure

Built with **Claude Code** (Anthropic's Claude). I provided direction, architecture, and testing; Claude wrote the implementation. The core algorithm was ported from Eric Lengyel's publicly available shader code.

## Roadmap

### v1.0 (current)

- [x] Resolution-independent GPU Bezier text rendering
- [x] SVG vector icon support
- [x] Text wrapping, word/character truncation with custom ellipsis, alignment (left/center/right/justified)
- [x] Rich text markup with inline colors, backgrounds, and icons
- [x] 13 text effects (rainbow, wobble, shake, shadow, outline, pulse, fade, gradient, wave, circular, rotation, typewriter, float)
- [x] Text selection highlighting
- [x] Static text caching
- [x] Scrollable text regions with viewport clipping
- [x] Message log system with auto-fading
- [x] Text input cursor positioning and click hit testing
- [x] UI scaling, camera panning, mouse wheel zoom
- [x] Multi-font with shared atlases and fallback chains
- [x] Kerning, letter spacing (tracking), tab stops, line spacing multiplier
- [x] Subscript/superscript, grid layout (CP437), independent decoration colors
- [x] 6 backends: OpenGL, Raylib, Vulkan, SDL3 GPU, Karl2D, Sokol GFX
- [x] Bordered rectangles, progress bars, blinking cursor
- [x] Rich text wrapping and scrolling with word-wrap + markup
- [x] Columnar layout with per-column widths and alignment
- [x] Wrapped text line count for auto-sizing panels
- [x] GPU scissor clipping with multi-pass flush support

### Later

- [ ] Zoom toward cursor -- camera offset adjustment per zoom step
- [ ] Tooltip system -- positioned text box, auto-flips at screen edges
- [ ] Text input widget -- full edit state, selection, clipboard
- [ ] HarfBuzz integration -- complex script shaping (Arabic, Devanagari, CJK)
- [ ] README screenshots / demo GIFs

## Credits

- **Algorithm**: Eric Lengyel -- [Slug: Resolution-Independent GPU Text](https://jcgt.org/published/0006/02/02/)
- **Reference implementation**: SlugVibes demo (Vulkan + Odin proof-of-concept)
- **SVG icons**: [game-icons.net](https://game-icons.net/) (CC BY 3.0)
- **Fonts**: Liberation font family (SIL Open Font License)
