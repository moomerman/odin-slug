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
- `slug/shaders/` — GLSL shader source (3.30 + 4.50)
- `examples/` — demo programs

## Build & Check Commands
```sh
# Check core library
odin check slug/ -no-entry-point

# Check backends
odin check slug/backends/opengl/ -no-entry-point
odin check slug/backends/raylib/ -no-entry-point
odin check slug/backends/vulkan/ -no-entry-point

# Build examples
odin build examples/demo_opengl/ -collection:libs=.
odin build examples/demo_raylib/ -collection:libs=.

# Vulkan: compile shaders FIRST, then build
./build.sh shaders
odin build examples/demo_vulkan/ -collection:libs=.
# or: ./build.sh vulkan
```

Always run all four `odin check` commands + build all 3 demos before committing.

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
| Raylib backend (thin wrapper over GL) | `slug/backends/raylib/raylib.odin` |
| GLSL shaders (OpenGL 3.30) | `slug/shaders/*.330.*` |
| GLSL shaders (Vulkan 4.50) | `slug/shaders/*.450.*` |
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
- **All 3 demos (demo_raylib, demo_opengl, demo_vulkan) must showcase every user-facing feature** — no exceptions
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

### Review Pacing
- After implementing each feature, stop and wait for the user to review before starting the next one
- Do not chain multiple features in one session without explicit "looks good, continue" from the user
- Present changes in logical chunks — core types/procs first, then backends, then demos
- Never write code that hasn't been read in this session
