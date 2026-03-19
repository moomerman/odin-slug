package slug

import "core:math"

// ===================================================
// Text effects — per-character manipulation.
// All CPU-side vertex data, zero shader changes needed.
// ===================================================

// --- Color utilities ---

hsv_to_rgb :: proc(h, s, v: f32) -> [3]f32 {
	c := v * s
	hp := math.mod(h / 60.0, 6.0)
	x := c * (1.0 - abs(math.mod(hp, 2.0) - 1.0))
	m := v - c

	r, g, b: f32
	if hp < 1 {r, g, b = c, x, 0} else if hp < 2 {r, g, b = x, c, 0} else if hp < 3 {r, g, b = 0, c, x} else if hp < 4 {r, g, b = 0, x, c} else if hp < 5 {r, g, b = x, 0, c} else {r, g, b = c, 0, x}

	return {r + m, g + m, b + m}
}

// --- Rainbow text ---
// Each character gets a hue offset by its position.

draw_text_rainbow :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	time: f32,
	speed: f32 = 120.0,
	spread: f32 = 25.0,
) {
	font := active_font(ctx)
	pen_x := x
	char_idx := 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		hue := math.mod(time * speed + f32(char_idx) * spread, 360.0)
		rgb := hsv_to_rgb(hue, 1.0, 1.0)
		color := [4]f32{rgb.x, rgb.y, rgb.z, 1.0}

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := y - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
	}
}

// --- Wobble text ---
// Each character bobs up and down on a sine wave.

draw_text_wobble :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	time: f32,
	amplitude: f32 = 8.0,
	frequency: f32 = 3.0,
	phase_step: f32 = 0.5,
) {
	font := active_font(ctx)
	pen_x := x
	char_idx := 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		y_offset := math.sin(time * frequency + f32(char_idx) * phase_step) * amplitude

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := (y + y_offset) - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		hue := math.mod(time * 120.0 + f32(char_idx) * 25.0, 360.0)
		rgb := hsv_to_rgb(hue, 0.8, 1.0)
		color := [4]f32{rgb.x, rgb.y, rgb.z, 1.0}

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
	}
}

// --- Shake text ---
// Per-character pseudo-random jitter.

draw_text_shake :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	intensity: f32 = 3.0,
	time: f32 = 0,
	color: [4]f32 = {1.0, 0.3, 0.3, 1.0},
) {
	font := active_font(ctx)
	pen_x := x
	char_idx := 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		seed := f32(char_idx) * 7.13 + time * 31.7
		dx := math.sin(seed * 3.7) * intensity
		dy := math.cos(seed * 5.3) * intensity

		glyph_x := pen_x + g.bbox_min.x * font_size + dx
		glyph_y := (y - g.bbox_max.y * font_size) + dy
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
	}
}

// --- Rotated text ---
// Text rendered around a center point at an arbitrary angle.

draw_text_rotated :: proc(
	ctx: ^Context,
	text: string,
	cx, cy: f32,
	font_size: f32,
	angle: f32,
	color: [4]f32,
) {
	font := active_font(ctx)

	total_w, text_h := measure_text(font, text, font_size)

	cos_a := math.cos(angle)
	sin_a := math.sin(angle)

	xform := matrix[2, 2]f32{
		cos_a * font_size, -sin_a * font_size,
		sin_a * font_size,  cos_a * font_size,
	}

	pen_x: f32 = -total_w * 0.5

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		em_cx := (g.bbox_min.x + g.bbox_max.x) * 0.5
		em_cy := (g.bbox_min.y + g.bbox_max.y) * 0.5
		local_x := pen_x + em_cx * font_size
		local_y := -em_cy * font_size + text_h * 0.5

		screen_x := cx + local_x * cos_a - local_y * sin_a
		screen_y := cy + local_x * sin_a + local_y * cos_a

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, screen_x, screen_y, xform, color)
		}

		pen_x += g.advance_width * font_size
	}
}

// --- Circular text ---
// Characters positioned along a circle, rotated to follow the tangent.

draw_text_on_circle :: proc(
	ctx: ^Context,
	text: string,
	cx, cy: f32,
	radius: f32,
	start_angle: f32,
	font_size: f32,
	color: [4]f32,
) {
	font := active_font(ctx)
	pen_angle := start_angle

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		advance_arc := g.advance_width * font_size
		char_angle := advance_arc / radius

		mid_angle := pen_angle + char_angle * 0.5
		pos_x := cx + radius * math.cos(mid_angle)
		pos_y := cy + radius * math.sin(mid_angle)

		tangent_angle := mid_angle + math.PI * 0.5
		cos_t := math.cos(tangent_angle)
		sin_t := math.sin(tangent_angle)

		xform := matrix[2, 2]f32{
			cos_t * font_size, -sin_t * font_size,
			sin_t * font_size,  cos_t * font_size,
		}

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, pos_x, pos_y, xform, color)
		}

		pen_angle += char_angle
	}
}

// --- Wave text ---
// Characters positioned along a sine wave path.

draw_text_on_wave :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	amplitude: f32 = 15.0,
	wavelength: f32 = 300.0,
	phase: f32 = 0,
	color: [4]f32 = {1.0, 0.5, 0.7, 1.0},
) {
	font := active_font(ctx)
	pen_x := x
	freq := math.TAU / wavelength

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		wave_y := amplitude * math.sin(freq * pen_x + phase)
		slope := amplitude * freq * math.cos(freq * pen_x + phase)
		tangent_angle := math.atan(slope)

		cos_t := math.cos(tangent_angle)
		sin_t := math.sin(tangent_angle)

		xform := matrix[2, 2]f32{
			cos_t * font_size, -sin_t * font_size,
			sin_t * font_size,  cos_t * font_size,
		}

		em_cx := (g.bbox_min.x + g.bbox_max.x) * 0.5

		screen_x := pen_x + em_cx * font_size * cos_t
		screen_y := (y + wave_y) + em_cx * font_size * sin_t

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, screen_x, screen_y, xform, color)
		}

		pen_x += g.advance_width * font_size
	}
}

// --- Drop shadow ---
// Renders text twice: offset dark shadow, then real text on top.

draw_text_shadow :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: [4]f32,
	shadow_offset: f32 = 2.0,
	shadow_color: [4]f32 = {0.0, 0.0, 0.0, 0.6},
) {
	draw_text(ctx, text, x + shadow_offset, y + shadow_offset, font_size, shadow_color)
	draw_text(ctx, text, x, y, font_size, color)
}

// --- Typewriter reveal ---
// Shows characters one at a time based on elapsed time.

draw_text_typewriter :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: [4]f32,
	time: f32,
	chars_per_sec: f32 = 12.0,
) {
	visible_chars := int(time * chars_per_sec)
	if visible_chars <= 0 do return

	char_count := 0
	byte_end := 0
	for i := 0; i < len(text); {
		if char_count >= visible_chars do break
		_, size := utf8_decode(text[i:])
		i += size
		byte_end = i
		char_count += 1
	}

	draw_text(ctx, text[:byte_end], x, y, font_size, color)
}

@(private = "file")
utf8_decode :: proc(s: string) -> (r: rune, size: int) {
	if len(s) == 0 do return 0, 0
	b := s[0]
	if b < 0x80 do return rune(b), 1
	if b < 0xC0 do return 0xFFFD, 1
	if b < 0xE0 {
		if len(s) < 2 do return 0xFFFD, 1
		return rune(b & 0x1F) << 6 | rune(s[1] & 0x3F), 2
	}
	if b < 0xF0 {
		if len(s) < 3 do return 0xFFFD, 1
		return rune(b & 0x0F) << 12 | rune(s[1] & 0x3F) << 6 | rune(s[2] & 0x3F), 3
	}
	if len(s) < 4 do return 0xFFFD, 1
	return rune(b & 0x07) << 18 |
		rune(s[1] & 0x3F) << 12 |
		rune(s[2] & 0x3F) << 6 |
		rune(s[3] & 0x3F),
		4
}
