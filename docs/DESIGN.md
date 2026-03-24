# odin-slug Design Document

## Why This Library Exists

The Slug algorithm (Eric Lengyel, 2017) is one of the best approaches to GPU text rendering ever published. It evaluates quadratic Bezier curves per-pixel in the fragment shader, producing mathematically perfect text at any size, rotation, or zoom level. No texture atlases, no SDF artifacts, no mipmaps.

The algorithm's US patent (10,936,792) was dedicated to the public domain by Eric Lengyel via a Terminal Disclaimer on March 17, 2026, making it freely usable. This library implements Slug in Odin as a reusable package that any project can drop in.

## Architecture: Why Core + Backends

The most important design decision in odin-slug is the split between a **GPU-agnostic core** and **thin GPU backends**.

### The Problem

In the original SlugVibes demo, text rendering was tightly coupled to Vulkan. Every struct held Vulkan handles, every function touched GPU state. You couldn't use the text renderer without pulling in the entire Vulkan stack — not in an OpenGL project, not in a Raylib game, not in a headless test.

### The Solution

The core library (`slug/`) handles everything that doesn't need a graphics API:

- Font loading and glyph extraction (TTF parsing via stb_truetype)
- Bezier curve extraction and cubic-to-quadratic conversion
- Band acceleration (spatial partitioning for the fragment shader)
- Texture data packing (raw float16/uint16 arrays, not GPU textures)
- CPU-side vertex packing for glyph quads
- Text measurement and layout
- Text effects (rainbow, wobble, shake, rotation, etc.)

Backends (`slug/backends/*/`) are thin wrappers that take the core's output and render it:

- Compile the appropriate shader variant
- Upload texture data to GPU textures
- Upload vertex data from `ctx.vertices[]`
- Issue draw calls

The OpenGL backend is ~580 lines (including the inline GLSL shaders). The Vulkan backend is larger (~1700 lines across two files) because Vulkan itself demands more boilerplate, but the slug-specific logic in each backend is still a small fraction of the total. The Raylib backend (`slug/backends/raylib/`) demonstrates just how thin a wrapper can be: ~85 lines that wraps the OpenGL backend, handling the GL loader gotcha and Raylib batch flushing automatically. A new backend for a modern API like Metal or WebGPU would likely land somewhere in between, since the hard work all happens in the core.

### Why This Split Is Optimal

1. **Portability**: Adding a new graphics API means writing one file, not refactoring the whole library.
2. **Raylib compatibility**: The OpenGL backend works alongside Raylib's internal GL state — just flush Raylib's batch first.
3. **Testability**: Core logic can be tested without a GPU context.
4. **Custom pipelines**: Advanced users can read `ctx.vertices[:]` directly and integrate into their own rendering pipeline.
5. **Reduced coupling**: A Vulkan project doesn't link OpenGL code and vice versa.

## The Context Struct: CPU Vertex Buffer

```odin
Context :: struct {
    fonts:           [MAX_FONT_SLOTS]Font,
    font_loaded:     [MAX_FONT_SLOTS]bool,
    font_count:      int,
    active_font_idx: int,
    shared_atlas:    bool,                   // set by fonts_process_shared()
    vertices:        [MAX_GLYPH_VERTICES]Vertex,
    quad_count:      u32,
    font_quad_start: [MAX_FONT_SLOTS]u32,   // unused in shared_atlas mode
    font_quad_count: [MAX_FONT_SLOTS]u32,   // unused in shared_atlas mode
}
```

The `vertices` array lives on the CPU. Every `draw_text` / `draw_icon` call writes glyph quads into this array. The backend reads it each frame and uploads to the GPU.

**Why not a GPU-mapped buffer?**

In SlugVibes (Vulkan), the vertex buffer was memory-mapped — the CPU wrote directly to GPU-visible memory. This is Vulkan-specific. OpenGL doesn't expose persistent mapping the same way, and Raylib users certainly can't manage Vulkan memory.

A CPU-side array is the simplest abstraction that works for every backend. The upload cost is negligible — at 80 bytes per vertex and 4 vertices per glyph, even 1000 visible glyphs is only 320KB. That's a single `glBufferSubData` or `vkCmdCopyBuffer` call per frame.

## Vertex Format: 80 Bytes of Per-Pixel Data

Each glyph is a screen-space quad (4 vertices). The vertex format packs everything the fragment shader needs to evaluate Bezier curves:

| Attribute | Contents | Why |
|-----------|----------|-----|
| `pos` (vec4) | Screen XY + dilation normal | Position + anti-aliasing expansion |
| `tex` (vec4) | Em-space UV + packed glyph location | Maps pixels to curve space + tells shader where this glyph's data lives in the textures |
| `jac` (vec4) | 2x2 inverse Jacobian | Transforms screen-space derivatives to em-space for correct antialiasing under rotation/scale |
| `bnd` (vec4) | Band transform (scale + offset) | Maps em-space coordinates to band indices |
| `col` (vec4) | RGBA color | Per-vertex color for effects |

**Why pack the Jacobian per-vertex?**

For axis-aligned text, the Jacobian is just `[em_width/screen_width, 0, 0, -em_height/screen_height]`. Simple. But for rotated or transformed text, the Jacobian encodes the full inverse transform from screen space back to em space. This is what makes rotated text render correctly — the fragment shader needs to know the relationship between pixel movement and curve-space movement for proper antialiasing.

**Why pack glyph location into tex.zw?**

Two u16 values (x, y coordinates into the band texture) are bit-packed into a single f32 via `transmute`. This avoids adding another vertex attribute — the shader unpacks them with `floatBitsToUint`. It's a space-saving trick from the original Slug paper.

## Band Acceleration: O(n) → O(n/√n)

The naive approach to GPU Bezier rendering would be: for every pixel, evaluate every curve in the glyph and sum winding numbers. For a glyph like 'B' with ~20 curves, that's 20 evaluations per pixel. For complex glyphs or CJK characters with 100+ curves, it becomes expensive.

**Bands** are the solution. Each glyph's bounding box is divided into horizontal and vertical strips (bands). Each band records only the curve indices that overlap it. The fragment shader:

1. Determines which horizontal and vertical band the current pixel falls in
2. Fetches only the curve indices for those two bands
3. Evaluates only those curves

For a glyph with N curves divided into √N bands, each band contains roughly √N curves. The fragment shader evaluates ~2√N curves instead of N — a significant win for complex glyphs.

### Band Count Selection

```odin
band_count := max(1, int(math.sqrt(f32(num_curves)) * 2.0))
```

The `* 2.0` factor over-partitions slightly. More bands = smaller curve lists per band = less fragment shader work, at the cost of more band texture data. The factor of 2 is a good empirical balance.

### Band Sorting

Curves within each band are sorted by their maximum extent in descending order (max X for horizontal bands, max Y for vertical bands). This enables the fragment shader's early-exit optimization: curves with the largest extent come first. Once the shader reaches a curve whose maximum extent is entirely behind the current pixel (all control points on the negative side), every remaining curve in that band is also behind it, so the shader breaks out of the loop.

## GPU Textures: Curve + Band

Two textures per font (or one shared pair with shared font atlases), sampled with `texelFetch` (integer coordinates, no filtering):

### Curve Texture (RGBA16F)

Stores Bezier control points. Each curve uses 2 texels:
- Texel 0: `(p1.x, p1.y, p2.x, p2.y)` — start point + control point
- Texel 1: `(p3.x, p3.y, 0, 0)` — end point

Float16 gives ~3 decimal digits of precision in em-space coordinates, which is more than sufficient for glyph outlines (typically in the 0.0-1.0 range).

### Band Texture (RG16UI)

Stores band headers and curve index lists. For each glyph:
1. **H band headers** (one texel each): `(curve_count, data_offset)`
2. **V band headers** (one texel each): `(curve_count, data_offset)`
3. **H curve index list**: `(curve_tex_x, curve_tex_y)` — pointers into the curve texture
4. **V curve index list**: same format

The data_offset in each band header is relative to the glyph's base position in the texture, so the shader computes `glyph_base + band_count + data_offset` to find the curve list.

### Packing Strategy

Both textures are 4096 texels wide (matching `BAND_TEXTURE_WIDTH`). Glyphs are packed left-to-right. When a glyph's data would overflow the row, the packer pads the remainder and wraps to the next row.

This is deliberately simple. A more sophisticated packer could use best-fit bin packing, but for typical use cases (ASCII + a few icons), glyphs fit in 1-2 rows of each texture. The simplicity matters more than optimal packing.

## Font Slot System

The library supports up to 4 simultaneously loaded fonts (`MAX_FONT_SLOTS`). Two texture modes are available:

### Shared Font Atlases (Recommended)

`fonts_process_shared(ctx)` packs all registered fonts' glyphs into a single pair of curve/band textures. This is the recommended approach for multi-font setups because:

1. **One draw call** — the backend binds one texture pair and draws all quads in one call
2. **Free font interleaving** — `use_font()` has no switching restrictions; mix fonts freely
3. **Fewer GPU resources** — 2 textures total instead of 2 per font

This works because each glyph vertex already carries its own texture coordinates (`curve_tex_x/y`, `band_tex_x/y`). The shader doesn't care which font a glyph belongs to — it just looks up whatever coordinates the vertex says. So packing multiple fonts into one texture is transparent to the shader.

When `shared_atlas` is true, `use_font()` simply switches which Font struct is used for metrics/glyph lookup. The per-font quad range tracking (`font_quad_start/count`) is unused.

### Per-Font Textures (Legacy)

Without shared atlases, each font gets its own texture pair. The backend issues one draw call per font, binding that font's textures. This requires contiguous drawing per font:

```odin
// Correct: all font 0 draws, then all font 1 draws
slug.draw_text(ctx, "Font 0 text", ...)
slug.use_font(ctx, 1)
slug.draw_text(ctx, "Font 1 text", ...)

// WRONG: switching back to font 0 after font 1 has quads
slug.use_font(ctx, 0)  // returns false, would corrupt batch layout
```

Why this constraint? To batch efficiently, we record `(start_quad, quad_count)` per font. If you interleave fonts, the ranges overlap and the wrong textures get bound for some quads. Shared atlases eliminate this problem entirely.

## Text Effects: Transform at the Vertex Level

All text effects (rainbow, wobble, shake, rotation, circular, wave) work the same way:

1. Iterate through characters
2. For each character, compute a position offset or color modification
3. Call `emit_glyph_quad` or `emit_glyph_quad_transformed` with the modified parameters

Effects never touch the fragment shader. The Bezier evaluation is the same regardless of whether text is wobbling, rotating, or rainbow-colored. This is because the effects modify *where* and *what color* each glyph quad is, not *how* the curves are evaluated.

The `emit_glyph_quad_transformed` variant handles rotation by encoding the full 2x2 transform into the inverse Jacobian. This is the elegant part: the same Jacobian that the fragment shader uses for antialiasing also encodes the rotation, so rotated text gets correct antialiasing for free.

## SVG Icons: Same Pipeline

SVG icons are parsed into the same `Glyph_Data` format as font glyphs. An SVG path's Bezier curves are stored in unused glyph slots (128+), processed with the same band acceleration, packed into the same textures.

This means:
- Icons render at any size/rotation with the same quality as text
- No separate icon rendering pipeline
- Icons can use text effects (rainbow icon, wobbling icon, etc.)

Cubic Bezier curves from SVG are automatically subdivided into quadratic approximations, since the Slug fragment shader only evaluates quadratics.

## GLSL Shader Variants

Two shader variants, identical math:

- **GLSL 4.50** (`slug_450.*`): Uses push constants. For Vulkan.
- **GLSL 3.30** (`slug_330.*`): Uses uniforms. For OpenGL 3.3 / Raylib.

The fragment shader algorithm:
1. Receive interpolated em-space coordinates and band transform
2. Compute which horizontal and vertical band the pixel falls in
3. Fetch curve indices for both bands from the band texture
4. For each curve: compute winding number contribution (Bezier root-finding)
5. Sum winding numbers → if non-zero, pixel is inside the glyph
6. Apply antialiasing using screen-space derivatives (from the Jacobian)
7. Output coverage * vertex color

The shader combines horizontal and vertical coverage estimates for antialiasing. For each band direction, it computes root intersections using the quadratic formula, converts those to screen-space pixel offsets, and accumulates signed coverage (via clamped winding contributions) and edge weight (how close the nearest root is). The final coverage blends directional contributions based on their weights, producing smooth edges without MSAA.

## Raylib Integration: The GL Loader Problem

When using slug with Raylib, Odin's `vendor:OpenGL` function pointers must be loaded explicitly. Raylib uses its own internal GLAD loader, which populates Raylib's internal GL function pointers — but `vendor:OpenGL` has separate function pointers that default to null. Without loading them, every GL call in slug's OpenGL backend (shader compilation, texture creation, draw calls) dereferences null function pointers and segfaults.

The naive fix is `gl.load_up_to(3, 3, glfw.gl_set_proc_address)` — but this creates a dependency on `vendor:glfw`, which links to the system's GLFW shared library. Raylib bundles its own GLFW internally. On Linux, this means two separate GLFW instances in the same process; on Windows, `vendor:glfw` may not even find a GLFW library at all. Either way, the function pointers come back NULL.

The correct fix is to load GL function addresses directly from the GL library that's already in the process — the one Raylib loaded when it created the GL context. On Linux/macOS, `dlsym(RTLD_DEFAULT, name)` searches all loaded shared objects. On Windows, `wglGetProcAddress` + fallback to `GetProcAddress(opengl32.dll)` covers both extension and core GL functions. The Raylib backend uses platform-specific files (`gl_loader_linux.odin`, `gl_loader_windows.odin`) to implement this.

The `Renderer` struct must also be heap-allocated with `new()` — `slug.Context` contains a `[16384]Vertex` array (80 bytes each = ~1.3MB), which overflows the default stack.

**If you use `slug/backends/raylib/`**, you don't need to worry about any of this. The Raylib backend loads GL procs during `init` and calls `rlgl.DrawRenderBatchActive` during `flush`, so both gotchas are handled automatically.

## Why stb_truetype (and its Limitations)

The library uses `vendor:stb/truetype` for TTF parsing. This ships with Odin — zero external dependencies.

**Limitation**: stb_truetype only reads the legacy `kern` table, not the modern GPOS table. Most fonts include both for backwards compatibility, but some modern fonts only have GPOS. If kerning doesn't work with a particular font, check whether it has a `kern` table (use `fontTools` or `ttx` to inspect).

Liberation Sans, the bundled font, has 908 kern pairs in its `kern` table, so it works well for demos.

## Constants and Tuning

All magic numbers are named constants:

| Constant | Value | Rationale |
|----------|-------|-----------|
| `BAND_TEXTURE_WIDTH` | 4096 | Maximum texture width widely supported. Matches `kLogBandTextureWidth` in shader. |
| `INITIAL_GLYPH_CAPACITY` | 256 | Initial glyph map size. Covers ASCII + Latin-1 + icon slots. Grows dynamically for CJK. |
| `MAX_GLYPH_QUADS` | 4096 | ~4K visible glyphs per frame. ~1.3MB vertex data (4 verts * 80 bytes each). Increase if needed. |
| `MAX_FONT_SLOTS` | 4 | Most apps use 1-3 fonts. 4 covers bold/italic variants. |
| `DILATION_SCALE` | 1.0 | Pixels of quad expansion for antialiasing border. |

## Future Considerations

Things that could be added without changing the core architecture:

- **Glyph caching across frames**: Currently all vertices are rebuilt every frame. A dirty-flag system could skip unchanged text.
- **Dynamic glyph loading**: Load glyphs on demand instead of all-ASCII upfront. Needed for CJK/Unicode.
- **Subpixel positioning**: Offset glyph quads by fractional pixels for LCD-quality spacing.
- **Text shaping**: Integrate HarfBuzz for complex scripts (Arabic, Devanagari). Would replace the simple left-to-right layout in `draw_text`.
- **Instanced rendering**: One draw call per glyph type instead of one quad per glyph instance. Reduces vertex data for repeated characters. Particularly impactful for text-heavy apps like roguelikes.
