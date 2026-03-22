package slug

import "core:math"
import "core:unicode/utf8"

// ===================================================
// Text drawing and measurement — CPU-side vertex packing.
//
// These procs write glyph quads into ctx.vertices[]. No GPU calls.
// The backend reads the vertex data and uploads/draws it.
// ===================================================

// Snap a coordinate to the nearest pixel boundary.
// Use this for grid-aligned UIs where you want pixel-perfect text:
//   slug.draw_text(ctx, "HP: 100", slug.snap(x), slug.snap(y), size, color)
// Slug renders Bezier curves per-pixel, so subpixel positioning works
// naturally without quality loss. Snapping is optional and purely for
// alignment with pixel-grid elements like tile maps or UI panels.
snap :: proc(v: f32) -> f32 {
	return math.round(v)
}

// Advance width of a single character in pixels.
// This is how far the pen moves after drawing the character — use it
// for manual text layout and positioning. Returns 0 if the glyph isn't loaded.
// For kerning between character pairs, use font_get_kerning separately.
char_advance :: proc(font: ^Font, ch: rune, font_size: f32) -> f32 {
	g := get_glyph(font, ch)
	if g == nil do return 0
	return g.advance_width * font_size
}

// Vertical distance between text lines in pixels.
// Includes the font's line gap for proper inter-line spacing.
// Computed from the font's ascent, descent, and line gap metrics —
// consistent regardless of which characters are drawn.
line_height :: proc(font: ^Font, font_size: f32) -> f32 {
	return (font.ascent - font.descent + font.line_gap) * font_size
}

// Fixed cell width for monospace-style layouts in pixels.
// Returns the widest loaded glyph's advance width, which can be
// used as a uniform cell width for grid-aligned text (roguelike maps,
// stat columns, fixed-width UI). Works with any font — proportional
// fonts just get wider cells.
mono_width :: proc(font: ^Font, font_size: f32) -> f32 {
	max_advance: f32 = 0
	for _, &g in font.glyphs {
		if g.valid && g.advance_width > max_advance {
			max_advance = g.advance_width
		}
	}
	return max_advance * font_size
}

// Measure a string's pixel dimensions at the given font size.
measure_text :: proc(
	font: ^Font,
	text: string,
	font_size: f32,
	use_kerning: bool = true,
) -> (
	width: f32,
	height: f32,
) {
	pen_x: f32 = 0
	prev_rune: rune = 0
	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}
		if use_kerning && prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}
		pen_x += g.advance_width * font_size
		prev_rune = ch
	}
	return pen_x, (font.ascent - font.descent) * font_size
}

// Pixel x-offset of the cursor at the given character index.
// index 0 = before the first character (left edge of the string).
// index == rune_count = after the last character (right edge).
// Returns 0 for out-of-range indices. Use with draw_text's x parameter:
//   cursor_px := x + slug.cursor_x_from_index(font, text, size, cursor_idx)
cursor_x_from_index :: proc(
	font: ^Font,
	text: string,
	font_size: f32,
	index: int,
	use_kerning: bool = true,
) -> f32 {
	pen_x: f32 = 0
	prev_rune: rune = 0
	i := 0
	for ch in text {
		if i >= index do break
		g := get_glyph(font, ch)
		if g != nil {
			if use_kerning && prev_rune != 0 {
				pen_x += font_get_kerning(font, prev_rune, ch) * font_size
			}
			pen_x += g.advance_width * font_size
		}
		prev_rune = ch
		i += 1
	}
	return pen_x
}

// Character index closest to a pixel x-offset within rendered text.
// Returns the index (0-based rune position) where a cursor should be
// placed if the user clicks at target_x pixels from the string's left edge.
// Snaps to the nearest character boundary (halfway = next character).
index_from_x :: proc(
	font: ^Font,
	text: string,
	font_size: f32,
	target_x: f32,
	use_kerning: bool = true,
) -> int {
	if target_x <= 0 do return 0

	pen_x: f32 = 0
	prev_rune: rune = 0
	i := 0
	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			i += 1
			continue
		}

		advance: f32 = 0
		if use_kerning && prev_rune != 0 {
			advance += font_get_kerning(font, prev_rune, ch) * font_size
		}
		advance += g.advance_width * font_size

		// If target is within the first half of this character, cursor goes before it
		if target_x < pen_x + advance * 0.5 {
			return i
		}

		pen_x += advance
		prev_rune = ch
		i += 1
	}
	return i // past the end
}

// Draw a string of text at the given position and size.
// x, y is the baseline-left position. font_size is the em-square height in pixels.
draw_text :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	use_kerning: bool = true,
) {
	font := active_font(ctx)
	pen_x := x

	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if use_kerning && prev_rune != 0 {
			kern := font_get_kerning(font, prev_rune, ch)
			pen_x += kern * font_size
		}

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := y - g.bbox_max.y * font_size

		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		prev_rune = ch
	}
}

// Draw text horizontally centered at x.
// x is the center point, not the left edge.
draw_text_centered :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	use_kerning: bool = true,
) {
	font := active_font(ctx)
	w, _ := measure_text(font, text, font_size, use_kerning)
	draw_text(ctx, text, x - w * 0.5, y, font_size, color, use_kerning)
}

// Draw text right-aligned so the last character ends at x.
// x is the right edge, not the left edge.
draw_text_right :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	use_kerning: bool = true,
) {
	font := active_font(ctx)
	w, _ := measure_text(font, text, font_size, use_kerning)
	draw_text(ctx, text, x - w, y, font_size, color, use_kerning)
}

// Draw text clipped to max_width pixels, appending "..." when truncated.
// The ellipsis width is reserved from the budget first, so the total rendered
// width always fits within max_width. If there is no room for any characters
// before the ellipsis, the ellipsis alone is drawn.
// Returns the pixel width actually drawn (useful for follow-on layout).
//
// Example:
//   // Clip a long item name to fit inside a UI panel column
//   slug.draw_text_truncated(ctx, item.name, x, y, size, column_width, color)
draw_text_truncated :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	max_width: f32,
	color: Color,
	use_kerning: bool = true,
) -> f32 {
	font := active_font(ctx)

	// Fast path: text fits as-is
	full_w, _ := measure_text(font, text, font_size, use_kerning)
	if full_w <= max_width {
		draw_text(ctx, text, x, y, font_size, color, use_kerning)
		return full_w
	}

	ELLIPSIS :: "..."
	ellipsis_w, _ := measure_text(font, ELLIPSIS, font_size)
	budget := max_width - ellipsis_w

	if budget <= 0 {
		// No room for any chars before the ellipsis
		draw_text(ctx, ELLIPSIS, x, y, font_size, color)
		return ellipsis_w
	}

	// Walk characters accumulating width until we exceed budget
	pen_x: f32 = 0
	prev_rune: rune = 0
	byte_end := 0

	for ch, i in text {
		g := get_glyph(font, ch)
		kern: f32 = 0
		if g != nil && use_kerning && prev_rune != 0 {
			kern = font_get_kerning(font, prev_rune, ch) * font_size
		}
		advance := kern + (g.advance_width * font_size if g != nil else 0)
		if pen_x + advance > budget do break
		pen_x += advance
		_, ch_size := utf8.decode_rune_in_string(text[i:])
		byte_end = i + ch_size
		prev_rune = ch
	}

	draw_text(ctx, text[:byte_end], x, y, font_size, color, use_kerning)
	draw_text(ctx, ELLIPSIS, x + pen_x, y, font_size, color)
	return pen_x + ellipsis_w
}

// Draw text with automatic word wrapping within max_width pixels.
// Breaks on spaces and newlines. Words wider than max_width are
// drawn on their own line without breaking mid-word.
// x, y is the top-left corner of the text block (not the baseline).
// Returns the total height used, so the caller can position
// content below: next_y = y + draw_text_wrapped(...).
draw_text_wrapped :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	max_width: f32,
	color: Color,
	use_kerning: bool = true,
) -> f32 {
	font := active_font(ctx)
	lh := line_height(font, font_size)
	space_w := char_advance(font, ' ', font_size)

	// Height of a single text line (ascent - descent), without inter-line gap.
	// Used for the return value — the total bounding height of the text block.
	text_line_h := (font.ascent - font.descent) * font_size

	// Offset so y is the top of the text block, not the baseline.
	// draw_text expects y at the top of the glyph's em square, which
	// is ascent above the baseline.
	ascent_px := font.ascent * font_size

	pen_x: f32 = 0
	pen_y: f32 = ascent_px

	// Walk through the text, splitting on spaces and newlines
	i := 0
	for i < len(text) {
		// Handle newlines
		if text[i] == '\n' {
			pen_x = 0
			pen_y += lh
			i += 1
			continue
		}

		// Skip spaces at line start
		if text[i] == ' ' && pen_x == 0 {
			i += 1
			continue
		}

		// Find the next word (run of non-space, non-newline characters)
		word_start := i
		for i < len(text) && text[i] != ' ' && text[i] != '\n' {
			i += 1
		}
		word := text[word_start:i]

		word_w, _ := measure_text(font, word, font_size, use_kerning)

		// Wrap if this word would exceed max_width (unless it's the first word on the line)
		if pen_x > 0 && pen_x + space_w + word_w > max_width {
			pen_x = 0
			pen_y += lh
		}

		// Add space between words on the same line
		if pen_x > 0 {
			pen_x += space_w
		}

		// Draw the word
		draw_text(ctx, word, x + pen_x, y + pen_y, font_size, color, use_kerning)
		pen_x += word_w

		// Skip trailing space after word
		if i < len(text) && text[i] == ' ' {
			i += 1
		}
	}

	// Return total height from the top of the text block.
	// pen_y already includes the initial ascent offset, so subtract it
	// and add back the full text line height for the last line.
	return pen_y - ascent_px + text_line_h
}

// Measure wrapped text height without drawing.
// Returns the total height the text block would occupy, so you can
// size a background box before drawing the text on top.
measure_text_wrapped :: proc(
	ctx: ^Context,
	text: string,
	font_size: f32,
	max_width: f32,
	use_kerning: bool = true,
) -> f32 {
	font := active_font(ctx)
	lh := line_height(font, font_size)
	space_w := char_advance(font, ' ', font_size)
	text_line_h := (font.ascent - font.descent) * font_size

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
		word_start := i
		for i < len(text) && text[i] != ' ' && text[i] != '\n' {
			i += 1
		}
		word := text[word_start:i]
		word_w, _ := measure_text(font, word, font_size, use_kerning)

		if pen_x > 0 && pen_x + space_w + word_w > max_width {
			pen_x = 0
			pen_y += lh
		}
		if pen_x > 0 {
			pen_x += space_w
		}
		pen_x += word_w
		if i < len(text) && text[i] == ' ' {
			i += 1
		}
	}

	return pen_y + text_line_h
}

// Draw an SVG icon centered at the given screen position.
// icon_index is the glyph slot (use 128+ to avoid ASCII collision).
draw_icon :: proc(ctx: ^Context, icon_index: int, x, y: f32, size: f32, color: Color) {
	font := active_font(ctx)
	g := get_glyph(font, rune(icon_index))
	if g == nil || len(g.curves) == 0 do return

	glyph_w := (g.bbox_max.x - g.bbox_min.x) * size
	glyph_h := (g.bbox_max.y - g.bbox_min.y) * size

	glyph_x := x - glyph_w * 0.5
	glyph_y := y - glyph_h * 0.5

	if ctx.quad_count < MAX_GLYPH_QUADS {
		emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
	}
}

// Draw a solid colored rectangle.
// x, y is the top-left corner in screen space. w, h are in pixels.
// The rect is added to ctx.rect_vertices[], which backends draw with a
// flat-color shader BEFORE the Slug text pass — so rects always appear
// behind any text drawn in the same frame.
//
// Typical use: call draw_rect before draw_text to highlight a region:
//   slug.draw_rect(ctx, x, y - ascent, w, line_h, slug.Color{0.2, 0.2, 0.8, 0.5})
//   slug.draw_text(ctx, "selected item", x, y, size, slug.WHITE)
draw_rect :: proc(ctx: ^Context, x, y, w, h: f32, color: Color) {
	if ctx.rect_count >= MAX_RECTS do return

	base := ctx.rect_count * VERTICES_PER_QUAD

	ctx.rect_vertices[base + 0] = Rect_Vertex{{x,     y    }, color}
	ctx.rect_vertices[base + 1] = Rect_Vertex{{x + w, y    }, color}
	ctx.rect_vertices[base + 2] = Rect_Vertex{{x + w, y + h}, color}
	ctx.rect_vertices[base + 3] = Rect_Vertex{{x,     y + h}, color}

	ctx.rect_count += 1
}

// Draw text with a solid background color behind it.
// x, y is the baseline-left position (same convention as draw_text).
// The background rect spans the full line height (ascent to descent) and
// the full text width. The rect is drawn before the text, so it always
// appears behind the glyphs.
//
// Example:
//   // Highlight a stat value in a roguelike HUD
//   slug.draw_text_highlighted(ctx, "POISONED", x, y, size, slug.BLACK, slug.Color{0.2, 0.8, 0.2, 1})
draw_text_highlighted :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	text_color: Color,
	bg_color: Color,
	use_kerning: bool = true,
) {
	font := active_font(ctx)
	w, h := measure_text(font, text, font_size, use_kerning)
	rect_y := y - font.ascent * font_size
	draw_rect(ctx, x, rect_y, w, h, bg_color)
	draw_text(ctx, text, x, y, font_size, text_color, use_kerning)
}

// Helper: return the background rect dimensions for a text string.
// Use this when you need to position the rect yourself (e.g. with padding):
//   rx, ry, rw, rh := slug.text_bg_rect(font, text, x, y, size)
//   slug.draw_rect(ctx, rx - pad, ry - pad, rw + pad*2, rh + pad*2, bg_color)
//   slug.draw_text(ctx, text, x, y, size, fg_color)
text_bg_rect :: proc(
	font: ^Font,
	text: string,
	x, y: f32,
	font_size: f32,
	use_kerning: bool = true,
) -> (
	rect_x, rect_y, rect_w, rect_h: f32,
) {
	w, h := measure_text(font, text, font_size, use_kerning)
	return x, y - font.ascent * font_size, w, h
}

// --- Vertex packing ---

// Emit a single glyph quad into the vertex buffer (axis-aligned).
@(private = "package")
emit_glyph_quad :: proc(ctx: ^Context, g: ^Glyph_Data, x, y, w, h: f32, color: Color) {
	base := ctx.quad_count * VERTICES_PER_QUAD
	if base + VERTICES_PER_QUAD > MAX_GLYPH_VERTICES do return

	em_min := g.bbox_min
	em_max := g.bbox_max

	glyph_loc := transmute(f32)(u32(g.band_tex_x) | (u32(g.band_tex_y) << 16))
	band_max := transmute(f32)(u32(g.band_max_x) | (u32(g.band_max_y) << 16))

	em_w := em_max.x - em_min.x
	em_h := em_max.y - em_min.y
	jac_00 := em_w / w if w > 0 else 0
	jac_11 := -(em_h / h) if h > 0 else 0

	corners := [4][2]f32 {
		{x, y}, // TL
		{x + w, y}, // TR
		{x + w, y + h}, // BR
		{x, y + h}, // BL
	}

	normals := [4][2]f32 {
		{-DILATION_SCALE, -DILATION_SCALE},
		{DILATION_SCALE, -DILATION_SCALE},
		{DILATION_SCALE, DILATION_SCALE},
		{-DILATION_SCALE, DILATION_SCALE},
	}

	em_coords := [4][2]f32 {
		{em_min.x, em_max.y}, // TL in em-space (Y-up)
		{em_max.x, em_max.y}, // TR
		{em_max.x, em_min.y}, // BR
		{em_min.x, em_min.y}, // BL
	}

	for vi in 0 ..< 4 {
		ctx.vertices[base + u32(vi)] = Vertex {
			pos = {corners[vi].x, corners[vi].y, normals[vi].x, normals[vi].y},
			tex = {em_coords[vi].x, em_coords[vi].y, glyph_loc, band_max},
			jac = {jac_00, 0, 0, jac_11},
			bnd = {g.band_scale.x, g.band_scale.y, g.band_offset.x, g.band_offset.y},
			col = color,
		}
	}

	ctx.quad_count += 1
}

// Emit a glyph quad with an arbitrary 2x2 transform (rotation + scale).
// center_x, center_y is the glyph center in screen space.
@(private = "package")
emit_glyph_quad_transformed :: proc(
	ctx: ^Context,
	g: ^Glyph_Data,
	center_x, center_y: f32,
	xform: matrix[2, 2]f32,
	color: Color,
) {
	base := ctx.quad_count * VERTICES_PER_QUAD
	if base + VERTICES_PER_QUAD > MAX_GLYPH_VERTICES do return

	em_min := g.bbox_min
	em_max := g.bbox_max
	em_cx := (em_min.x + em_max.x) * 0.5
	em_cy := (em_min.y + em_max.y) * 0.5

	glyph_loc := transmute(f32)(u32(g.band_tex_x) | (u32(g.band_tex_y) << 16))
	band_max := transmute(f32)(u32(g.band_max_x) | (u32(g.band_max_y) << 16))

	em_offsets := [4][2]f32 {
		{em_min.x - em_cx, em_max.y - em_cy},
		{em_max.x - em_cx, em_max.y - em_cy},
		{em_max.x - em_cx, em_min.y - em_cy},
		{em_min.x - em_cx, em_min.y - em_cy},
	}

	em_coords := [4][2]f32 {
		{em_min.x, em_max.y},
		{em_max.x, em_max.y},
		{em_max.x, em_min.y},
		{em_min.x, em_min.y},
	}

	det := xform[0, 0] * xform[1, 1] - xform[0, 1] * xform[1, 0]
	inv_det := 1.0 / det if abs(det) > 1e-10 else 0.0
	inv_jac := matrix[2, 2]f32{
		xform[1, 1] * inv_det, -xform[0, 1] * inv_det, 
		xform[1, 0] * inv_det, -xform[0, 0] * inv_det, 
	}

	for vi in 0 ..< 4 {
		off := em_offsets[vi]
		screen_off := [2]f32 {
			xform[0, 0] * off.x + xform[0, 1] * (-off.y),
			xform[1, 0] * off.x + xform[1, 1] * (-off.y),
		}

		nx := screen_off.x
		ny := screen_off.y
		len_n := math.sqrt(nx * nx + ny * ny)
		if len_n > 0 {
			nx = nx / len_n * DILATION_SCALE
			ny = ny / len_n * DILATION_SCALE
		}

		// Inverse Jacobian stored in row-major order matching the fragment shader's
		// expected layout. Encodes the screen-to-em-space transform so the shader
		// can compute correct antialiasing distances under rotation/skew.
		ctx.vertices[base + u32(vi)] = Vertex {
			pos = {center_x + screen_off.x, center_y + screen_off.y, nx, ny},
			tex = {em_coords[vi].x, em_coords[vi].y, glyph_loc, band_max},
			jac = {inv_jac[0, 0], inv_jac[0, 1], inv_jac[1, 0], inv_jac[1, 1]},
			bnd = {g.band_scale.x, g.band_scale.y, g.band_offset.x, g.band_offset.y},
			col = color,
		}
	}

	ctx.quad_count += 1
}
