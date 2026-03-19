package slug

import "core:fmt"
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
// Supported commands: M/m L/l H/h V/v C/c S/s Q/q T/t Z/z
// Arc (A/a) is NOT supported.
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
		fmt.eprintln("Failed to read SVG file:", path)
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
		fmt.eprintln("SVG: no path d attribute found")
		return {}, false
	}

	svg_parse_path_data(path_d, vb_x, vb_y, vb_w, vb_h, &icon.glyph)

	if len(icon.glyph.curves) == 0 {
		fmt.eprintln("SVG: no curves parsed from path data")
		return {}, false
	}

	svg_compute_bbox(&icon.glyph)

	icon.glyph.advance_width = icon.glyph.bbox_max.x - icon.glyph.bbox_min.x
	icon.glyph.left_bearing = icon.glyph.bbox_min.x
	icon.glyph.valid = true

	glyph_process(&icon.glyph)

	fmt.printf(
		"SVG loaded: %d curves, bbox=(%.3f,%.3f)-(%.3f,%.3f)\n",
		len(icon.glyph.curves),
		icon.glyph.bbox_min.x,
		icon.glyph.bbox_min.y,
		icon.glyph.bbox_max.x,
		icon.glyph.bbox_max.y,
	)

	return icon, true
}

// Load an SVG file and place it into a font's glyph slot.
// Must be called BEFORE process_font / pack_glyph_textures.
svg_load_into_font :: proc(font: ^Font, slot_index: int, path: string) -> bool {
	if slot_index < 0 || slot_index >= MAX_CACHED_GLYPHS {
		fmt.eprintln("SVG: invalid glyph slot index:", slot_index)
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

svg_extract_path_d :: proc(svg: string) -> string {
	d_start := strings.index(svg, " d=\"")
	if d_start < 0 do return ""
	d_start += len(" d=\"")
	d_end := strings.index(svg[d_start:], "\"")
	if d_end < 0 do return ""
	return svg[d_start:][:d_end]
}

// --- SVG path parser ---

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

svg_parse_path_data :: proc(path_d: string, vb_x, vb_y, vb_w, vb_h: f32, glyph: ^Glyph_Data) {
	p := SVG_Parser{
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

svg_to_em :: proc(p: ^SVG_Parser, sx, sy: f32) -> [2]f32 {
	return {(sx - p.vb_x) / p.vb_w, 1.0 - (sy - p.vb_y) / p.vb_h}
}

svg_emit_line :: proc(p: ^SVG_Parser, glyph: ^Glyph_Data, x0, y0, x1, y1: f32) {
	p1 := svg_to_em(p, x0, y0)
	p3 := svg_to_em(p, x1, y1)
	p2 := (p1 + p3) * 0.5
	append(&glyph.curves, Bezier_Curve{p1, p2, p3})
}

svg_emit_quadratic :: proc(p: ^SVG_Parser, glyph: ^Glyph_Data, x0, y0, cpx, cpy, x1, y1: f32) {
	p1 := svg_to_em(p, x0, y0)
	p2 := svg_to_em(p, cpx, cpy)
	p3 := svg_to_em(p, x1, y1)
	append(&glyph.curves, Bezier_Curve{p1, p2, p3})
}

svg_emit_cubic :: proc(
	p: ^SVG_Parser,
	glyph: ^Glyph_Data,
	x0, y0, c1x, c1y, c2x, c2y, x1, y1: f32,
) {
	cp0 := svg_to_em(p, x0, y0)
	cp1 := svg_to_em(p, c1x, c1y)
	cp2 := svg_to_em(p, c2x, c2y)
	cp3 := svg_to_em(p, x1, y1)
	cubic_to_quadratics(cp0, cp1, cp2, cp3, &glyph.curves, 0.001)
}

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

svg_is_number_start :: proc(ch: u8) -> bool {
	return (ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.'
}

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

parse_f32 :: proc(s: string) -> f32 {
	val, ok := strconv.parse_f32(s)
	if !ok do return 0
	return val
}
