package slug

// ===================================================
// Rich text — inline color and background markup.
//
// Foreground color:   {color_name:text} or {#rrggbb:text}
// Background color:   {bg:color_name:text} or {bg:#rrggbb:text}
// Untagged text uses the default color passed to draw_rich_text.
//
// Supported named colors: red, green, blue, yellow, cyan, magenta,
// orange, white, black, gray, light_gray, dark_gray.
//
// Examples:
//   "You deal {red:15} damage!"
//   "Found a {yellow:Golden Sword} in the chest."
//   "{#ff8800:Warning:} low health!"
//   "Status: {bg:red:POISONED}"
//   "{bg:#003300:{green:STEALTH}}"   -- bg + fg on same text (bg tag wraps fg tag — not nesting)
//   "Plain text with no markup works too."
//
// Nesting is NOT supported. Braces inside tagged text are literal.
// To draw a literal '{', use '{{'.
// ===================================================

// A parsed segment of rich text — either plain or colored.
@(private = "file")
Rich_Segment :: struct {
	text:  string, // Slice into original string (no allocation)
	color: Color,
}

// Draw rich text with inline color and background markup at the given position.
// Parses markup on the fly and draws each segment with its colors.
// Returns the total width drawn (for positioning content after it).
draw_rich_text :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	default_color: Color,
	use_kerning: bool = true,
) -> f32 {
	font := active_font(ctx)
	pen_x := x

	i := 0
	for i < len(text) {
		// Look for start of markup
		if text[i] == '{' {
			// Escaped brace: {{ => literal {
			if i + 1 < len(text) && text[i + 1] == '{' {
				draw_text(ctx, "{", pen_x, y, font_size, default_color, use_kerning)
				w, _ := measure_text(font, "{", font_size, use_kerning)
				pen_x += w
				i += 2
				continue
			}

			// Try to parse {bg:color:text} first
			bg_color, seg_text, end_pos, bg_ok := parse_bg_tag(text, i)
			if bg_ok {
				w, h := measure_text(font, seg_text, font_size, use_kerning)
				rect_y := y - font.ascent * font_size
				draw_rect(ctx, pen_x, rect_y, w, h, bg_color)
				draw_text(ctx, seg_text, pen_x, y, font_size, default_color, use_kerning)
				pen_x += w
				i = end_pos
				continue
			}

			// Try to parse {color:text}
			seg_color, seg_text2, end_pos2, fg_ok := parse_rich_tag(text, i)
			if fg_ok {
				draw_text(ctx, seg_text2, pen_x, y, font_size, seg_color, use_kerning)
				w, _ := measure_text(font, seg_text2, font_size, use_kerning)
				pen_x += w
				i = end_pos2
				continue
			}
		}

		// Plain text: consume until next '{' or end
		plain_start := i
		for i < len(text) && text[i] != '{' {
			i += 1
		}
		plain := text[plain_start:i]
		if len(plain) > 0 {
			draw_text(ctx, plain, pen_x, y, font_size, default_color, use_kerning)
			w, _ := measure_text(font, plain, font_size, use_kerning)
			pen_x += w
		}
	}

	return pen_x - x
}

// Measure rich text width without drawing.
// Parses the same markup as draw_rich_text but only accumulates advance widths.
measure_rich_text :: proc(
	font: ^Font,
	text: string,
	font_size: f32,
	use_kerning: bool = true,
) -> (
	width: f32,
	height: f32,
) {
	pen_x: f32 = 0

	i := 0
	for i < len(text) {
		if text[i] == '{' {
			if i + 1 < len(text) && text[i + 1] == '{' {
				w, _ := measure_text(font, "{", font_size, use_kerning)
				pen_x += w
				i += 2
				continue
			}

			_, seg_text, end_pos, ok := parse_rich_tag(text, i)
			if ok {
				w, _ := measure_text(font, seg_text, font_size, use_kerning)
				pen_x += w
				i = end_pos
				continue
			}
		}

		plain_start := i
		for i < len(text) && text[i] != '{' {
			i += 1
		}
		plain := text[plain_start:i]
		if len(plain) > 0 {
			w, _ := measure_text(font, plain, font_size, use_kerning)
			pen_x += w
		}
	}

	return pen_x, (font.ascent - font.descent) * font_size
}

// Draw rich text centered at x.
draw_rich_text_centered :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	default_color: Color,
	use_kerning: bool = true,
) -> f32 {
	font := active_font(ctx)
	w, _ := measure_rich_text(font, text, font_size, use_kerning)
	return draw_rich_text(ctx, text, x - w * 0.5, y, font_size, default_color, use_kerning)
}

// Strip all rich text markup, returning plain text length in bytes.
// Useful for cursor positioning: convert rich text positions to plain positions.
rich_text_plain_length :: proc(text: string) -> int {
	count := 0
	i := 0
	for i < len(text) {
		if text[i] == '{' {
			if i + 1 < len(text) && text[i + 1] == '{' {
				count += 1 // escaped brace = 1 char
				i += 2
				continue
			}
			_, seg_text, end_pos, ok := parse_rich_tag(text, i)
			if ok {
				count += len(seg_text)
				i = end_pos
				continue
			}
		}
		count += 1
		i += 1
	}
	return count
}

// --- Internal parsing ---

// Parse a {bg:color:text} background tag starting at `start`.
// Returns the background color, the inner text, position after '}', and success.
// The inner text is drawn with the caller's default foreground color —
// nest a {color:...} tag inside if you also want a custom foreground.
@(private = "file")
parse_bg_tag :: proc(text: string, start: int) -> (bg_color: Color, inner: string, end_pos: int, ok: bool) {
	if start >= len(text) || text[start] != '{' do return {}, "", start, false

	// Must start with "{bg:"
	prefix :: "{bg:"
	if start + len(prefix) > len(text) do return {}, "", start, false
	if text[start:start + len(prefix)] != prefix do return {}, "", start, false

	// Find the second colon (separating color from text)
	colon2 := -1
	for j := start + len(prefix); j < len(text); j += 1 {
		if text[j] == ':' {
			colon2 = j
			break
		}
		if text[j] == '}' || text[j] == '{' {
			return {}, "", start, false
		}
	}
	if colon2 < 0 do return {}, "", start, false

	color_name := text[start + len(prefix):colon2]

	// Find closing brace
	close := -1
	for j := colon2 + 1; j < len(text); j += 1 {
		if text[j] == '}' {
			close = j
			break
		}
	}
	if close < 0 do return {}, "", start, false

	inner_text := text[colon2 + 1:close]

	resolved, color_ok := resolve_color_name(color_name)
	if !color_ok do return {}, "", start, false

	return resolved, inner_text, close + 1, true
}

// Parse a {color:text} tag starting at position `start` (which should be '{').
// Returns the color, the inner text (as a slice of the original string),
// the position after the closing '}', and whether parsing succeeded.
@(private = "file")
parse_rich_tag :: proc(text: string, start: int) -> (color: Color, inner: string, end_pos: int, ok: bool) {
	if start >= len(text) || text[start] != '{' do return {}, "", start, false

	// Find the colon separator
	colon := -1
	for j := start + 1; j < len(text); j += 1 {
		if text[j] == ':' {
			colon = j
			break
		}
		if text[j] == '}' || text[j] == '{' {
			// No colon before end — not a valid tag
			return {}, "", start, false
		}
	}
	if colon < 0 do return {}, "", start, false

	color_name := text[start + 1:colon]

	// Find closing brace
	close := -1
	for j := colon + 1; j < len(text); j += 1 {
		if text[j] == '}' {
			close = j
			break
		}
	}
	if close < 0 do return {}, "", start, false

	inner_text := text[colon + 1:close]

	// Resolve color
	resolved, color_ok := resolve_color_name(color_name)
	if !color_ok do return {}, "", start, false

	return resolved, inner_text, close + 1, true
}

// Resolve a color name or hex code to a Color value.
@(private = "file")
resolve_color_name :: proc(name: string) -> (Color, bool) {
	// Named colors
	switch name {
	case "red":
		return RED, true
	case "green":
		return GREEN, true
	case "blue":
		return BLUE, true
	case "yellow":
		return YELLOW, true
	case "cyan":
		return CYAN, true
	case "magenta":
		return MAGENTA, true
	case "orange":
		return ORANGE, true
	case "white":
		return WHITE, true
	case "black":
		return BLACK, true
	case "gray", "grey":
		return GRAY, true
	case "light_gray", "light_grey":
		return LIGHT_GRAY, true
	case "dark_gray", "dark_grey":
		return DARK_GRAY, true
	}

	// Hex color: #rrggbb or #rgb
	if len(name) > 0 && name[0] == '#' {
		hex := name[1:]
		if len(hex) == 6 {
			r := hex_byte(hex[0:2])
			g := hex_byte(hex[2:4])
			b := hex_byte(hex[4:6])
			return Color{f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 1.0}, true
		}
		if len(hex) == 3 {
			r := hex_nibble(hex[0])
			g := hex_nibble(hex[1])
			b := hex_nibble(hex[2])
			return Color{f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 1.0}, true
		}
	}

	return {}, false
}

// Parse a 2-character hex string to a byte value (0-255).
@(private = "file")
hex_byte :: proc(s: string) -> u8 {
	if len(s) != 2 do return 0
	return hex_nibble(s[0]) * 16 + hex_nibble(s[1])
}

// Parse a single hex character to a value (0-15), doubled for #rgb shorthand.
@(private = "file")
hex_nibble :: proc(c: u8) -> u8 {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}
