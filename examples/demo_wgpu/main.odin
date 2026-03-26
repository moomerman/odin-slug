package main

// ===================================================
// odin-slug WebGPU Demo
//
// Standalone example showing GPU-accelerated Bezier text rendering
// using odin-slug with a WebGPU backend. Uses GLFW for windowing.
//
// Showcases all text-only features of the slug library: layout,
// alignment, rich text, sub/super, truncation, justification,
// columns, grid, caching, SVG icons, and animated effects.
//
// Build:  odin build examples/demo_wgpu/ -collection:libs=.
// Run:    ./demo_wgpu
//
// Prerequisites:
//   - Liberation fonts in examples/assets/fonts/
//   - SVG icons in examples/assets/icons/
//   - WebGPU-capable GPU
// ===================================================

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

import "vendor:glfw"
import "vendor:wgpu"
import "vendor:wgpu/glfwglue"

import slug "../../slug"
import slug_wgpu "../../slug/backends/wgpu"

// --- Window ---

WINDOW_TITLE :: "odin-slug WebGPU Demo"
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 820

// --- Font paths ---

FONT_SANS :: "examples/assets/fonts/LiberationSans-Regular.ttf"
FONT_SERIF :: "examples/assets/fonts/LiberationSerif-Regular.ttf"

// --- SVG icon glyph slots ---

ICON_SWORD :: 128
ICON_HEART :: 129
ICON_SHIELD :: 130
ICON_CIRCLE :: 131

ICON_SWORD_PATH :: "examples/assets/icons/sword.svg"
ICON_HEART_PATH :: "examples/assets/icons/heart.svg"
ICON_SHIELD_PATH :: "examples/assets/icons/shield.svg"
ICON_CIRCLE_PATH :: "examples/assets/icons/circle.svg"

// --- Text sizes ---

TITLE_SIZE :: f32(48)
BODY_SIZE :: f32(28)
SMALL_SIZE :: f32(20)
TINY_SIZE :: f32(16)
ICON_SIZE :: f32(40)

// --- Layout ---

LEFT_X :: f32(40)
MID_X :: f32(480)
RIGHT_X :: f32(900)

COL_WIDTH :: f32(380)
WRAP_W :: f32(280)

// Left column rows
L_TITLE :: f32(70)
L_SUBTITLE :: f32(120)
L_DIM_1 :: f32(160)
L_DIM_2 :: f32(186)
L_KERNING :: f32(220)
L_SIZES :: f32(255)
L_SERIF :: f32(295)
L_SHADOW :: f32(335)
L_OUTLINED :: f32(380)
L_SUBSUPER :: f32(420)
L_FLOAT :: f32(460)
L_CENTERED :: f32(500)
L_RIGHT :: f32(540)
L_TRUNCATED :: f32(585)
L_TRUNC_WORD :: f32(615)
L_JUSTIFIED :: f32(660)
L_WRAP :: f32(700)

// Middle column rows
M_HEADER :: f32(60)
M_RICH_1 :: f32(95)
M_RICH_2 :: f32(135)
M_RICH_WRAP :: f32(180)
M_COL_HEADER :: f32(290)
M_COL_HDR_ROW :: f32(315)
M_COL_ROW_1 :: f32(345)
M_COL_ROW_2 :: f32(375)
M_GRID_HEADER :: f32(415)
M_GRID :: f32(440)
M_CACHE_HEADER :: f32(540)
M_CACHED :: f32(570)
M_ICONS_HEADER :: f32(620)
M_ICONS :: f32(665)
M_RICH_ICONS :: f32(720)
M_WAVE :: f32(770)

// Right column rows
R_HEADER :: f32(60)
R_RAINBOW :: f32(95)
R_WOBBLE :: f32(135)
R_PULSE :: f32(175)
R_SHAKE :: f32(215)
R_TYPEWRITER :: f32(255)
R_GRADIENT :: f32(295)
R_FADE :: f32(335)
R_ROTATED :: f32(395)
R_TRANSFORMED :: f32(465)
R_CIRCLE :: f32(580)
R_FLOAT_DEMO :: f32(740)

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}
COLOR_GREEN :: [4]f32{0.3, 1.0, 0.5, 1.0}
COLOR_RED :: [4]f32{1.0, 0.3, 0.3, 1.0}
COLOR_DIM :: [4]f32{0.5, 0.5, 0.5, 1.0}
COLOR_HEADER :: [4]f32{0.55, 0.55, 0.75, 1.0}
COLOR_BG :: [4]f64{0.18, 0.19, 0.24, 1.0}

// --- Global state for async wgpu init ---

State :: struct {
	odin_ctx:       runtime.Context,
	window:         glfw.WindowHandle,
	instance:       wgpu.Instance,
	surface:        wgpu.Surface,
	adapter:        wgpu.Adapter,
	device:         wgpu.Device,
	queue:          wgpu.Queue,
	surface_format: wgpu.TextureFormat,
	renderer:       slug_wgpu.Renderer,
	cached_label:   slug.Text_Cache,
	ready:          bool,
	start_time:     time.Time,
	width:          u32,
	height:         u32,
}

state: State

main :: proc() {
	state.odin_ctx = context
	state.start_time = time.now()

	// -----------------------------------------------
	// 1. Create GLFW window (no graphics API)
	// -----------------------------------------------

	if !glfw.Init() {
		fmt.eprintln("Failed to initialize GLFW")
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

	state.window = glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
	if state.window == nil {
		fmt.eprintln("Failed to create GLFW window")
		return
	}
	defer glfw.DestroyWindow(state.window)

	// -----------------------------------------------
	// 2. Initialize WebGPU
	// -----------------------------------------------

	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil {
		fmt.eprintln("WebGPU is not supported")
		return
	}

	state.surface = glfwglue.GetSurface(state.instance, state.window)
	if state.surface == nil {
		fmt.eprintln("Failed to create wgpu surface")
		return
	}

	wgpu.InstanceRequestAdapter(
		state.instance,
		&{compatibleSurface = state.surface},
		{callback = on_adapter},
	)

	// -----------------------------------------------
	// 3. Main loop
	// -----------------------------------------------

	for !glfw.WindowShouldClose(state.window) {
		glfw.PollEvents()

		if glfw.GetKey(state.window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(state.window, true)
		}

		if state.ready {
			render_frame()
		}
	}

	// -----------------------------------------------
	// 4. Cleanup
	// -----------------------------------------------

	if state.ready {
		slug.cache_destroy(&state.cached_label)
		slug_wgpu.destroy(&state.renderer)
	}
	wgpu.SurfaceRelease(state.surface)
	wgpu.InstanceRelease(state.instance)
}

// --- Async WebGPU initialization callbacks ---

on_adapter :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: string,
	userdata1, userdata2: rawptr,
) {
	context = state.odin_ctx
	if status != .Success || adapter == nil {
		fmt.panicf("request adapter failure: [%v] %s", status, message)
	}
	state.adapter = adapter
	wgpu.AdapterRequestDevice(adapter, nil, {callback = on_device})
}

on_device :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: string,
	userdata1, userdata2: rawptr,
) {
	context = state.odin_ctx
	if status != .Success || device == nil {
		fmt.panicf("request device failure: [%v] %s", status, message)
	}
	state.device = device
	state.queue = wgpu.DeviceGetQueue(device)
	on_ready()
}

on_ready :: proc() {
	// Get framebuffer size
	fb_w, fb_h := glfw.GetFramebufferSize(state.window)
	state.width = u32(fb_w)
	state.height = u32(fb_h)

	// Configure surface
	state.surface_format = .BGRA8Unorm
	wgpu.SurfaceConfigure(
		state.surface,
		&{
			device = state.device,
			usage = {.RenderAttachment},
			format = state.surface_format,
			width = state.width,
			height = state.height,
			presentMode = .Fifo,
			alphaMode = .Opaque,
		},
	)

	// Initialize slug renderer
	slug_wgpu.init(&state.renderer, state.device, state.queue, state.surface_format)
	sctx := slug_wgpu.ctx(&state.renderer)

	// Load fonts (from memory — keeps the demo WASM-friendly later)
	sans_data, sans_err := os.read_entire_file(FONT_SANS, context.allocator)
	if sans_err != nil {
		fmt.eprintln("Failed to load font:", FONT_SANS)
		return
	}
	defer delete(sans_data)

	font0, font0_ok := slug.font_load_mem(sans_data)
	if !font0_ok {
		fmt.eprintln("Failed to parse font:", FONT_SANS)
		return
	}
	slug.font_load_ascii(&font0)
	slug.font_load_range(&font0, 160, 255) // Latin-1 Supplement (² ³ π …)
	slug.font_load_glyph(&font0, '☺')      // For grid demo

	// Load SVG icons into the sans font
	slug.svg_load_into_font(&font0, ICON_SWORD, ICON_SWORD_PATH)
	slug.svg_load_into_font(&font0, ICON_HEART, ICON_HEART_PATH)
	slug.svg_load_into_font(&font0, ICON_SHIELD, ICON_SHIELD_PATH)
	slug.svg_load_into_font(&font0, ICON_CIRCLE, ICON_CIRCLE_PATH)

	slug.register_font(sctx, 0, font0)

	serif_data, serif_err := os.read_entire_file(FONT_SERIF, context.allocator)
	if serif_err != nil {
		fmt.eprintln("Failed to load font:", FONT_SERIF)
		return
	}
	defer delete(serif_data)

	font1, font1_ok := slug.font_load_mem(serif_data)
	if !font1_ok {
		fmt.eprintln("Failed to parse font:", FONT_SERIF)
		return
	}
	slug.font_load_ascii(&font1)
	slug.register_font(sctx, 1, font1)

	slug.font_set_fallback(sctx, 0, 1)

	pack := slug.fonts_process_shared(sctx)
	defer slug.pack_result_destroy(&pack)
	slug_wgpu.upload_shared_textures(&state.renderer, &pack)

	// Build the cached label once. Must be inside a begin/end block.
	slug.begin(sctx)
	state.cached_label = slug.cache_text(
		sctx,
		"Cached label (no per-frame work)",
		MID_X,
		M_CACHED,
		SMALL_SIZE,
		COLOR_GREEN,
	)
	slug.end(sctx)

	state.ready = true
}

// --- Rendering ---

render_frame :: proc() {
	// Handle resize
	fb_w, fb_h := glfw.GetFramebufferSize(state.window)
	w := u32(fb_w)
	h := u32(fb_h)
	if w != state.width || h != state.height {
		state.width = w
		state.height = h
		wgpu.SurfaceConfigure(
			state.surface,
			&{
				device = state.device,
				usage = {.RenderAttachment},
				format = state.surface_format,
				width = w,
				height = h,
				presentMode = .Fifo,
				alphaMode = .Opaque,
			},
		)
	}

	if w == 0 || h == 0 do return

	// Get surface texture
	surface_tex := wgpu.SurfaceGetCurrentTexture(state.surface)
	switch surface_tex.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// OK
	case .Timeout, .Outdated, .Lost, .Occluded:
		if surface_tex.texture != nil {
			wgpu.TextureRelease(surface_tex.texture)
		}
		return
	case .Error:
		fmt.panicf("get_current_texture status=%v", surface_tex.status)
	}
	defer wgpu.TextureRelease(surface_tex.texture)

	view := wgpu.TextureCreateView(surface_tex.texture, nil)
	defer wgpu.TextureViewRelease(view)

	encoder := wgpu.DeviceCreateCommandEncoder(state.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = view,
				loadOp = .Clear,
				storeOp = .Store,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				clearValue = {COLOR_BG.x, COLOR_BG.y, COLOR_BG.z, COLOR_BG.w},
			},
		},
	)

	t := f32(time.duration_seconds(time.since(state.start_time)))
	sctx := slug_wgpu.ctx(&state.renderer)

	slug.begin(sctx)
	draw_text_content(sctx, t)
	slug.end(sctx)

	slug_wgpu.flush(&state.renderer, pass, w, h)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	cmd := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(cmd)
	wgpu.QueueSubmit(state.queue, {cmd})
	wgpu.SurfacePresent(state.surface)
}

draw_text_content :: proc(sctx: ^slug.Context, t: f32) {
	draw_left_column(sctx, t)
	draw_middle_column(sctx, t)
	draw_right_column(sctx, t)
}

// ---- Left column: basics, layout, decorations ----

draw_left_column :: proc(sctx: ^slug.Context, t: f32) {
	// Title with built-in drop shadow
	slug.draw_text_shadow(sctx, "odin-slug", LEFT_X, L_TITLE, TITLE_SIZE, COLOR_WHITE)

	// Subtitle
	slug.draw_text(sctx, "WebGPU Backend Demo", LEFT_X, L_SUBTITLE, BODY_SIZE, COLOR_CYAN)

	// Body text + dim line
	slug.draw_text(sctx, "GPU-evaluated Bezier curves.", LEFT_X, L_DIM_1, SMALL_SIZE, COLOR_WHITE)
	slug.draw_text(sctx, "Resolution-independent, crisp at any size.", LEFT_X, L_DIM_2, SMALL_SIZE, COLOR_DIM)

	// Kerning demo
	slug.draw_text(sctx, "AV WA To VA: kerning pairs", LEFT_X, L_KERNING, SMALL_SIZE, COLOR_YELLOW)

	// Multiple sizes
	slug.draw_text(sctx, "Big",    LEFT_X,        L_SIZES, 40, COLOR_WHITE)
	slug.draw_text(sctx, "Medium", LEFT_X + 100,  L_SIZES, 28, COLOR_WHITE)
	slug.draw_text(sctx, "Small",  LEFT_X + 240,  L_SIZES, 18, COLOR_WHITE)
	slug.draw_text(sctx, "Tiny",   LEFT_X + 320,  L_SIZES, 12, COLOR_WHITE)

	// Serif fallback (font 1)
	slug.use_font(sctx, 1)
	slug.draw_text(sctx, "Serif via fallback chain.", LEFT_X, L_SERIF, BODY_SIZE, COLOR_WHITE)
	slug.use_font(sctx, 0)

	// Drop shadow
	slug.draw_text_shadow(sctx, "Shadow Text", LEFT_X, L_SHADOW, BODY_SIZE, COLOR_WHITE)

	// Outlined
	slug.draw_text_outlined(sctx, "Outlined Text", LEFT_X, L_OUTLINED, BODY_SIZE, COLOR_YELLOW)

	// Sub / super: H₂O · E = mc²  composed manually
	font := slug.active_font(sctx)
	pen := LEFT_X
	slug.draw_text(sctx, "H", pen, L_SUBSUPER, BODY_SIZE, COLOR_WHITE)
	hw, _ := slug.measure_text(font, "H", BODY_SIZE)
	pen += hw
	slug.draw_text_sub(sctx, "2", pen, L_SUBSUPER, BODY_SIZE, COLOR_WHITE)
	sub_w, _ := slug.measure_text(font, "2", BODY_SIZE * slug.SUB_SCALE)
	pen += sub_w
	slug.draw_text(sctx, "O   E = mc", pen, L_SUBSUPER, BODY_SIZE, COLOR_WHITE)
	rest_w, _ := slug.measure_text(font, "O   E = mc", BODY_SIZE)
	pen += rest_w
	slug.draw_text_super(sctx, "2", pen, L_SUBSUPER, BODY_SIZE, COLOR_WHITE)

	// Animated value via fmt.tprintf + draw_text — shows how to mix runtime
	// strings with the library (no built-in number formatter).
	val := math.sin(t) * 50.0 + 50.0
	slug.draw_text(sctx, "Live:", LEFT_X, L_FLOAT, BODY_SIZE, COLOR_DIM)
	slug.draw_text(sctx, fmt.tprintf("%.2f", val), LEFT_X + 80, L_FLOAT, BODY_SIZE, COLOR_GREEN)

	// Centered (anchor x = column center)
	slug.draw_text_centered(sctx, "Centered Text", LEFT_X + COL_WIDTH * 0.5, L_CENTERED, BODY_SIZE, COLOR_WHITE)

	// Right-aligned (anchor x = column right edge)
	slug.draw_text_right(sctx, "Right Aligned", LEFT_X + COL_WIDTH, L_RIGHT, BODY_SIZE, COLOR_WHITE)

	// Truncated (char-level)
	slug.draw_text(sctx, "Trunc:", LEFT_X, L_TRUNCATED, SMALL_SIZE, COLOR_DIM)
	slug.draw_text_truncated(
		sctx,
		"This very long sentence will be clipped",
		LEFT_X + 60, L_TRUNCATED, SMALL_SIZE, COL_WIDTH - 60, COLOR_WHITE,
	)

	// Truncated (word boundary)
	slug.draw_text(sctx, "Word: ", LEFT_X, L_TRUNC_WORD, SMALL_SIZE, COLOR_DIM)
	slug.draw_text_truncated_word(
		sctx,
		"This very long sentence will be clipped",
		LEFT_X + 60, L_TRUNC_WORD, SMALL_SIZE, COL_WIDTH - 60, COLOR_WHITE,
	)

	// Justified (one line, fills column width)
	slug.draw_text_justified(
		sctx,
		"Justified across the full column width here",
		LEFT_X, L_JUSTIFIED, SMALL_SIZE, COL_WIDTH, COLOR_CYAN,
	)

	// Word wrap (smaller box than before)
	slug.draw_text_wrapped(
		sctx,
		"Word wrapping breaks at word boundaries inside a fixed width.",
		LEFT_X, L_WRAP, SMALL_SIZE, WRAP_W, COLOR_WHITE,
	)
}

// ---- Middle column: rich text, columns, grid, cache, icons ----

draw_middle_column :: proc(sctx: ^slug.Context, t: f32) {
	slug.draw_text(sctx, "Rich text:", MID_X, M_HEADER, SMALL_SIZE, COLOR_HEADER)

	// Inline color markup
	slug.draw_rich_text(
		sctx,
		"HP {green:95}/100  MP {cyan:42}/50  XP {yellow:1280}",
		MID_X, M_RICH_1, BODY_SIZE, COLOR_WHITE,
	)
	slug.draw_rich_text(
		sctx,
		"Found a {yellow:Golden Sword}!",
		MID_X, M_RICH_2, BODY_SIZE, COLOR_WHITE,
	)

	// Wrapped rich text
	slug.draw_rich_text_wrapped(
		sctx,
		"Markup like {red:hostile} and {green:friendly} text wraps cleanly across multiple lines.",
		MID_X, M_RICH_WRAP, SMALL_SIZE, COL_WIDTH, COLOR_WHITE,
	)

	// Columns table
	slug.draw_text(sctx, "Columns:", MID_X, M_COL_HEADER, SMALL_SIZE, COLOR_HEADER)
	slug.draw_text_columns(sctx, {
		{text = "Name",     width = 160, align = .Left,   color = COLOR_HEADER},
		{text = "HP",       width = 80,  align = .Right,  color = COLOR_HEADER},
		{text = "Status",   width = 140, align = .Center, color = COLOR_HEADER},
	}, MID_X, M_COL_HDR_ROW, SMALL_SIZE, COLOR_WHITE)
	slug.draw_text_columns(sctx, {
		{text = "Skeleton", width = 160, align = .Left,   color = {0.85, 0.7, 0.7, 1.0}},
		{text = "45/80",    width = 80,  align = .Right,  color = COLOR_RED},
		{text = "BURNING",  width = 140, align = .Center, color = {1.0, 0.6, 0.2, 1.0}},
	}, MID_X, M_COL_ROW_1, SMALL_SIZE, COLOR_WHITE)
	slug.draw_text_columns(sctx, {
		{text = "Goblin",   width = 160, align = .Left,   color = {0.7, 0.85, 0.7, 1.0}},
		{text = "12/30",    width = 80,  align = .Right,  color = COLOR_RED},
		{text = "POISONED", width = 140, align = .Center, color = COLOR_GREEN},
	}, MID_X, M_COL_ROW_2, SMALL_SIZE, COLOR_WHITE)

	// Grid demo (each glyph centered in a fixed-size cell)
	slug.draw_text(sctx, "Grid:", MID_X, M_GRID_HEADER, SMALL_SIZE, COLOR_HEADER)
	slug.draw_text_grid(
		sctx,
		"#######\n#..@..#\n#.....#\n#######",
		MID_X, M_GRID, 18, 14, 22, COLOR_GREEN,
	)

	// Cached text — built once at init, drawn here every frame
	slug.draw_text(sctx, "Cached:", MID_X, M_CACHE_HEADER, SMALL_SIZE, COLOR_HEADER)
	slug.draw_cached(sctx, &state.cached_label)

	// Standalone SVG icons (drawn via draw_icon, in different colors)
	slug.draw_text(sctx, "SVG Icons:", MID_X, M_ICONS_HEADER, SMALL_SIZE, COLOR_HEADER)
	slug.draw_icon(sctx, ICON_SWORD,  MID_X + 20,  M_ICONS, ICON_SIZE, COLOR_YELLOW)
	slug.draw_icon(sctx, ICON_HEART,  MID_X + 90,  M_ICONS, ICON_SIZE, COLOR_RED)
	slug.draw_icon(sctx, ICON_SHIELD, MID_X + 160, M_ICONS, ICON_SIZE, COLOR_CYAN)
	slug.draw_icon(sctx, ICON_CIRCLE, MID_X + 230, M_ICONS, ICON_SIZE, COLOR_GREEN)

	// Inline icons inside rich text
	slug.draw_rich_text(
		sctx,
		"Slay the {icon:128:yellow} get a {icon:129:red}!",
		MID_X, M_RICH_ICONS, BODY_SIZE, COLOR_WHITE,
	)

	// Wave-path text (lives in this column to balance the right one)
	slug.draw_text_on_wave(
		sctx,
		"Riding a sine wave across the column",
		MID_X, M_WAVE,
		SMALL_SIZE,
		amplitude = 8.0,
		wavelength = 200.0,
		phase = t * 2.0,
		color = COLOR_CYAN,
	)
}

// ---- Right column: animated effects ----

draw_right_column :: proc(sctx: ^slug.Context, t: f32) {
	slug.draw_text(sctx, "Effects:", RIGHT_X, R_HEADER, SMALL_SIZE, COLOR_HEADER)

	slug.draw_text_rainbow(sctx, "Rainbow Text!", RIGHT_X, R_RAINBOW, BODY_SIZE, t)
	slug.draw_text_wobble(sctx, "Wobble!", RIGHT_X, R_WOBBLE, BODY_SIZE, t, color = COLOR_YELLOW)
	slug.draw_text_pulse(sctx, "Pulse!", RIGHT_X, R_PULSE, BODY_SIZE, COLOR_GREEN, t)
	slug.draw_text_shake(sctx, "Shake!!", RIGHT_X, R_SHAKE, BODY_SIZE, intensity = 2.5, time = t)

	// Typewriter — loops every 6 seconds so it's always visible
	loop := math.mod(t, 6.0)
	slug.draw_text_typewriter(
		sctx,
		"Typing one letter at a time...",
		RIGHT_X, R_TYPEWRITER, SMALL_SIZE, COLOR_WHITE, loop,
	)

	slug.draw_text_gradient(
		sctx, "Gradient Text", RIGHT_X, R_GRADIENT, BODY_SIZE,
		{0.2, 0.6, 1.0, 1.0}, {1.0, 0.3, 0.8, 1.0},
	)

	fade := (math.sin(t * 2.0) + 1.0) * 0.5
	slug.draw_text_fade(sctx, "Fade In / Out", RIGHT_X, R_FADE, BODY_SIZE, COLOR_WHITE, fade)

	// Rotated — spins around its center
	slug.draw_text_rotated(
		sctx, "Rotated!",
		RIGHT_X + 130, R_ROTATED,
		BODY_SIZE, math.sin(t) * 0.4, COLOR_CYAN,
	)

	// User-provided per-glyph transform (wave + hue cycle)
	wave_state := Wave_Hue_State{time = t}
	slug.draw_text_transformed(
		sctx, "Wave + Hue Shift",
		RIGHT_X, R_TRANSFORMED,
		BODY_SIZE, COLOR_WHITE,
		wave_hue_xform, &wave_state,
	)

	// Text on a circle
	slug.draw_text_on_circle(
		sctx,
		"Text on a circle  *  rotates  *  ",
		RIGHT_X + 130, R_CIRCLE,
		70, t * 0.5,
		BODY_SIZE, COLOR_YELLOW,
	)

	// Floating damage number — loops every 1.5s
	float_age := math.mod(t, 1.5)
	slug.draw_text_float(
		sctx, "-15",
		RIGHT_X + 130, R_FLOAT_DEMO,
		BODY_SIZE, COLOR_RED, float_age, duration = 1.5, rise_distance = 50,
	)
}

Wave_Hue_State :: struct {
	time: f32,
}

wave_hue_xform :: proc(
	char_idx: int,
	ch: rune,
	pen_x, y: f32,
	userdata: rawptr,
) -> slug.Glyph_Xform {
	whs := (^Wave_Hue_State)(userdata)
	phase := f32(char_idx) * 0.7
	bob := math.sin(whs.time * 4.0 + phase) * 7.0
	hue := math.mod(whs.time * 90.0 + f32(char_idx) * 35.0, 360.0)
	rgb := slug.hsv_to_rgb(hue, 0.85, 1.0)
	return slug.Glyph_Xform{offset = {0, -bob}, color = {rgb.x, rgb.y, rgb.z, 1.0}}
}
