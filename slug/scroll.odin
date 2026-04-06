package slug

// ===================================================
// Scrollable text region — vertical scrolling within a fixed viewport.
//
// Renders word-wrapped text but only emits quads for lines that fall
// within the visible region. No GPU scissor needed — lines outside
// the viewport are simply skipped.
//
// Usage:
//   region := slug.Scroll_Region{x = 10, y = 50, width = 400, height = 300}
//   slug.draw_text_scrolled(ctx, long_text, &region, 20, slug.WHITE)
//   // On mouse wheel:
//   region.scroll_offset += delta * slug.line_height(font, 20)
// ===================================================

// Describes a rectangular viewport for scrollable text.
// The caller owns this struct and updates scroll_offset to scroll.
Scroll_Region :: struct {
	x:             f32, // Left edge of the text area
	y:             f32, // Top edge of the visible viewport
	width:         f32, // Text wrap width
	height:        f32, // Visible viewport height
	scroll_offset: f32, // Pixels scrolled down (0 = top, positive = scrolled)
}

// Draw word-wrapped text within a scroll region.
// Only lines overlapping the visible viewport [y, y+height] emit quads.
// Returns the total content height (for scroll bar sizing).
draw_text_scrolled :: proc(
	ctx: ^Context,
	text: string,
	region: ^Scroll_Region,
	font_size: f32,
	color: Color,
	use_kerning: bool = true,
	line_spacing: f32 = 1.0,
) -> f32 {
	font := active_font(ctx)
	lh := line_height(font, font_size) * line_spacing
	space_w := char_advance(font, ' ', font_size)
	text_line_h := (font.ascent - font.descent) * font_size
	ascent_px := font.ascent * font_size

	// Content coordinates: pen_y starts at 0 (top of content)
	pen_x: f32 = 0
	pen_y: f32 = 0

	i := 0
	for i < len(text) {
		if text[i] == '\n' {
			pen_x = 0
			pen_y += lh
			i += 1
			continue
		}
		if text[i] == ' ' && pen_x == 0 {
			i += 1
			continue
		}

		// Find next word
		word_start := i
		for i < len(text) && text[i] != ' ' && text[i] != '\n' {
			i += 1
		}
		word := text[word_start:i]
		word_w, _ := measure_text(font, word, font_size, use_kerning)

		// Wrap
		if pen_x > 0 && pen_x + space_w + word_w > region.width {
			pen_x = 0
			pen_y += lh
		}
		if pen_x > 0 {
			pen_x += space_w
		}

		// Only emit quads if the full line fits within the visible viewport.
		// Uses screen-space coordinates so glyphs never bleed past the box edges.
		draw_y := region.y + (pen_y + ascent_px) - region.scroll_offset
		glyph_top := draw_y - ascent_px
		glyph_bot := draw_y - font.descent * font_size // descent is negative
		if glyph_top >= region.y && glyph_bot <= region.y + region.height {
			draw_x := region.x + pen_x
			draw_text(ctx, word, draw_x, draw_y, font_size, color, use_kerning)
		}

		pen_x += word_w

		if i < len(text) && text[i] == ' ' {
			i += 1
		}
	}

	return pen_y + text_line_h
}

// Draw rich text with word wrapping and scrolling within a scroll region.
// Only lines overlapping the visible viewport emit quads.
// Returns the total content height (for scroll bar sizing).
draw_rich_text_scrolled :: proc(
	ctx: ^Context,
	text: string,
	region: ^Scroll_Region,
	font_size: f32,
	default_color: Color,
	use_kerning: bool = true,
	line_spacing: f32 = 1.0,
) -> f32 {
	font := active_font(ctx)
	lh := line_height(font, font_size) * line_spacing
	space_w := char_advance(font, ' ', font_size)
	text_line_h := (font.ascent - font.descent) * font_size
	ascent_px := font.ascent * font_size

	pen_x: f32 = 0
	pen_y: f32 = 0

	i := 0
	for i < len(text) {
		if text[i] == '\n' {
			pen_x = 0
			pen_y += lh
			i += 1
			continue
		}
		if text[i] == ' ' && pen_x == 0 {
			i += 1
			continue
		}
		if text[i] == ' ' {
			i += 1
			continue
		}

		// Consume one token (same as draw_rich_text_wrapped)
		token_start := i
		token_color := default_color
		token_bg: Color = {}
		token_has_bg := false
		token_text := ""
		token_is_icon := false
		icon_slot := 0
		icon_color := default_color
		icon_color_set := false

		if text[i] == '{' {
			if i + 1 < len(text) && text[i + 1] == '{' {
				token_text = "{"
				i += 2
			} else {
				s, ic, ics, ie, iok := parse_icon_tag(text, i)
				if iok {
					token_is_icon = true
					icon_slot = s
					icon_color = ic
					icon_color_set = ics
					i = ie
				} else {
					bgc, bgt, bge, bgok := parse_bg_tag(text, i)
					if bgok {
						token_text = bgt
						token_bg = bgc
						token_has_bg = true
						i = bge
					} else {
						fc, ft, fe, fok := parse_rich_tag(text, i)
						if fok {
							token_text = ft
							token_color = fc
							i = fe
						} else {
							token_text = "{"
							i += 1
						}
					}
				}
			}
		} else {
			for i < len(text) && text[i] != ' ' && text[i] != '\n' && text[i] != '{' {
				i += 1
			}
			token_text = text[token_start:i]
		}

		if token_is_icon {
			g := get_glyph_fallback(ctx, rune(icon_slot))
			if g != nil && len(g.curves) > 0 {
				icon_w := (g.bbox_max.x - g.bbox_min.x) * font_size
				icon_h := (g.bbox_max.y - g.bbox_min.y) * font_size

				if pen_x > 0 && pen_x + icon_w > region.width {
					pen_x = 0
					pen_y += lh
				}
				if pen_x > 0 {
					pen_x += space_w
				}

				draw_y := region.y + (pen_y + ascent_px) - region.scroll_offset
				glyph_top := draw_y - ascent_px
				glyph_bot := draw_y - font.descent * font_size
				if glyph_top >= region.y && glyph_bot <= region.y + region.height {
					line_mid_y := draw_y - (font.ascent + font.descent) * font_size * 0.5
					glyph_y := line_mid_y - icon_h * 0.5
					draw_color := icon_color if icon_color_set else default_color
					if ctx.quad_count < MAX_GLYPH_QUADS {
						emit_glyph_quad(ctx, g, region.x + pen_x, glyph_y, icon_w, icon_h, draw_color)
					}
				}
				pen_x += icon_w + font_size * 0.1
			}
			continue
		}

		if len(token_text) == 0 do continue

		ti := 0
		for ti < len(token_text) {
			if token_text[ti] == ' ' {
				ti += 1
				continue
			}
			ws := ti
			for ti < len(token_text) && token_text[ti] != ' ' {
				ti += 1
			}
			word := token_text[ws:ti]
			word_w, _ := measure_text(font, word, font_size, use_kerning)

			if pen_x > 0 && pen_x + space_w + word_w > region.width {
				pen_x = 0
				pen_y += lh
			}
			if pen_x > 0 {
				pen_x += space_w
			}

			// Only emit if visible
			draw_y := region.y + (pen_y + ascent_px) - region.scroll_offset
			glyph_top := draw_y - ascent_px
			glyph_bot := draw_y - font.descent * font_size
			if glyph_top >= region.y && glyph_bot <= region.y + region.height {
				draw_x := region.x + pen_x
				if token_has_bg {
					_, wh := measure_text(font, word, font_size, use_kerning)
					rect_y := draw_y - font.ascent * font_size
					draw_rect(ctx, draw_x, rect_y, word_w, wh, token_bg)
				}
				draw_text(ctx, word, draw_x, draw_y, font_size, token_color, use_kerning)
			}

			pen_x += word_w

			if ti < len(token_text) && token_text[ti] == ' ' {
				ti += 1
			}
		}
	}

	return pen_y + text_line_h
}

// Clamp scroll offset to valid range given total content height.
// Call after changing scroll_offset to prevent over-scrolling.
scroll_clamp :: proc(region: ^Scroll_Region, content_height: f32) {
	max_scroll := content_height - region.height
	if max_scroll < 0 do max_scroll = 0
	if region.scroll_offset < 0 do region.scroll_offset = 0
	if region.scroll_offset > max_scroll do region.scroll_offset = max_scroll
}

// Scroll by a delta (positive = scroll down, negative = scroll up).
// Automatically clamps to valid range.
scroll_by :: proc(region: ^Scroll_Region, delta: f32, content_height: f32) {
	region.scroll_offset += delta
	scroll_clamp(region, content_height)
}

// Returns 0.0–1.0 representing how far down the content is scrolled.
// Useful for drawing a scroll bar indicator.
scroll_fraction :: proc(region: ^Scroll_Region, content_height: f32) -> f32 {
	max_scroll := content_height - region.height
	if max_scroll <= 0 do return 0
	return clamp(region.scroll_offset / max_scroll, 0, 1)
}

// Returns the fraction of total content visible in the viewport (0.0–1.0).
// Useful for scroll bar thumb size.
scroll_visible_fraction :: proc(region: ^Scroll_Region, content_height: f32) -> f32 {
	if content_height <= 0 do return 1
	return clamp(region.height / content_height, 0, 1)
}
