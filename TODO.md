# odin-slug — TODO

Tracks both the feature roadmap and polish/cleanup work.
Update after each session.

Last updated: 2026-03-23 (session 6)

---

## Completed

- [x] Text highlighting / background color rects (`draw_rect`, `draw_text_highlighted`)
- [x] Ellipsis truncation (`draw_text_truncated`)
- [x] Underline / strikethrough (`draw_text_underlined`, `draw_text_strikethrough`)
- [x] Font fallback chains (`font_set_fallback`, `get_glyph_fallback`)
- [x] Per-character transform callback (`Glyph_Xform`, `draw_text_transformed`)
- [x] Inline icons in rich text flow (`{icon:N}` and `{icon:N:color}` markup tags)
- [x] Hit testing (`text_hit_test`)
- [x] Named styles / `Text_Style` struct (`draw_text_styled`, `measure_text_styled`)
- [x] Justified alignment (`draw_text_justified`)
- [x] Subscript / superscript (`draw_text_sub`, `draw_text_super`, `SUB_SCALE/SHIFT/SUPER_SHIFT` constants)
- [x] GPU scissor clipping (`Scissor_Rect`, optional `scissor` param on `flush` / `present_frame`; multi-pass per frame)
- [x] Camera pan (`camera_x/y` in `Context`, `set_camera(ctx, x, y)`; WASD + middle-mouse drag in demos, R to reset, scissor adjusted by cam offset)

---

## Polish / Cleanup
*Items from the 2026-03-22 codebase review. Fix these opportunistically — before or alongside features.*

### Documentation
- [ ] `draw_icon` — add precondition comment: active font must be set via `use_font()`; icon glyphs
      should live in slots 128+ via `svg_load_into_font()`
- [ ] `cache_text` — add precondition comment: `slug.begin(ctx)` must be called first to initialize
      `quad_count`, even outside the main loop
- [ ] `measure_text` / `measure_text_wrapped` — note in comment that these use the specified font
      only (no fallback chain), so results won't account for glyphs resolved via `font_set_fallback`
- [ ] `font_set_fallback` — add cross-reference: "shared atlas is enabled automatically by
      `fonts_process_shared()`; fallback is silently skipped in per-font atlas mode"

### API additions
- [ ] `active_font_index(ctx) -> int` — introspection proc so callers can query which slot is
      currently active without tracking it themselves

### Naming
- [x] Renamed `snap` → `coord_snap` (noun_verb convention, pre-v1 rename)

---

## Feature Roadmap

### In Progress
*(nothing)*

### Up Next
- [x] **#19 — Camera pan** *(done session 6)*
- [x] **#20 — Zoom toggle** *(done session 6)* Tab snaps 1.0x↔0.6x; mouse wheel zooms when not over scroll region; Up/Down/wheel all clamped to [0.25, 3.0]x


- [ ] **#13 — Grid rendering mode (CP437)**
      `draw_text_grid(ctx, text, x, y, font_size, cell_w, cell_h, color)`. Fixed-width cells,
      each character centered. Primary use case: roguelike map tiles and stat columns.

### Near-Term Backends
- [ ] **#16 — Sokol backend** (`slug_sokol`)
      Sokol GFX is a popular Odin/C cross-platform graphics layer. Good portability story.
      Needs `flush(scissor)` support via `sg_apply_scissor_rect`.

- [ ] **#17 — SDL3 GPU backend** (`slug_sdl3`)
      SDL3's new GPU API. Pairs naturally with the existing Vulkan demo's SDL3 windowing.
      Needs `flush(scissor)` support via `sdl.GPUSetScissor`.

- [ ] **#18 — Karl2D backend** (`slug_karl2d`)
      Karl Zylinski's pure-Odin 2D library (zero C deps). Primary target for the roguelike project.
      Integration notes in `docs/KARL2D_INTEGRATION.md`. Has OpenGL, D3D11, and Metal backends.
      Needs `flush(scissor)` support via the underlying GL/D3D11/Metal scissor APIs.

### Later / Stretch Goals
- [ ] **#14 — Message log widget**
      Scrollable, timestamped message list. Probably built on top of scroll.odin + Text_Style.
      May wait until #9 and #12 are done.

- [ ] **#15 — Tooltip system**
      Positioned text box that follows the mouse and auto-flips at screen edges. Needs hit testing
      (#8) to be useful.

- [ ] **#1 — Instanced rendering**
      Replace one-quad-per-glyph with GPU instancing. Big perf win for dense text. Requires
      shader changes in all backends. Defer until the API is stable (post-v1.0).

---

## Known Limitations (by design, not bugs)

- `measure_text` / cursor procs take `^Font` and don't follow fallback chains. This is intentional —
  fallback-aware measurement would require `^Context`, changing the public API.
- `MAX_GLYPH_QUADS = 4096`, `MAX_RECTS = 512`, `MAX_FONT_SLOTS = 4` are compile-time constants
  baked into `Context`. No dynamic allocation. Exceeding the limits silently drops glyphs.
- Font fallback only works in shared atlas mode (`fonts_process_shared`). In per-font mode the
  fallback chain is registered but silently ignored to avoid cross-texture quad corruption.
- `draw_rect` / background rects are always drawn *before* glyphs regardless of call order — rects
  can never appear on top of text in the same frame.
