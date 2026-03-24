# odin-slug — TODO

Tracks both the feature roadmap and polish/cleanup work.
Update after each session.

Last updated: 2026-03-24 (session 10 — v1.0)

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
- [x] Zoom toggle + mouse wheel zoom (Tab snaps 1.0x↔0.6x; wheel zooms when not over scroll region; clamped to [0.25, 3.0]x)
- [x] Grid rendering mode / CP437 (`draw_text_grid`; fixed-width cells, bbox-centered; `\n` row advance)
- [x] Message log widget (`Message_Log`, `log_push`, `draw_message_log`; fixed-size ring buffer, age-based fade, no dynamic allocation)
- [x] **#22** — Camera/viewport bugs fixed: Raylib shapes now offset by cam_x/cam_y; scroll region hover check converts mouse to world space in all 3 demos; band epsilon (1/1024 em-space) added to glyph processing
- [x] **#10** — Custom ellipsis string parameter on `draw_text_truncated`
- [x] **#11** — Text selection highlighting (`draw_text_selection`)
- [x] **#12** — Independent underline/strikethrough colors (`line_color` param, `Text_Style` fields)
- [x] **#13** — Word-boundary truncation (`draw_text_truncated_word`)
- [x] **#16** — Sokol backend (`slug_sokol`)
- [x] **#17** — SDL3 GPU backend (`slug_sdl3gpu`)
- [x] **#18** — Karl2D backend (`slug_karl2d`)
- [x] Letter spacing / tracking (`tracking` parameter)
- [x] Tab stops (horizontal tab character support)
- [x] Line spacing multiplier (`line_spacing` parameter on wrapped text)
- [x] `active_font_index(ctx) -> int`
- [x] Documentation polish: `draw_icon`, `cache_text`, `measure_text`, `font_set_fallback` precondition comments
- [x] Full codebase audit (sessions 8 and 9)
- [x] **#27** — Outlined / bordered rects (`draw_rect_outline`, `draw_rect_bordered`)
- [x] **#28** — Rich text wrapping (`draw_rich_text_wrapped`, `measure_rich_text_wrapped`)
- [x] **#29** — Rich text scrolling (`draw_rich_text_scrolled`)
- [x] **#30** — Cursor / text input rendering (`draw_cursor` with blink support)
- [x] **#31** — Progress / stat bars (`draw_bar` with fill, border, centered label)
- [x] **#32** — Wrapped text line count (`measure_text_wrapped` returns `(height, lines)`)
- [x] **#33** — Columnar / tabular layout (`draw_text_columns`, `Column`, `Column_Align`)
- [x] **#34** — Clipped rich text (GPU scissor at flush level, demoed in all 6 backends)

---

## Feature Roadmap

### Later
- [ ] **#21 — Viewport zoom (zoom toward cursor)**
      Camera offset adjustment per zoom step so zoom centers on mouse position.

- [ ] **#15 — Tooltip system**
      Positioned text box that follows the mouse and auto-flips at screen edges.

### Slug Algorithm Optimizations (from Eric Lengyel's tips)
*These improve texture size and cache performance. Correctness is already handled.*

- [ ] **#23 — Curve texture endpoint sharing**
      Connected curves in a contour share an endpoint (p3 of curve N = p1 of curve N+1).
      Currently each curve writes 2 independent texels (`2 * num_curves` per glyph).
      With sharing, contours use `num_curves + 1` texels — ~50% curve texture reduction.
      Requires tracking contour boundaries during `font_load_glyph` and reworking
      `pack_glyph_textures` to emit shared texels. Band data curve coordinates still work
      since they point by explicit (x,y) into the curve texture.

- [ ] **#24 — Horizontal/vertical line filtering**
      Straight horizontal lines should be excluded from horizontal bands, and straight
      vertical lines from vertical bands — they can't contribute to the winding number
      for rays parallel to them. Currently `CalcRootCode` in the shader filters them at
      runtime (returns 0), but excluding them from bands avoids the texture fetch entirely.
      Check: `p1.y == p2.y == p3.y` (horizontal) or `p1.x == p2.x == p3.x` (vertical)
      with a small tolerance.

- [ ] **#25 — Band deduplication / subset sharing**
      If two adjacent bands contain the same curve index list, point both to the same
      data in the band texture. Also, if one band's list is a contiguous subset of
      another's, point it into the larger band's data. Reduces band texture size and
      improves texture cache hit rate.

- [ ] **#26 — sCapHeight pixel-grid alignment utility**
      Read `sCapHeight` from the font's OS/2 table. Expose a utility proc that, given a
      target font size and DPI, returns the nearest size where `size * sCapHeight` is an
      integer pixel count. This aligns cap-height glyphs to the pixel grid for crisp
      rendering without traditional font hinting.

### Later / Stretch Goals
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
- `ui_scale` only scales font sizes, not layout positions. For true viewport zoom (scale + pan
  toward cursor), see #21.
