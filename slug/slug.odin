package slug

// ===================================================
// odin-slug — GPU Bezier text rendering library
//
// An Odin implementation of Eric Lengyel's Slug algorithm for
// resolution-independent text and vector icon rendering. The fragment
// shader evaluates quadratic Bezier curves per-pixel using winding
// numbers for crisp, infinitely scalable glyphs at any size or rotation.
//
// This core package is graphics-API-agnostic. It handles:
//   - TTF font loading and glyph extraction (via stb_truetype)
//   - Bezier curve processing and band acceleration
//   - SVG path parsing for vector icons
//   - CPU-side vertex packing for glyph quads
//   - Text measurement and layout
//   - Text effects (rainbow, wobble, shake, rotation, etc.)
//
// Backends (in separate packages) handle GPU upload and rendering:
//   - slug/backends/vulkan  — Vulkan 1.x with GLSL 4.50 shaders
//   - slug/backends/opengl  — OpenGL 3.3 (compatible with Raylib/rlgl)
//   - slug/backends/raylib  — Raylib via rlgl
//
// Usage:
//   1. Create a Context
//   2. Load fonts with font_load / font_load_ascii
//   3. Process fonts with font_process (generates GPU texture data)
//   4. Pass Texture_Pack_Result to your backend for GPU upload
//   5. Per frame: begin() -> draw_text() / draw_icon() -> end()
//   6. Backend reads ctx.vertices[:vertex_count()] and draws
// ===================================================

import stbtt "vendor:stb/truetype"

// --- Constants ---

// Texture dimensions — must match kLogBandTextureWidth in the fragment shader.
// Both curve and band textures use this as their row width.
BAND_TEXTURE_WIDTH_LOG2 :: 12
BAND_TEXTURE_WIDTH :: 1 << BAND_TEXTURE_WIDTH_LOG2 // 4096

// Initial capacity for the per-font glyph map.
// Not a hard limit — the map grows as needed for any Unicode codepoint.
INITIAL_GLYPH_CAPACITY :: 256

// Maximum glyph quads per frame (one quad per visible glyph instance)
MAX_GLYPH_QUADS :: 4096
VERTICES_PER_QUAD :: 4
INDICES_PER_QUAD :: 6
MAX_GLYPH_VERTICES :: MAX_GLYPH_QUADS * VERTICES_PER_QUAD
MAX_GLYPH_INDICES :: MAX_GLYPH_QUADS * INDICES_PER_QUAD

// Maximum simultaneously loaded fonts
MAX_FONT_SLOTS :: 4

// Pixels of quad expansion for antialiasing border
DILATION_SCALE :: f32(1.0)

// Maximum error for cubic-to-quadratic Bezier subdivision (in em-space units)
CUBIC_TO_QUAD_TOLERANCE :: f32(0.001)

// RGBA color as 4 floats (0.0–1.0 per channel).
Color :: [4]f32

// --- Vertex Format ---
// Matches the 5x vec4 attribute layout in the vertex shader (locations 0-4).
// 80 bytes per vertex. All data for fragment-shader curve evaluation is packed
// here — the vertex shader just transforms and forwards it.

Vertex :: struct {
	pos: [4]f32, // .xy = screen position, .zw = dilation normal
	tex: [4]f32, // .xy = em-space texcoord, .zw = packed glyph/band texture coords
	jac: [4]f32, // 2x2 inverse Jacobian (screen-space -> em-space)
	bnd: [4]f32, // band transform: em coord -> band index via (coord * scale + offset)
	col: Color, // vertex color RGBA
}

// --- Curve and Glyph Types ---

Bezier_Curve :: struct {
	p1: [2]f32, // Start point
	p2: [2]f32, // Control point (off-curve)
	p3: [2]f32, // End point
}

// Spatial acceleration band — a horizontal or vertical slice of a glyph.
// The fragment shader only evaluates curves overlapping the current pixel's band.
Band :: struct {
	curve_count: u16,
	data_offset: u16, // Offset into per-glyph curve index list
}

// Per-glyph data: metrics, curves, bands, and GPU texture coordinates.
Glyph_Data :: struct {
	// Metrics (em-space, normalized)
	bbox_min:      [2]f32,
	bbox_max:      [2]f32,
	advance_width: f32,
	left_bearing:  f32,

	// Bezier curves defining the glyph outline
	curves:        [dynamic]Bezier_Curve,

	// Band acceleration data
	h_bands:       [dynamic]Band, // Horizontal bands (Y-axis slices)
	v_bands:       [dynamic]Band, // Vertical bands (X-axis slices)
	h_curve_lists: [dynamic]u16, // Curve indices per horizontal band
	v_curve_lists: [dynamic]u16, // Curve indices per vertical band

	// GPU texture coordinates (set during packing)
	curve_tex_x:   u16,
	curve_tex_y:   u16,
	band_tex_x:    u16,
	band_tex_y:    u16,
	band_max_x:    u16, // Number of vertical bands - 1
	band_max_y:    u16, // Number of horizontal bands - 1

	// Band transform for shader
	band_scale:    [2]f32,
	band_offset:   [2]f32,

	// Identity
	codepoint:     rune,
	glyph_index:   i32,
	valid:         bool,
}

// Font loaded from a TTF file.
Font :: struct {
	info:      stbtt.fontinfo,
	font_data: []u8, // Raw TTF bytes (must stay alive while font is in use)

	// Vertical metrics (em-space)
	ascent:    f32,
	descent:   f32,
	line_gap:  f32,
	em_scale:  f32, // 1.0 / units_per_em

	// Glyph cache keyed by codepoint (supports any Unicode codepoint)
	glyphs:    map[rune]Glyph_Data,
}

// --- Core Context ---
// GPU-agnostic rendering state. Backends embed or wrap this.

Context :: struct {
	// Loaded fonts
	fonts:           [MAX_FONT_SLOTS]Font,
	font_loaded:     [MAX_FONT_SLOTS]bool,
	font_count:      int,

	// Active font for drawing
	active_font_idx: int,

	// UI scale factor — multiplied into font sizes via scaled_size().
	// Set this to match your display DPI or user preference.
	// Default: 1.0 (set in begin()).
	ui_scale:        f32,

	// Per-frame vertex buffer (CPU side — backends upload to GPU)
	vertices:        [MAX_GLYPH_VERTICES]Vertex,
	quad_count:      u32,

	// Per-font quad ranges for batched draw calls
	font_quad_start: [MAX_FONT_SLOTS]u32,
	font_quad_count: [MAX_FONT_SLOTS]u32,
}

// --- Context operations ---

// Reset quad counter for a new frame. Call before any draw_text/draw_icon calls.
begin :: proc(ctx: ^Context) {
	ctx.quad_count = 0
	ctx.active_font_idx = 0
	ctx.font_quad_start = {}
	ctx.font_quad_count = {}
	ctx.font_quad_start[0] = 0
	if ctx.ui_scale == 0 do ctx.ui_scale = 1.0
}

// Finalize per-font quad ranges. Call after all draw calls, before backend flush.
end :: proc(ctx: ^Context) {
	prev := ctx.active_font_idx
	ctx.font_quad_count[prev] = ctx.quad_count - ctx.font_quad_start[prev]
}

// Switch to a different font slot. All subsequent draw calls use this font.
// Returns false if the slot is invalid, not loaded, or already has quads
// (switching back would corrupt the batch layout).
use_font :: proc(ctx: ^Context, slot: int) -> bool {
	if slot < 0 || slot >= MAX_FONT_SLOTS do return false
	if !ctx.font_loaded[slot] do return false
	if slot == ctx.active_font_idx do return true

	// Reject switching back to a font that already has quads
	if ctx.font_quad_count[slot] > 0 do return false

	// Finalize previous font's quad range
	prev := ctx.active_font_idx
	ctx.font_quad_count[prev] = ctx.quad_count - ctx.font_quad_start[prev]

	// Start new font's range
	ctx.active_font_idx = slot
	ctx.font_quad_start[slot] = ctx.quad_count
	return true
}

// Register a loaded font into a context slot.
// slot must be in [0, MAX_FONT_SLOTS). Returns false if the slot is invalid.
register_font :: proc(ctx: ^Context, slot: int, font: Font) -> bool {
	if slot < 0 || slot >= MAX_FONT_SLOTS do return false
	ctx.fonts[slot] = font
	ctx.font_loaded[slot] = true
	if slot >= ctx.font_count {
		ctx.font_count = slot + 1
	}
	return true
}

// Get pointer to the currently active font.
active_font :: proc(ctx: ^Context) -> ^Font {
	assert(ctx.active_font_idx >= 0 && ctx.active_font_idx < MAX_FONT_SLOTS)
	return &ctx.fonts[ctx.active_font_idx]
}

// Set the UI scale factor. Affects all subsequent scaled_size() calls.
// Use this at startup to match display DPI, or at runtime for a user
// "text size" slider.  1.0 = no scaling, 2.0 = double size, etc.
set_ui_scale :: proc(ctx: ^Context, scale: f32) {
	ctx.ui_scale = scale if scale > 0 else 1.0
}

// Apply the context's UI scale to a logical font size.
// Use this in draw and measure calls so text scales uniformly:
//   slug.draw_text(ctx, "hello", x, y, slug.scaled_size(ctx, 24), color)
//   w, h := slug.measure_text(font, "hello", slug.scaled_size(ctx, 24))
scaled_size :: proc(ctx: ^Context, font_size: f32) -> f32 {
	return font_size * ctx.ui_scale
}

// Number of vertices written this frame (for backend upload).
vertex_count :: proc(ctx: ^Context) -> u32 {
	return ctx.quad_count * VERTICES_PER_QUAD
}

// Look up a glyph by codepoint. Returns nil if not loaded.
get_glyph :: proc(font: ^Font, ch: rune) -> ^Glyph_Data {
	g, ok := &font.glyphs[ch]
	if !ok || !g.valid do return nil
	return g
}

// --- Cleanup ---

glyph_data_destroy :: proc(g: ^Glyph_Data) {
	delete(g.curves)
	delete(g.h_bands)
	delete(g.v_bands)
	delete(g.h_curve_lists)
	delete(g.v_curve_lists)
	g^ = {}
}

font_destroy :: proc(font: ^Font) {
	for _, &g in font.glyphs {
		glyph_data_destroy(&g)
	}
	delete(font.glyphs)
	delete(font.font_data)
	font^ = {}
}

// Unload a single font from a context slot, freeing its glyph data.
// The backend is responsible for releasing any associated GPU resources.
unload_font :: proc(ctx: ^Context, slot: int) {
	if slot < 0 || slot >= MAX_FONT_SLOTS do return
	if !ctx.font_loaded[slot] do return
	font_destroy(&ctx.fonts[slot])
	ctx.font_loaded[slot] = false
}

destroy :: proc(ctx: ^Context) {
	for i in 0 ..< MAX_FONT_SLOTS {
		if ctx.font_loaded[i] {
			font_destroy(&ctx.fonts[i])
			ctx.font_loaded[i] = false
		}
	}
}
