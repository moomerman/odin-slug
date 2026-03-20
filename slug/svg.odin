package slug

import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// ===================================================
// Minimal SVG path parser for single-path icons.
//
// Parses <path d="..."> from simple SVGs (like game-icons.net)
// into Bezier_Curve data that feeds directly into the Slug pipeline.
//
// Supported commands: M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z
// ===================================================

SVG_Icon :: struct {
	glyph:     Glyph_Data,
	viewbox_w: f32,
	viewbox_h: f32,
}

svg_icon_destroy :: proc(icon: ^SVG_Icon) {
	glyph_data_destroy(&icon.glyph)
	icon^ = {}
}

// Load an SVG file from disk, parse it, and process for GPU rendering.
svg_load_icon :: proc(path: string) -> (icon: SVG_Icon, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(data)

	return svg_parse(string(data))
}

// Parse SVG string into an icon with processed glyph data.
svg_parse :: proc(svg_data: string) -> (icon: SVG_Icon, ok: bool) {
	vb_x, vb_y, vb_w, vb_h: f32
	if !svg_extract_viewbox(svg_data, &vb_x, &vb_y, &vb_w, &vb_h) {
		vb_x, vb_y, vb_w, vb_h = 0, 0, 512, 512
	}
	icon.viewbox_w = vb_w
	icon.viewbox_h = vb_h

	path_d := svg_extract_path_d(svg_data)
	if len(path_d) == 0 {
		return {}, false
	}

	svg_parse_path_data(path_d, vb_x, vb_y, vb_w, vb_h, &icon.glyph)

	if len(icon.glyph.curves) == 0 {
		return {}, false
	}

	svg_compute_bbox(&icon.glyph)

	icon.glyph.advance_width = icon.glyph.bbox_max.x - icon.glyph.bbox_min.x
	icon.glyph.left_bearing = icon.glyph.bbox_min.x
	icon.glyph.valid = true

	glyph_process(&icon.glyph)

	return icon, true
}

// Load an SVG file and place it into a font's glyph slot.
// Must be called BEFORE font_process / pack_glyph_textures.
svg_load_into_font :: proc(font: ^Font, slot_index: int, path: string) -> bool {
	if slot_index < 0 || slot_index >= MAX_CACHED_GLYPHS {
		return false
	}

	icon, icon_ok := svg_load_icon(path)
	if !icon_ok do return false

	g := &font.glyphs[slot_index]
	g^ = icon.glyph
	g.codepoint = rune(slot_index)
	g.valid = true

	icon.glyph = {}

	return true
}

// --- XML attribute extraction ---

@(private = "file")
svg_extract_viewbox :: proc(svg: string, x, y, w, h: ^f32) -> bool {
	vb_start := strings.index(svg, "viewBox=\"")
	if vb_start < 0 do return false
	vb_start += len("viewBox=\"")
	vb_end := strings.index(svg[vb_start:], "\"")
	if vb_end < 0 do return false
	vb_str := svg[vb_start:][:vb_end]

	parts := strings.fields(vb_str)
	defer delete(parts)
	if len(parts) != 4 do return false

	x^ = parse_f32(parts[0])
	y^ = parse_f32(parts[1])
	w^ = parse_f32(parts[2])
	h^ = parse_f32(parts[3])
	return w^ > 0 && h^ > 0
}

@(private = "file")
svg_extract_path_d :: proc(svg: string) -> string {
	d_start := strings.index(svg, " d=\"")
	if d_start < 0 do return ""
	d_start += len(" d=\"")
	d_end := strings.index(svg[d_start:], "\"")
	if d_end < 0 do return ""
	return svg[d_start:][:d_end]
}

// --- SVG path parser ---

@(private = "file")
SVG_Parser :: struct {
	data:      string,
	pos:       int,
	cx, cy:    f32,
	sx, sy:    f32,
	prev_cp_x: f32,
	prev_cp_y: f32,
	prev_cmd:  u8,
	vb_x:      f32,
	vb_y:      f32,
	vb_w:      f32,
	vb_h:      f32,
}

@(private = "file")
svg_parse_path_data :: proc(path_d: string, vb_x, vb_y, vb_w, vb_h: f32, glyph: ^Glyph_Data) {
	p := SVG_Parser {
		data = path_d,
		vb_x = vb_x,
		vb_y = vb_y,
		vb_w = vb_w,
		vb_h = vb_h,
	}

	for p.pos < len(p.data) {
		svg_skip_ws(&p)
		if p.pos >= len(p.data) do break

		ch := p.data[p.pos]

		if svg_is_command(ch) {
			p.pos += 1
			svg_execute_command(&p, ch, glyph)
		} else if svg_is_number_start(ch) {
			repeat_cmd := p.prev_cmd
			if repeat_cmd == 'M' do repeat_cmd = 'L'
			if repeat_cmd == 'm' do repeat_cmd = 'l'
			if repeat_cmd != 0 {
				svg_execute_command(&p, repeat_cmd, glyph)
			} else {
				p.pos += 1
			}
		} else {
			p.pos += 1
		}
	}
}

@(private = "file")
svg_execute_command :: proc(p: ^SVG_Parser, cmd: u8, glyph: ^Glyph_Data) {
	is_rel := cmd >= 'a' && cmd <= 'z'

	switch cmd {
	case 'M', 'm':
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		if is_rel {
			p.cx += x
			p.cy += y
		} else {
			p.cx = x
			p.cy = y
		}
		p.sx = p.cx
		p.sy = p.cy
		p.prev_cmd = cmd

	case 'L', 'l':
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			p.cx += x
			p.cy += y
		} else {
			p.cx = x
			p.cy = y
		}
		svg_emit_line(p, glyph, x0, y0, p.cx, p.cy)
		p.prev_cmd = cmd

	case 'H', 'h':
		x := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			p.cx += x
		} else {
			p.cx = x
		}
		svg_emit_line(p, glyph, x0, y0, p.cx, p.cy)
		p.prev_cmd = cmd

	case 'V', 'v':
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			p.cy += y
		} else {
			p.cy = y
		}
		svg_emit_line(p, glyph, x0, y0, p.cx, p.cy)
		p.prev_cmd = cmd

	case 'C', 'c':
		c1x := svg_parse_number(p)
		c1y := svg_parse_number(p)
		c2x := svg_parse_number(p)
		c2y := svg_parse_number(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			c1x += x0
			c1y += y0
			c2x += x0
			c2y += y0
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = c2x
		p.prev_cp_y = c2y
		svg_emit_cubic(p, glyph, x0, y0, c1x, c1y, c2x, c2y, x, y)
		p.prev_cmd = cmd

	case 'S', 's':
		c2x := svg_parse_number(p)
		c2y := svg_parse_number(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		c1x, c1y: f32
		if p.prev_cmd == 'C' || p.prev_cmd == 'c' || p.prev_cmd == 'S' || p.prev_cmd == 's' {
			c1x = 2 * p.cx - p.prev_cp_x
			c1y = 2 * p.cy - p.prev_cp_y
		} else {
			c1x = p.cx
			c1y = p.cy
		}
		if is_rel {
			c2x += x0
			c2y += y0
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = c2x
		p.prev_cp_y = c2y
		svg_emit_cubic(p, glyph, x0, y0, c1x, c1y, c2x, c2y, x, y)
		p.prev_cmd = cmd

	case 'Q', 'q':
		cpx := svg_parse_number(p)
		cpy := svg_parse_number(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			cpx += x0
			cpy += y0
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = cpx
		p.prev_cp_y = cpy
		svg_emit_quadratic(p, glyph, x0, y0, cpx, cpy, x, y)
		p.prev_cmd = cmd

	case 'T', 't':
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		cpx, cpy: f32
		if p.prev_cmd == 'Q' || p.prev_cmd == 'q' || p.prev_cmd == 'T' || p.prev_cmd == 't' {
			cpx = 2 * p.cx - p.prev_cp_x
			cpy = 2 * p.cy - p.prev_cp_y
		} else {
			cpx = p.cx
			cpy = p.cy
		}
		if is_rel {
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = cpx
		p.prev_cp_y = cpy
		svg_emit_quadratic(p, glyph, x0, y0, cpx, cpy, x, y)
		p.prev_cmd = cmd

	case 'A', 'a':
		rx := abs(svg_parse_number(p))
		ry := abs(svg_parse_number(p))
		x_rot := svg_parse_number(p) * math.RAD_PER_DEG
		large_arc := svg_parse_flag(p)
		sweep := svg_parse_flag(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		svg_emit_arc(p, glyph, x0, y0, rx, ry, x_rot, large_arc, sweep, x, y)
		p.prev_cmd = cmd

	case 'Z', 'z':
		if p.cx != p.sx || p.cy != p.sy {
			svg_emit_line(p, glyph, p.cx, p.cy, p.sx, p.sy)
		}
		p.cx = p.sx
		p.cy = p.sy
		p.prev_cmd = cmd
	}
}

// --- Coordinate transform ---

@(private = "file")
svg_to_em :: proc(p: ^SVG_Parser, sx, sy: f32) -> [2]f32 {
	// SVG is Y-down, glyph em-space is Y-up — flip Y
	return {(sx - p.vb_x) / p.vb_w, 1.0 - (sy - p.vb_y) / p.vb_h}
}

@(private = "file")
svg_emit_line :: proc(p: ^SVG_Parser, glyph: ^Glyph_Data, x0, y0, x1, y1: f32) {
	p1 := svg_to_em(p, x0, y0)
	p3 := svg_to_em(p, x1, y1)
	p2 := (p1 + p3) * 0.5
	append(&glyph.curves, Bezier_Curve{p1, p2, p3})
}

@(private = "file")
svg_emit_quadratic :: proc(p: ^SVG_Parser, glyph: ^Glyph_Data, x0, y0, cpx, cpy, x1, y1: f32) {
	p1 := svg_to_em(p, x0, y0)
	p2 := svg_to_em(p, cpx, cpy)
	p3 := svg_to_em(p, x1, y1)
	append(&glyph.curves, Bezier_Curve{p1, p2, p3})
}

@(private = "file")
svg_emit_cubic :: proc(
	p: ^SVG_Parser,
	glyph: ^Glyph_Data,
	x0, y0, c1x, c1y, c2x, c2y, x1, y1: f32,
) {
	cp0 := svg_to_em(p, x0, y0)
	cp1 := svg_to_em(p, c1x, c1y)
	cp2 := svg_to_em(p, c2x, c2y)
	cp3 := svg_to_em(p, x1, y1)
	cubic_to_quadratics(cp0, cp1, cp2, cp3, &glyph.curves, CUBIC_TO_QUAD_TOLERANCE)
}

// SVG arc to cubic Bezier conversion (SVG spec F.6).
// Converts endpoint-parameterized arc to center parameterization,
// splits into segments of at most 90 degrees, and approximates
// each segment as a cubic Bezier.
@(private = "file")
svg_emit_arc :: proc(
	p: ^SVG_Parser,
	glyph: ^Glyph_Data,
	x0, y0: f32,
	rx_in, ry_in: f32,
	x_rot: f32,
	large_arc: bool,
	sweep: bool,
	x1, y1: f32,
) {
	// Degenerate: endpoints identical — nothing to draw
	if x0 == x1 && y0 == y1 do return

	rx := rx_in
	ry := ry_in

	// Degenerate: zero radius — treat as line
	if rx == 0 || ry == 0 {
		svg_emit_line(p, glyph, x0, y0, x1, y1)
		return
	}

	cos_rot := math.cos(x_rot)
	sin_rot := math.sin(x_rot)

	// F.6.5.1: Compute (x1', y1') — midpoint in rotated frame
	dx := (x0 - x1) * 0.5
	dy := (y0 - y1) * 0.5
	x1p := cos_rot * dx + sin_rot * dy
	y1p := -sin_rot * dx + cos_rot * dy

	// F.6.6.2: Scale radii up if too small for the endpoint distance
	x1p_sq := x1p * x1p
	y1p_sq := y1p * y1p
	rx_sq := rx * rx
	ry_sq := ry * ry
	lambda := x1p_sq / rx_sq + y1p_sq / ry_sq
	if lambda > 1.0 {
		scale := math.sqrt(lambda)
		rx *= scale
		ry *= scale
		rx_sq = rx * rx
		ry_sq = ry * ry
	}

	// F.6.5.2: Compute (cx', cy') — center in rotated frame
	num := max(rx_sq * ry_sq - rx_sq * y1p_sq - ry_sq * x1p_sq, 0)
	den := rx_sq * y1p_sq + ry_sq * x1p_sq
	sq := math.sqrt(num / den) if den > 1e-10 else 0
	if large_arc == sweep do sq = -sq

	cxp := sq * rx * y1p / ry
	cyp := -sq * ry * x1p / rx

	// F.6.5.3: Compute (cx, cy) — center in original frame
	mx := (x0 + x1) * 0.5
	my := (y0 + y1) * 0.5
	cx := cos_rot * cxp - sin_rot * cyp + mx
	cy := sin_rot * cxp + cos_rot * cyp + my

	// F.6.5.5-6: Compute start angle and sweep angle
	ux := (x1p - cxp) / rx
	uy := (y1p - cyp) / ry
	vx := (-x1p - cxp) / rx
	vy := (-y1p - cyp) / ry

	theta1 := svg_arc_angle(1, 0, ux, uy)
	dtheta := svg_arc_angle(ux, uy, vx, vy)

	// Clamp sweep direction per SVG spec
	if !sweep && dtheta > 0 {
		dtheta -= math.TAU
	} else if sweep && dtheta < 0 {
		dtheta += math.TAU
	}

	// Split into segments of at most 90 degrees
	ARC_SEGMENT_MAX :: math.PI / 2.0
	n_segs := max(1, int(math.ceil(abs(dtheta) / ARC_SEGMENT_MAX)))
	seg_angle := dtheta / f32(n_segs)

	// Cubic Bezier approximation factor for an arc of angle alpha:
	// k = (4/3) * tan(alpha / 4)
	k := (4.0 / 3.0) * math.tan(seg_angle * 0.25)

	angle := theta1
	for _ in 0 ..< n_segs {
		cos_a := math.cos(angle)
		sin_a := math.sin(angle)
		cos_b := math.cos(angle + seg_angle)
		sin_b := math.sin(angle + seg_angle)

		// Unit circle control points for this segment
		// Start: (cos_a, sin_a), End: (cos_b, sin_b)
		// Control 1: start + k * tangent at start
		// Control 2: end - k * tangent at end
		e1x := cos_a
		e1y := sin_a
		e2x := cos_b
		e2y := sin_b
		c1x := e1x - k * e1y
		c1y := e1y + k * e1x
		c2x := e2x + k * e2y
		c2y := e2y - k * e2x

		// Transform from unit circle to original coordinate space:
		// scale by radii, rotate by x_rot, translate to center
		ax0 := cos_rot * rx * e1x - sin_rot * ry * e1y + cx
		ay0 := sin_rot * rx * e1x + cos_rot * ry * e1y + cy
		ac1x := cos_rot * rx * c1x - sin_rot * ry * c1y + cx
		ac1y := sin_rot * rx * c1x + cos_rot * ry * c1y + cy
		ac2x := cos_rot * rx * c2x - sin_rot * ry * c2y + cx
		ac2y := sin_rot * rx * c2x + cos_rot * ry * c2y + cy
		ax1 := cos_rot * rx * e2x - sin_rot * ry * e2y + cx
		ay1 := sin_rot * rx * e2x + cos_rot * ry * e2y + cy

		svg_emit_cubic(p, glyph, ax0, ay0, ac1x, ac1y, ac2x, ac2y, ax1, ay1)

		angle += seg_angle
	}
}

// Angle between two vectors, with sign — used by arc conversion.
@(private = "file")
svg_arc_angle :: proc(ux, uy, vx, vy: f32) -> f32 {
	dot := ux * vx + uy * vy
	len_u := math.sqrt(ux * ux + uy * uy)
	len_v := math.sqrt(vx * vx + vy * vy)
	cos_a := clamp(dot / (len_u * len_v), -1, 1)
	angle := math.acos(cos_a)
	// Sign from cross product
	if ux * vy - uy * vx < 0 {
		angle = -angle
	}
	return angle
}

@(private = "file")
svg_compute_bbox :: proc(glyph: ^Glyph_Data) {
	if len(glyph.curves) == 0 do return

	min_x := max(f32)
	min_y := max(f32)
	max_x := min(f32)
	max_y := min(f32)

	for &curve in glyph.curves {
		for pt in ([3][2]f32{curve.p1, curve.p2, curve.p3}) {
			min_x = math.min(min_x, pt.x)
			min_y = math.min(min_y, pt.y)
			max_x = math.max(max_x, pt.x)
			max_y = math.max(max_y, pt.y)
		}
	}

	glyph.bbox_min = {min_x, min_y}
	glyph.bbox_max = {max_x, max_y}
}

// --- Tokenizer helpers ---

@(private = "file")
svg_skip_ws :: proc(p: ^SVG_Parser) {
	for p.pos < len(p.data) {
		ch := p.data[p.pos]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' {
			p.pos += 1
		} else {
			break
		}
	}
}

@(private = "file")
svg_is_command :: proc(ch: u8) -> bool {
	switch ch {
	case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v':
		return true
	case 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't':
		return true
	case 'A', 'a':
		return true
	case 'Z', 'z':
		return true
	}
	return false
}

@(private = "file")
svg_is_number_start :: proc(ch: u8) -> bool {
	return (ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.'
}

@(private = "file")
svg_parse_number :: proc(p: ^SVG_Parser) -> f32 {
	svg_skip_ws(p)
	if p.pos >= len(p.data) do return 0

	start := p.pos

	if p.pos < len(p.data) && (p.data[p.pos] == '-' || p.data[p.pos] == '+') {
		p.pos += 1
	}

	for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
		p.pos += 1
	}

	if p.pos < len(p.data) && p.data[p.pos] == '.' {
		p.pos += 1
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos += 1
		}
	}

	if p.pos < len(p.data) && (p.data[p.pos] == 'e' || p.data[p.pos] == 'E') {
		p.pos += 1
		if p.pos < len(p.data) && (p.data[p.pos] == '-' || p.data[p.pos] == '+') {
			p.pos += 1
		}
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos += 1
		}
	}

	if p.pos == start do return 0

	num_str := p.data[start:p.pos]
	return parse_f32(num_str)
}

// SVG arc flags are always a single digit (0 or 1) and don't require
// whitespace or comma separators. Using svg_parse_number would misread
// "11" as the number eleven instead of two separate flags.
@(private = "file")
svg_parse_flag :: proc(p: ^SVG_Parser) -> bool {
	svg_skip_ws(p)
	if p.pos >= len(p.data) do return false
	ch := p.data[p.pos]
	if ch == '0' || ch == '1' {
		p.pos += 1
		return ch == '1'
	}
	return false
}

@(private = "file")
parse_f32 :: proc(s: string) -> f32 {
	val, ok := strconv.parse_f32(s)
	if !ok do return 0
	return val
}
