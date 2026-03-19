package slug

import "core:math"

// ===================================================
// Text drawing and measurement — CPU-side vertex packing.
//
// These procs write glyph quads into ctx.vertices[]. No GPU calls.
// The backend reads the vertex data and uploads/draws it.
// ===================================================

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
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS {
			prev_rune = ch
			continue
		}
		g := &font.glyphs[idx]
		if !g.valid {
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
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS {
			prev_rune = ch
			continue
		}

		g := &font.glyphs[idx]
		if !g.valid {
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

// Draw an SVG icon centered at the given screen position.
// icon_index is the glyph slot (use 128+ to avoid ASCII collision).
draw_icon :: proc(ctx: ^Context, icon_index: int, x, y: f32, size: f32, color: Color) {
	font := active_font(ctx)
	if icon_index < 0 || icon_index >= MAX_CACHED_GLYPHS do return
	g := &font.glyphs[icon_index]
	if !g.valid || len(g.curves) == 0 do return

	glyph_w := (g.bbox_max.x - g.bbox_min.x) * size
	glyph_h := (g.bbox_max.y - g.bbox_min.y) * size

	glyph_x := x - glyph_w * 0.5
	glyph_y := y - glyph_h * 0.5

	if ctx.quad_count < MAX_GLYPH_QUADS {
		emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
	}
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
