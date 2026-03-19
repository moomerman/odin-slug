# odin-slug Cleanup Plan

Tracked issues to address, roughly in priority order.

## Bug Fixes

- [ ] **Raylib backend: replace `vendor:glfw` with `dlsym`** — Root cause of invisible text. `vendor:glfw` links to a separate GLFW instance from Raylib's internal one. Use `dlsym(RTLD_DEFAULT, name)` to load GL proc addresses from the already-loaded GL library. (Other agent is working on this)
- [ ] **Remove debug prints from OpenGL/Raylib backends** — The other agent added per-frame `fmt.println` calls in `opengl.odin` (lines ~474-508) and `raylib.odin` (lines ~80-106). Remove once the raylib fix is confirmed.

## Repo / Docs

- [x] **Fix `.gitignore` anchoring** — `demo_opengl` etc. now `/demo_opengl` so demo source dirs aren't ignored
- [x] **Fix patent number in DESIGN.md** — Was `10,373,352`, now matches README's `10,936,792`
- [x] **Mark Windows/macOS as untested in README**
- [ ] **Commit the three demo source files** — `examples/demo_opengl/main.odin`, `demo_raylib/`, `demo_vulkan/` are untracked
- [ ] **Add screenshots to README** — After cleanup is done
- [ ] **Update DESIGN.md Raylib section** — Once the `dlsym` fix lands, the "GL Loader Gotcha" section needs updating

## API Cleanup — Core Library

### High Priority (correctness / usability)

- [ ] **Remove all `fmt.printf`/`println` from core library** — `ttf.odin` (3 info prints), `glyph.odin` (1 in `pack_glyph_textures`), `svg.odin` (1 in `svg_parse`). A reusable library should be silent. Error prints (`fmt.eprintln`) in the core should become return values.
- [ ] **Add `register_font(ctx, slot, font)` proc** — Replace the 3-line internal bookkeeping pattern (`ctx.fonts[0] = font; ctx.font_loaded[0] = true; ctx.font_count = ...`) that every demo repeats.
- [ ] **Make SVG parser internals private** — `SVG_Parser`, `svg_execute_command`, `svg_parse_path_data`, `svg_skip_ws`, `svg_is_command`, `svg_is_number_start`, `svg_parse_number`, `svg_to_em`, `svg_emit_line`, `svg_emit_quadratic`, `svg_emit_cubic`, `svg_compute_bbox`, `parse_f32` should all be `@(private = "file")`.
- [ ] **Make glyph processing internals private** — `sort_curve_indices_by_max_x`, `sort_curve_indices_by_max_y`, `glyph_process`, `pack_glyph_textures`, `f32_to_f16` should be `@(private = "file")` or `@(private = "package")`.
- [ ] **Make vertex packing internals private** — `emit_glyph_quad` and `emit_glyph_quad_transformed` should be `@(private = "package")` — they're used by effects.odin but shouldn't be user-facing.
- [ ] **Replace custom `utf8_decode`** — `effects.odin:330-349` reimplements UTF-8 decoding. Use Odin's built-in rune iteration or `core:unicode/utf8` instead.
- [ ] **`use_font` should detect and reject switching back** — Currently silently corrupts the batch layout. Should return `bool` or assert.

### Medium Priority (API ergonomics)

- [ ] **Add `Color :: [4]f32` type alias** — Used in 15+ proc signatures. Add to `slug.odin` with the type definition. Optionally add helpers like `color_rgb(r, g, b)`, `color_rgba(r, g, b, a)`.
- [ ] **Fix naming inconsistency: `process_font` → `font_process`** — All other font procs use `font_verb` pattern.
- [ ] **Add `load_font_with_icons` convenience proc** — Every demo with SVGs repeats: `font_load` → `font_load_ascii` → `svg_load_into_font` × N → `process_font`. Wrap this.
- [ ] **`Texture_Pack_Result` ownership** — Backend `upload_font_textures` could optionally consume and destroy the pack result, since the GPU has the data at that point.
- [ ] **Add `unload_font(ctx, slot)` proc** — Currently only `destroy()` tears down everything. No way to swap a single font at runtime.
- [ ] **Remove info prints from backends** — `slug_opengl: font slot %d loaded` in opengl.odin, `Font slot %d loaded: %s` in vulkan renderer.

### Low Priority (nice-to-have)

- [ ] **SVG arc commands** — `svg.odin:330-349` parses arc parameters but emits no geometry. Arcs are common in SVG icons.
- [ ] **Extract GL texture creation helper in OpenGL backend** — `load_font` and `upload_font_textures` duplicate the GenTextures/BindTexture/TexParameteri/TexImage2D sequence.
- [ ] **Vulkan backend: remove `zoom`/`pan` from Renderer** — Application-level concern, not library. Should be a user-provided MVP.
- [ ] **Vulkan backend: hardcoded shader paths** — `"slug/shaders/slug_vert.spv"` breaks if run from a different working directory. Should be configurable or embedded.
- [ ] **`hsv_to_rgb` placement** — Currently in `effects.odin`. If a `Color` type is added, consider moving color utilities alongside it.
