#+build !js
package slug

import "core:os"

// Load an SVG file from disk, parse it, and process for GPU rendering.
// Desktop only — use svg_parse for WASM.
svg_load_icon :: proc(path: string) -> (icon: SVG_Icon, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(data)

	return svg_parse(string(data))
}

// Load an SVG file and place it into a font's glyph slot.
// Must be called BEFORE font_process / pack_glyph_textures.
svg_load_into_font :: proc(font: ^Font, slot_index: int, path: string) -> bool {
	icon, icon_ok := svg_load_icon(path)
	if !icon_ok do return false

	svg_icon_into_font(font, slot_index, icon)
	return true
}
