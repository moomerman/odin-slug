# odin-slug — Claude Code Project Instructions

## Project Type
This is a **vibe code** project. Write code directly — do NOT teach/guide mode.

## What This Is
GPU Bezier text rendering library for Odin. Implementation of Eric Lengyel's Slug algorithm.
Extracted from the SlugVibes demo into a reusable, graphics-API-agnostic package.

## Package Structure
- `slug/` — core library (package slug), zero GPU dependencies
- `slug/backends/vulkan/` — Vulkan 1.x backend (package slug_vulkan)
- `slug/backends/opengl/` — OpenGL 3.3 backend (package slug_opengl)
- `slug/backends/sdl3gpu/` — SDL3 GPU backend (package slug_sdl3gpu)
- `slug/backends/karl2d/` — Karl2D backend (package slug_karl2d, wraps OpenGL)
- `slug/backends/d3d11/` — Direct3D 11 backend (package slug_d3d11, Windows only)
- `slug/backends/sokol/` — Sokol GFX backend (package slug_sokol, GL-only GLSL 430)
- `slug/shaders/` — GLSL shader source (3.30 + 4.50 + SDL3 UBO variants)
- `examples/` — demo programs

## Build & Check Commands
```sh
# Check core library
odin check slug/ -no-entry-point

# Check backends
odin check slug/backends/opengl/ -no-entry-point
odin check slug/backends/raylib/ -no-entry-point
odin check slug/backends/vulkan/ -no-entry-point
odin check slug/backends/sdl3gpu/ -no-entry-point
odin check slug/backends/d3d11/ -no-entry-point    # Windows only
odin check slug/backends/karl2d/ -no-entry-point

# Build examples
odin build examples/demo_opengl/ -collection:libs=.
odin build examples/demo_raylib/ -collection:libs=.

# Vulkan: compile shaders FIRST, then build
./build.sh shaders
odin build examples/demo_vulkan/ -collection:libs=.
# or: ./build.sh vulkan

# SDL3 GPU: compile shaders FIRST, then build
./build.sh shaders
odin build examples/demo_sdl3gpu/ -collection:libs=.
# or: ./build.sh sdl3gpu

# D3D11: Windows only, no external deps needed
odin build examples/demo_d3d11/ -collection:libs=.
# or: ./build.sh d3d11

# Karl2D: requires KARL2D_PATH pointing to parent of karl2d/
export KARL2D_PATH=/path/to  # where /path/to/karl2d/ exists
odin build examples/demo_karl2d/ -collection:libs=. -collection:karl2d=$KARL2D_PATH
# or: KARL2D_PATH=/path/to ./build.sh karl2d

# Sokol GFX: requires SOKOL_PATH pointing to sokol/ subdir in sokol-odin
export SOKOL_PATH=/path/to/sokol-odin/sokol
odin build examples/demo_sokol/ -collection:libs=. -collection:sokol=$SOKOL_PATH
# or: SOKOL_PATH=/path/to/sokol-odin/sokol ./build.sh sokol
```

Always run all checks + build all demos before committing. Sokol check requires SOKOL_PATH.

## Key Files — What to Edit for What

| Task | File |
|------|------|
| New text drawing / measurement procs | `slug/text.odin` |
| New per-character animated effects | `slug/effects.odin` |
| Rich text markup (`{color:text}`) | `slug/richtext.odin` |
| Font loading, glyph metrics, kerning | `slug/ttf.odin` |
| Core types, constants, `Context` struct | `slug/slug.odin` |
| OpenGL backend (rect pipeline, flush) | `slug/backends/opengl/opengl.odin` |
| Vulkan backend (pipelines, flush, present_frame) | `slug/backends/vulkan/renderer.odin` |
| SDL3 GPU backend (pipelines, flush, present_frame) | `slug/backends/sdl3gpu/sdl3gpu.odin` |
| D3D11 backend (standalone, HLSL shaders embedded) | `slug/backends/d3d11/d3d11.odin` |
| Karl2D backend (thin wrapper over GL) | `slug/backends/karl2d/karl2d.odin` |
| Sokol GFX backend (standalone GL) | `slug/backends/sokol/sokol.odin` |
| Raylib backend (thin wrapper over GL) | `slug/backends/raylib/raylib.odin` |
| GLSL shaders (OpenGL 3.30) | `slug/shaders/*.330.*` |
| GLSL shaders (Vulkan 4.50) | `slug/shaders/*.450.*` |
| GLSL shaders (SDL3 GPU, UBO variant) | `slug/shaders/*_sdl3.*` |
| Demo layout / draw calls | `examples/demo_*/main.odin` |

## Code Style
- Same conventions as slugvibes (see global CLAUDE.md for Odin conventions)
- Named constants over magic numbers
- Type assertion ok-naming convention: `pd, pd_ok := ...`
- Keep it simple — this is a library, not a framework

## API Rules — Adding Public Procs/Types

This library is designed for others to drop into their projects. Every addition to the
public API must meet these standards:

### Naming
- `noun_verb` pattern for procs: `font_load`, `font_process`, `font_destroy`
- Types are `PascalCase`: `Font`, `Glyph_Data`, `Texture_Pack_Result`
- Constants are `UPPER_SNAKE`: `MAX_FONT_SLOTS`, `BAND_TEXTURE_WIDTH`

### Error Handling
- Return `bool` for fallible operations — never print to stdout/stderr
- No `fmt` imports in library code (core or backends)
- Caller decides how to handle errors, not the library

### Visibility
- Private by default — only expose what users need
- Internal helpers: `@(private = "file")` or `@(private = "package")`
- If a proc is only used within one file, make it file-private
- If used across files in the same package, make it package-private

### Documentation
- Every public proc gets a comment above it explaining what it does
- Document preconditions (e.g., "call AFTER rl.InitWindow()")
- Document ownership (e.g., "caller must call pack_result_destroy")
- Package header comment in the main file of each package

### When Adding New Features
- Check `odin check` on core + all backends + build examples before committing
- New procs in core must work across all backends without changes
- New types that affect the vertex format or texture packing need shader updates too
- **All 7 demos (demo_raylib, demo_opengl, demo_vulkan, demo_sdl3gpu, demo_d3d11, demo_karl2d, demo_sokol) must showcase every user-facing feature** — no exceptions
- Update docs/DESIGN.md if the feature changes architecture

### Demo Layout — Adding New Elements
The demos use a named position table at the top of each `main.odin`. Every coordinate is a named constant — no magic numbers in the draw loop.

**Three columns:**
- Left (x=40): stacked text feature demos, top to bottom
- Center (x=420): animated effects and SVG icons
- Right (x=800): structural demos (zoom, truncate, grid, alignment, wrap, scroll)

**Text sizes (all demos):** TITLE_SIZE=52, BODY_SIZE=34, SMALL_SIZE=24, ICON_SIZE=44

**Left column layout notes:**
- `PANEL_Y` (currently 516) controls where the lower panel box starts
- When adding a new row to the left column **between `ROW_CURSOR_HINT` and the panel**, bump `PANEL_Y` down enough to avoid overlap (typically +30 to +35 per new SMALL_SIZE row)
- All panel content constants (`PANEL_RAINBOW_Y`, `PANEL_WOBBLE_Y`, `PANEL_CACHED_Y`, `SERIF_LINE_Y`) are computed from `PANEL_Y`, so they shift automatically
- The cached label is created before the main loop using `PANEL_CACHED_Y` — it picks up the new value automatically since it's a compile-time constant
- `SCALE_Y = 820` is the bottom anchor (window is 900px); verify `SERIF_LINE_Y` stays below 760 after any shift
- **ROW_HIGHLIGHT (282)** draws only "SELECTED" at BODY_SIZE. **ROW_STATUS (330)** draws the status bg-tags at SMALL_SIZE — they were split because the full row at BODY_SIZE overflows into the center column. Don't recombine them.

**Right column layout notes:**
- Elements stack: ZOOM_Y(250) → TRUNCATE_Y(315) → GRID_Y(380) → ALIGN(65..129) → WRAP_Y(425) → SCROLL_Y(590) → CLIP_BOX_Y(738) → SCALE_Y(820)
- CLIP_BOX_Y(738): GPU scissor demo — 200×44px box, text baseline at CLIP_TEXT_Y(767). Box bottom = 782.
- New right-column items go between ZOOM_Y and GRID_Y (most space) or between GRID and WRAP

## Architecture Gotchas — Hard-Won Lessons

### Kerning in effect procs
Every proc that walks characters in its own loop (effects.odin, any new effect) MUST include kerning. The pattern is identical in all of them — missing it causes irregular spacing:
```odin
prev_rune: rune = 0
for ch in text {
    g := get_glyph(font, ch)
    if g == nil { prev_rune = ch; continue }      // nil glyphs still update prev_rune
    if prev_rune != 0 {
        pen_x += font_get_kerning(font, prev_rune, ch) * font_size
    }
    // ... position and emit glyph ...
    pen_x += g.advance_width * font_size
    prev_rune = ch
}
```
`draw_text` in text.odin is the reference implementation.

### Pulse / scale effects — glyph centering
When scaling a glyph, center on the **glyph's visual center** (`(bbox_min + bbox_max) * 0.5`), NOT the advance slot center. The advance width and bbox are different per glyph; centering on advance gives different offsets per character and breaks spacing. Correct formula:
```odin
em_cx   := (g.bbox_min.x + g.bbox_max.x) * 0.5
em_cy   := (g.bbox_min.y + g.bbox_max.y) * 0.5
glyph_w := (g.bbox_max.x - g.bbox_min.x) * scaled_size
glyph_h := (g.bbox_max.y - g.bbox_min.y) * scaled_size
glyph_x := pen_x + em_cx * font_size - glyph_w * 0.5
glyph_y := y - em_cy * font_size - glyph_h * 0.5
```

### Vulkan NDC Y-axis
Vulkan's NDC Y=+1 is at the BOTTOM of the screen (opposite of OpenGL). The orthographic projection for Vulkan is:
```odin
linalg.matrix_ortho3d_f32(0, w, 0, h, -1, 1)  // correct: y=0 top, y=h bottom
linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)  // WRONG: flips everything vertically
```
Both the rect pipeline and the Slug text pipeline use the Vulkan convention. OpenGL uses the inverted form.

### SDL3 GPU NDC Y-axis
SDL3 GPU normalizes NDC Y+ up across ALL platform backends (Vulkan, D3D12, Metal) — it handles the Vulkan Y-flip internally. This means SDL3 GPU uses the same projection as OpenGL:
```odin
linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)  // correct: same as OpenGL
linalg.matrix_ortho3d_f32(0, w, 0, h, -1, 1)  // WRONG: would flip vertically
```
Do NOT copy the Vulkan projection when writing SDL3 GPU code — it will render upside down.

### D3D11 NDC Y-axis and scissor
D3D11 clip space Y+ is up (same as OpenGL). Uses the same projection:
```odin
linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)  // same as OpenGL
```
D3D11 depth range is [0,1] not [-1,1], but irrelevant since depth testing is off.
D3D11 `RSSetScissorRects` uses top-left origin Y-down — matches screen coords directly. No Y-flip needed (unlike OpenGL's `glScissor` which is Y-up from bottom-left).

### D3D11 HLSL shaders — embedded, runtime compiled
The D3D11 backend embeds HLSL shader source as string constants (no separate files). Shaders are compiled at init time via `d3d_compiler.Compile()` targeting `vs_5_0`/`ps_5_0`. HLSL cbuffers use `column_major float4x4` so GLSL matrix extraction logic works unchanged. Key GLSL→HLSL mappings: `floatBitsToUint`→`asuint`, `texelFetch`→`.Load(int3(x,y,0))`, `flat`→`nointerpolation`.

### D3D11 backend — caller-owned device
The D3D11 backend receives `^d3d11.IDevice` + `^d3d11.IDeviceContext` from the caller. It does NOT create device, swapchain, or render target. `flush()` also takes the caller's `^d3d11.IRenderTargetView`. This mirrors the SDL3 GPU backend pattern. The `destroy` proc releases all backend-created COM objects but NOT the caller's device/context.

### SDL3 GPU push constants → UBOs
SDL3 GPU's `PushGPUVertexUniformData` maps to uniform buffer objects, NOT Vulkan push constants. Shaders that use `layout(push_constant)` will silently receive all-zero uniforms. The SDL3 GPU backend has its own shader variants (`*_sdl3.*`) using `layout(set = 1, binding = 0) uniform UBO` for vertex uniforms and `layout(set = 2, binding = N)` for fragment samplers.

### Karl2D batch flush callback
Karl2D is a third-party package (not an Odin vendor lib), so the Karl2D backend cannot import it directly. Instead, the caller passes `k2.draw_current_batch` as a callback to `init()`. This is the equivalent of `rlgl.DrawRenderBatchActive()` in the Raylib backend. Karl2D does NOT cache GL state, so no state invalidation is needed after slug's flush.

### Sokol GFX — external dependency and GLSL 430
Sokol GFX is NOT an Odin vendor package. It requires `sokol-odin` (github.com/floooh/sokol-odin) provided via `-collection:sokol=`. The backend uses GLSL 430 shaders with uniforms packed into `vec4[]` arrays (matching the sokol-shdc convention). Currently GL-only; cross-platform (Metal/D3D11/WebGPU) would require sokol-shdc integration for pre-compiled shader bytecode.

### Sokol GFX — append_buffer for multi-flush
Sokol's `sg.update_buffer()` can only be called ONCE per buffer per frame. The Sokol backend uses `sg.append_buffer()` instead, which supports multiple appends per frame. This enables multiple flush calls (e.g. for scissored passes) within a single `sg.begin_pass/end_pass` block. The returned byte offset is passed via `vertex_buffer_offsets`.

### Sokol GFX — no pass management in flush
The Sokol backend's `flush()` only issues `apply_pipeline / apply_bindings / draw` calls — it does NOT call `sg.begin_pass()` or `sg.end_pass()`. The caller is responsible for pass management. This is different from the Vulkan backend which owns the entire frame lifecycle.

### Karl2D build — collection path
Karl2D uses `import k2 "karl2d:karl2d"`. The `-collection:karl2d=` flag must point to the **parent** directory of the karl2d/ folder, not to karl2d/ itself. Example: if Karl2D is at `/home/user/libs/karl2d/`, use `-collection:karl2d=/home/user/libs`.

### Rect draw order
`draw_rect` appends to `ctx.rect_vertices[]`. Backends draw ALL rects in a single flat-color pass BEFORE the Slug glyph pass — so rects are always behind text, regardless of call order within a frame. You cannot draw a rect on top of glyphs in the same frame.

### Raylib backend inherits OpenGL rect support
`slug/backends/raylib/raylib.odin` uses `using gl_renderer` — it gets the GL rect pipeline for free. No changes needed there when adding rect-related features to the OpenGL backend.

### begin(ctx) required before cache_text
`cache_text` writes into `ctx.vertices[]`. Call `slug.begin(ctx)` before calling it (even outside the main loop), as `begin` initializes `quad_count`. The demo does this once before the loop to build static cached labels.

### Hard limits
```odin
MAX_RECTS       :: 512   // rect_vertices capacity (slug/slug.odin)
MAX_GLYPH_QUADS :: 4096  // glyph quad capacity per frame
MAX_FONT_SLOTS  :: 4     // font registry slots
```
If adding features that generate rects (e.g. decorations on wrapped text), watch the rect budget.

### Slug Algorithm — Texture Layout and Band Optimization (Eric Lengyel)

These are core implementation details from the algorithm's author. They govern how
`slug/ttf.odin` packs glyph data into the curve and band textures.

**Curve texture** — RGBA16F (4 × 16-bit half-float):
- Stores control point coordinates `(x1, y1, x2, y2)` per texel.
- One quadratic Bézier curve uses two texels: the first texel holds the first two
  control points packed as `(x1, y1, x2, y2)`, the third control point goes in the
  first two channels of the next texel.
- Connected curves in a contour share an endpoint, so the second texel of one curve
  is also the first texel of the next curve. This is a data-sharing optimization —
  don't duplicate endpoints.

**Band texture** — RG16UI (2 × 16-bit unsigned integer):
- A glyph can have any number of horizontal and vertical bands. Choose band count to
  minimize the maximum number of curves in any single band.
- When determining which curves fall into each band, use an epsilon (~1/1024 em-space)
  to make bands overlap slightly. This prevents edge-case misses at band boundaries.
- Curves within each band must be sorted in **descending** order of their maximum
  x-coordinate (horizontal bands) or y-coordinate (vertical bands).

**Band optimizations** (reduce texture size + improve cache):
- Each band for a single glyph must have the same thickness.
- If two or more adjacent bands contain the same set of curves, point all of them to
  the same data (deduplication).
- If one band's curves are a contiguous subset of another band's, point the smaller
  band into the larger band's data (subset sharing).

**Curve filtering rules:**
- Straight horizontal lines must NEVER be included in horizontal bands.
- Straight vertical lines must NEVER be included in vertical bands.
- These curves contribute nothing to the winding number for rays parallel to them.

**Pixel-grid alignment (no hinting needed):**
- Read `sCapHeight` from the font's OS/2 table.
- Choose font sizes such that `font_size × sCapHeight` is an integer (in pixels,
  accounting for monitor DPI).
- This aligns cap-height glyphs to the pixel grid, giving crisp tops and bottoms
  without traditional font hinting.

### Plans and Research Output
- Write plans, research docs, and backend integration notes to `.claude/plans/` (inside the repo root).
- This directory is gitignored (under `.claude/`) so nothing gets committed.
- Do NOT write to `~/.claude/plans/` — that path is outside the repo and background agents cannot write there without manual permission approval.

### Review Pacing
- After implementing each feature, stop and wait for the user to review before starting the next one
- Do not chain multiple features in one session without explicit "looks good, continue" from the user
- Present changes in logical chunks — core types/procs first, then backends, then demos
- Never write code that hasn't been read in this session
