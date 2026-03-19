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

- [x] **Remove all `fmt.printf`/`println` from core library** — Removed all info prints and error prints from `ttf.odin`, `glyph.odin`, `svg.odin`. Removed `fmt` imports. Procs return `false` to signal errors.
- [x] **Add `register_font(ctx, slot, font)` proc** — Added to `slug.odin`. Replaces the 3-line bookkeeping pattern.
- [x] **Make SVG parser internals private** — All internal procs and `SVG_Parser` struct marked `@(private = "file")`.
- [x] **Make glyph processing internals private** — `sort_curve_indices_by_max_x/y`, `pack_glyph_textures`, `f32_to_f16` are `@(private = "file")`. `glyph_process` is `@(private = "package")` (used by svg.odin).
- [x] **Make vertex packing internals private** — `emit_glyph_quad` and `emit_glyph_quad_transformed` marked `@(private = "package")`.
- [x] **Replace custom `utf8_decode`** — Now uses `core:unicode/utf8.decode_rune_in_string`.
- [x] **`use_font` should detect and reject switching back** — Now returns `bool`, rejects switching to a font that already has quads.

### Medium Priority (API ergonomics)

- [ ] **Add `Color :: [4]f32` type alias** — Used in 15+ proc signatures. Add to `slug.odin` with the type definition. Optionally add helpers like `color_rgb(r, g, b)`, `color_rgba(r, g, b, a)`.
- [x] **Fix naming inconsistency: `process_font` → `font_process`** — Renamed in core, backends, and examples.
- [ ] **Add `load_font_with_icons` convenience proc** — Every demo with SVGs repeats: `font_load` → `font_load_ascii` → `svg_load_into_font` × N → `font_process`. Wrap this.
- [ ] **`Texture_Pack_Result` ownership** — Backend `upload_font_textures` could optionally consume and destroy the pack result, since the GPU has the data at that point.
- [ ] **Add `unload_font(ctx, slot)` proc** — Currently only `destroy()` tears down everything. No way to swap a single font at runtime.
- [ ] **Remove info prints from backends** — `slug_opengl: font slot %d loaded` in opengl.odin, `Font slot %d loaded: %s` in vulkan renderer.

### Low Priority (nice-to-have)

- [ ] **SVG arc commands** — `svg.odin:330-349` parses arc parameters but emits no geometry. Arcs are common in SVG icons.
- [ ] **Extract GL texture creation helper in OpenGL backend** — `load_font` and `upload_font_textures` duplicate the GenTextures/BindTexture/TexParameteri/TexImage2D sequence.
- [ ] **Vulkan backend: remove `zoom`/`pan` from Renderer** — Application-level concern, not library. Should be a user-provided MVP.
- [ ] **Vulkan backend: hardcoded shader paths** — `"slug/shaders/slug_vert.spv"` breaks if run from a different working directory. Should be configurable or embedded.
- [ ] **`hsv_to_rgb` placement** — Currently in `effects.odin`. If a `Color` type is added, consider moving color utilities alongside it.
