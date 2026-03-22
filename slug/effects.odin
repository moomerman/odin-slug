package slug

import "core:math"
import "core:unicode/utf8"

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
	if hp < 1 {
		r, g, b = c, x, 0
	} else if hp < 2 {
		r, g, b = x, c, 0
	} else if hp < 3 {
		r, g, b = 0, c, x
	} else if hp < 4 {
		r, g, b = 0, x, c
	} else if hp < 5 {
		r, g, b = x, 0, c
	} else {
		r, g, b = c, 0, x
	}

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
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

		hue := math.mod(time * speed + f32(char_idx) * spread, 360.0)
		rgb := hsv_to_rgb(hue, 1.0, 1.0)
		color := Color{rgb.x, rgb.y, rgb.z, 1.0}

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := y - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
		prev_rune = ch
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
	color: Color = {1.0, 1.0, 1.0, 1.0},
) {
	font := active_font(ctx)
	pen_x := x
	char_idx := 0
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

		y_offset := math.sin(time * frequency + f32(char_idx) * phase_step) * amplitude

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := (y + y_offset) - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
		prev_rune = ch
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
	color: Color = {1.0, 0.3, 0.3, 1.0},
) {
	font := active_font(ctx)
	pen_x := x
	char_idx := 0
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

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
		prev_rune = ch
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
	color: Color,
) {
	font := active_font(ctx)

	total_w, text_h := measure_text(font, text, font_size)

	cos_a := math.cos(angle)
	sin_a := math.sin(angle)

	xform := matrix[2, 2]f32{
		cos_a * font_size, -sin_a * font_size, 
		sin_a * font_size, cos_a * font_size, 
	}

	pen_x: f32 = -total_w * 0.5
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

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
		prev_rune = ch
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
	color: Color,
) {
	font := active_font(ctx)
	pen_angle := start_angle
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		kern_advance: f32 = 0
		if prev_rune != 0 {
			kern_advance = font_get_kerning(font, prev_rune, ch) * font_size
		}

		advance_arc := g.advance_width * font_size + kern_advance
		char_angle := advance_arc / radius if abs(radius) > 1e-6 else 0

		mid_angle := pen_angle + char_angle * 0.5
		pos_x := cx + radius * math.cos(mid_angle)
		pos_y := cy + radius * math.sin(mid_angle)

		tangent_angle := mid_angle + math.PI * 0.5
		cos_t := math.cos(tangent_angle)
		sin_t := math.sin(tangent_angle)

		xform := matrix[2, 2]f32{
			cos_t * font_size, -sin_t * font_size,
			sin_t * font_size, cos_t * font_size,
		}

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, pos_x, pos_y, xform, color)
		}

		pen_angle += char_angle
		prev_rune = ch
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
	color: Color = {1.0, 0.5, 0.7, 1.0},
) {
	font := active_font(ctx)
	pen_x := x
	freq := math.TAU / wavelength if abs(wavelength) > 1e-6 else 0
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

		wave_y := amplitude * math.sin(freq * pen_x + phase)
		slope := amplitude * freq * math.cos(freq * pen_x + phase)
		tangent_angle := math.atan(slope)

		cos_t := math.cos(tangent_angle)
		sin_t := math.sin(tangent_angle)

		xform := matrix[2, 2]f32{
			cos_t * font_size, -sin_t * font_size,
			sin_t * font_size, cos_t * font_size,
		}

		em_cx := (g.bbox_min.x + g.bbox_max.x) * 0.5

		screen_x := pen_x + em_cx * font_size * cos_t
		screen_y := (y + wave_y) + em_cx * font_size * sin_t

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, screen_x, screen_y, xform, color)
		}

		pen_x += g.advance_width * font_size
		prev_rune = ch
	}
}

// --- Drop shadow ---
// Renders text twice: offset dark shadow, then real text on top.

draw_text_shadow :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	shadow_offset: f32 = 2.0,
	shadow_color: Color = {0.0, 0.0, 0.0, 0.6},
) {
	draw_text(ctx, text, x + shadow_offset, y + shadow_offset, font_size, shadow_color)
	draw_text(ctx, text, x, y, font_size, color)
}

// --- Outlined text ---
// Renders text with a colored outline for readability over busy backgrounds.
// Draws the text 8 times at cardinal + diagonal offsets in the outline color,
// then draws the fill on top. Uses 9 draw calls total per string.

draw_text_outlined :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	outline_thickness: f32 = 1.5,
	outline_color: Color = {0.0, 0.0, 0.0, 1.0},
) {
	t := outline_thickness
	// 8 offsets: N, NE, E, SE, S, SW, W, NW
	for off in ([8][2]f32{{0, -t}, {t, -t}, {t, 0}, {t, t}, {0, t}, {-t, t}, {-t, 0}, {-t, -t}}) {
		draw_text(ctx, text, x + off.x, y + off.y, font_size, outline_color)
	}
	draw_text(ctx, text, x, y, font_size, color)
}

// --- Typewriter reveal ---
// Shows characters one at a time based on elapsed time.

draw_text_typewriter :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	time: f32,
	chars_per_sec: f32 = 12.0,
) {
	visible_chars := int(time * chars_per_sec)
	if visible_chars <= 0 do return

	char_count := 0
	byte_end := 0
	for i := 0; i < len(text); {
		if char_count >= visible_chars do break
		_, size := utf8.decode_rune_in_string(text[i:])
		i += size
		byte_end = i
		char_count += 1
	}

	draw_text(ctx, text[:byte_end], x, y, font_size, color)
}

// --- Fade text ---
// Whole-string alpha fade based on time. Useful for floating damage numbers,
// toast notifications, or any text that should appear and disappear.
// alpha_override directly sets the alpha (0.0 = invisible, 1.0 = fully visible).

draw_text_fade :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	alpha: f32,
) {
	a := clamp(alpha, 0.0, 1.0)
	if a <= 0 do return
	faded := Color{color.r, color.g, color.b, color.a * a}
	draw_text(ctx, text, x, y, font_size, faded)
}

// --- Gradient text ---
// Per-character vertical color blend from top_color to bottom_color.
// Since each glyph is a quad with 4 vertices (TL, TR, BR, BL), we set
// top vertices to top_color and bottom vertices to bottom_color.

draw_text_gradient :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	top_color: Color,
	bottom_color: Color,
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

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := y - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			// Emit quad manually to set per-vertex colors
			base := ctx.quad_count * VERTICES_PER_QUAD
			if base + VERTICES_PER_QUAD <= MAX_GLYPH_VERTICES {
				emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, top_color)

				// Override bottom vertex colors (BR=index 2, BL=index 3)
				ctx.vertices[base + 2].col = bottom_color
				ctx.vertices[base + 3].col = bottom_color
			}
		}

		pen_x += g.advance_width * font_size
		prev_rune = ch
	}
}

// --- Scale pulse text ---
// Each character pulses in size on a sine wave, staggered by position.
// Creates a "breathing" or "popping" effect across the string.

draw_text_pulse :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	time: f32,
	scale_amount: f32 = 0.3,
	frequency: f32 = 3.0,
	phase_step: f32 = 0.5,
) {
	font := active_font(ctx)
	pen_x := x
	char_idx := 0
	prev_rune: rune = 0

	for ch in text {
		g := get_glyph(font, ch)
		if g == nil {
			prev_rune = ch
			continue
		}

		if prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}

		t := math.sin(time * frequency + f32(char_idx) * phase_step)
		char_scale := 1.0 + t * scale_amount
		scaled_size := font_size * char_scale

		// Scale each glyph around its visual center (bbox midpoint at base size).
		// This preserves exact character positions at scale=1.0 and grows/shrinks
		// symmetrically without shifting the overall string layout.
		em_cx   := (g.bbox_min.x + g.bbox_max.x) * 0.5
		em_cy   := (g.bbox_min.y + g.bbox_max.y) * 0.5
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * scaled_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * scaled_size
		glyph_x := pen_x + em_cx * font_size - glyph_w * 0.5
		glyph_y := y - em_cy * font_size - glyph_h * 0.5

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
		prev_rune = ch
	}
}

// --- Floating damage number ---
// Classic game effect: text rises upward and fades out over a duration.
// age is seconds since the number appeared. Returns false when the
// animation is complete (age >= duration), so the caller knows to remove it.
//
// Typical usage:
//   if slug.draw_text_float(ctx, "-15", x, y, 28, slug.RED, age) {
//       // still visible, keep it alive
//   } else {
//       // animation done, remove from list
//   }

draw_text_float :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	age: f32,
	duration: f32 = 1.0,
	rise_distance: f32 = 60.0,
) -> bool {
	if age < 0 || age >= duration do return false

	t := age / duration
	current_y := y - rise_distance * t
	alpha := 1.0 - t * t // quadratic fade — stays visible longer, then drops off

	faded := Color{color.r, color.g, color.b, color.a * alpha}
	draw_text_centered(ctx, text, x, current_y, font_size, faded)
	return true
}
