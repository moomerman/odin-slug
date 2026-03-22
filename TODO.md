# odin-slug — TODO

Tracks both the feature roadmap and polish/cleanup work.
Update after each session.

Last updated: 2026-03-22

---

## Completed

- [x] Text highlighting / background color rects (`draw_rect`, `draw_text_highlighted`)
- [x] Ellipsis truncation (`draw_text_truncated`)
- [x] Underline / strikethrough (`draw_text_underlined`, `draw_text_strikethrough`)
- [x] Font fallback chains (`font_set_fallback`, `get_glyph_fallback`)

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
- [ ] **#6 — Per-character transform callback**
      `Glyph_Transform` struct + `draw_text_transformed` accepting a proc/closure called per
      glyph with `(glyph_idx: int, pen_x: f32, time: f32, userdata: rawptr) -> Glyph_Transform`.
      Subsumes many one-off effects and enables user-defined animations.

- [ ] **#7 — Inline icons in rich text flow**
      Extend `draw_rich_text` markup to embed SVG icons inline: `{icon:sword}` emits the icon
      glyph at the current pen position, advancing correctly with the surrounding text.

- [ ] **#8 — Hit testing**
      `hit_test_text(font, text, x, y, font_size, mouse_x, mouse_y) -> (rune_index: int, hit: bool)`.
      Maps a screen coordinate back to a character index. Needed for any interactive text UI.

- [ ] **#9 — Named styles / Text_Style struct**
      `Text_Style` struct carrying font slot, size, color, and decoration flags (underline,
      strikethrough, bold-emulation). `draw_text_styled(ctx, text, x, y, style)` for clean
      call sites in complex UIs.

- [ ] **#10 — Justified alignment**
      `draw_text_justified(ctx, text, x, y, font_size, column_width, color)`. Distributes
      inter-word spacing to fill the column exactly. Completes the alignment family.

- [ ] **#11 — Subscript / superscript**
      `draw_text_sub` / `draw_text_super`: draw at ~60% size, shifted down/up by ~35%/40% of
      the em-square. Useful for math notation, footnotes, chemical formulas.

- [ ] **#12 — GPU scissor clipping**
      Backend-level scissor rect passed to flush. Cleaner than the current scroll region approach
      for arbitrary clipped panels. Needs backend changes in all three renderers.

- [ ] **#13 — Grid rendering mode (CP437)**
      `draw_text_grid(ctx, text, x, y, font_size, cell_w, cell_h, color)`. Fixed-width cells,
      each character centered. Primary use case: roguelike map tiles and stat columns.

### Later / Stretch Goals
- [ ] **#14 — Message log widget**
      Scrollable, timestamped message list. Probably built on top of scroll.odin + Text_Style.
      May wait until #9 and #12 are done.

- [ ] **#15 — Tooltip system**
      Positioned text box that follows the mouse and auto-flips at screen edges. Needs hit testing
      (#8) to be useful.

- [ ] **#16 — Sokol backend** (`slug_sokol`)
      Thin wrapper over Sokol GFX for the Sokol ecosystem. Low priority until a user requests it.

- [ ] **#17 — SDL3 GPU backend** (`slug_sdl3`)
      SDL3's new GPU API (similar to WebGPU). Good target for portability. Low priority.

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
