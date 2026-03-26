#+build !js
package slug

import "core:os"

// Load a TTF font file from disk.
// Desktop only — use font_load_mem for WASM.
font_load :: proc(path: string) -> (font: Font, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(data)
	return font_load_mem(data)
}

// Convenience: load a font, its ASCII glyphs, optional SVG icons, and process.
// Returns the font and packed texture data ready for backend upload.
// icons is a slice of {slot_index, svg_path} pairs (use slots 128+).
Icon_Def :: struct {
	slot: int,
	path: string,
}

font_load_with_icons :: proc(
	ttf_path: string,
	icons: []Icon_Def = {},
) -> (
	font: Font,
	pack: Texture_Pack_Result,
	ok: bool,
) {
	font_ok: bool
	font, font_ok = font_load(ttf_path)
	if !font_ok do return {}, {}, false

	font_load_ascii(&font)

	for icon in icons {
		svg_load_into_font(&font, icon.slot, icon.path)
	}

	pack = font_process(&font)
	return font, pack, true
}
