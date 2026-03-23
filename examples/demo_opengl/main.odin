package main

// ===================================================
// odin-slug OpenGL Demo
//
// Standalone example showing GPU-accelerated Bezier text rendering
// using odin-slug with an OpenGL 3.3 backend. Uses GLFW for windowing.
// Showcases all library features: effects, wrapping, scrolling, cursor
// positioning, rich text, caching, alignment, shared font atlas, etc.
//
// Build:  odin build examples/demo_opengl -out:demo_opengl -collection:libs=.
// Run:    ./demo_opengl
//
// Prerequisites:
//   - Liberation fonts in examples/assets/fonts/
//   - OpenGL 3.3+ capable GPU
// ===================================================

import "core:fmt"
import "core:math"
import "core:time"

import gl "vendor:OpenGL"
import "vendor:glfw"

import slug "../../slug"
import slug_gl "../../slug/backends/opengl"

// --- Window ---

WINDOW_TITLE :: "odin-slug OpenGL Demo"
WINDOW_WIDTH :: 1600
WINDOW_HEIGHT :: 900

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

TITLE_SIZE :: f32(52)
BODY_SIZE :: f32(34)
SMALL_SIZE :: f32(24)
ICON_SIZE :: f32(44)

// =============================================================
// Position table — every layout coordinate in one named place.
// Edit here to reflow the demo without hunting through draw code.
// =============================================================

// ---- Left column (x=40..390): text feature demos ----

LEFT_X :: f32(40)

ROW_TITLE :: f32(60) // title, TITLE_SIZE, drop shadow
ROW_SUBTITLE :: f32(132) // subtitle, BODY_SIZE, outlined
ROW_RICH_TEXT :: f32(192) // rich text markup
ROW_UNICODE :: f32(238) // unicode characters
ROW_HIGHLIGHT :: f32(282) // "SELECTED" highlighted word, BODY_SIZE
ROW_STATUS :: f32(330) // status bg-tag row below SELECTED, SMALL_SIZE
ROW_SERIF :: f32(380) // multi-font serif line
ROW_CURSOR :: f32(426) // cursor demo text (size SMALL_SIZE)
ROW_CURSOR_HINT :: f32(454) // "[</>] or click  idx:N" (size 14)

FLOAT_X :: f32(310) // floating damage number: different x, same row as cursor
FLOAT_Y :: f32(426)

// Panel box (rainbow / wobble / cached), lower left
ROW_DECORATION :: f32(480) // underlined + strikethrough side by side

// Panel box (rainbow / wobble / cached), lower left
PANEL_X :: 40
PANEL_Y :: 516
PANEL_W :: 340
PANEL_H :: 210
PANEL_PAD :: f32(15) // inner margin from panel left edge to text

PANEL_RAINBOW_Y :: f32(PANEL_Y + 55) // 523
PANEL_WOBBLE_Y :: f32(PANEL_Y + 108) // 576
PANEL_CACHED_Y :: f32(PANEL_Y + 161) // 629

SERIF_LINE_Y :: f32(PANEL_Y + PANEL_H + 25) // 703

// ---- Center column (x=420..760): animated effects ----

ICONS_X :: f32(420) // first icon x
ICONS_Y :: f32(88) // icon baseline
ICON_STRIDE :: f32(56) // x step between icons

FX_X :: f32(420) // animated effect text left edge
FX_GRADIENT_Y :: f32(160)
FX_PULSE_Y :: f32(212)
FX_FADE_Y :: f32(264)
FX_XFORM_Y :: f32(320) // per-character transform callback demo
FX_SUBSUP_Y :: f32(378) // subscript / superscript inline demo

// Circle (orbital text + rotated text — no background shape in GL)
CIRCLE_CX :: f32(560)
CIRCLE_CY :: f32(490)
CIRCLE_R :: f32(90)

// ---- Right column (x=800..1240): structural demos ----

RIGHT_X :: f32(800)

ZOOM_Y :: f32(250) // pulsing-size "Zoom!" text — shifted down so ascenders don't hit fallback/justify

TRUNCATE_Y :: f32(315) // truncated text demo
TRUNCATE_MAX_W :: f32(240) // clip boundary in pixels

GRID_Y :: f32(380) // monospace grid demo

ALIGN_X :: f32(1050) // x anchor for all three alignment variants
ALIGN_Y0 :: f32(65) // left-aligned
ALIGN_Y1 :: f32(97) // centered
ALIGN_Y2 :: f32(129) // right-aligned

FALLBACK_Y :: f32(163) // fallback chain demo (sans + auto-serif for missing codepoints)

JUSTIFY_Y :: f32(196) // justified alignment demo
JUSTIFY_W :: f32(380) // column width — text expands to fill this exactly

WRAP_W :: f32(420)
WRAP_Y :: f32(425)
WRAP_PAD :: f32(8)

SCROLL_W :: f32(420)
SCROLL_Y :: f32(590)
SCROLL_H :: f32(110)

// GPU scissor clipping demo — right column, below scroll region
CLIP_LABEL_Y :: f32(720) // "GPU scissor:" label
CLIP_BOX_X :: RIGHT_X // aligns with right column
CLIP_BOX_Y :: f32(738) // top of the scissored viewport
CLIP_BOX_W :: f32(200) // intentionally narrow — text overflows without scissor
CLIP_BOX_H :: f32(44) // one line tall
CLIP_TEXT_Y :: CLIP_BOX_Y + 29 // text baseline centered inside box

SCALE_Y :: f32(820)

// Camera pan speed in pixels/second for WASD keys
CAMERA_SPEED :: f32(400.0)

// Zoom
ZOOM_WHEEL_STEP :: f32(0.1)
ZOOM_FIT_SCALE  :: f32(0.6)
ZOOM_MIN        :: f32(0.25)
ZOOM_MAX        :: f32(3.0)

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}

STYLE_UNDERLINE :: slug.Text_Style {
	size      = SMALL_SIZE,
	color     = COLOR_WHITE,
	underline = true,
}
STYLE_STRIKE :: slug.Text_Style {
	size          = SMALL_SIZE,
	color         = COLOR_YELLOW,
	strikethrough = true,
}
STYLE_BOTH :: slug.Text_Style {
	size          = SMALL_SIZE,
	color         = COLOR_CYAN,
	underline     = true,
	strikethrough = true,
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
	state := (^Wave_Hue_State)(userdata)
	phase := f32(char_idx) * 0.7
	bob := math.sin(state.time * 4.0 + phase) * 7.0
	hue := math.mod(state.time * 90.0 + f32(char_idx) * 35.0, 360.0)
	rgb := slug.hsv_to_rgb(hue, 0.85, 1.0)
	return slug.Glyph_Xform{offset = {0, -bob}, color = {rgb.x, rgb.y, rgb.z, 1.0}}
}

main :: proc() {
	// -----------------------------------------------
	// 1. Create window and OpenGL context
	// -----------------------------------------------

	if !glfw.Init() {
		fmt.eprintln("Failed to initialize GLFW")
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
	if window == nil {
		fmt.eprintln("Failed to create GLFW window")
		return
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	glfw.SwapInterval(1)

	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	// -----------------------------------------------
	// 2. Initialize slug renderer
	// -----------------------------------------------

	renderer := new(slug_gl.Renderer)
	if !slug_gl.init(renderer) {
		fmt.eprintln("Failed to initialize slug GL renderer")
		return
	}
	defer {
		slug_gl.destroy(renderer)
		free(renderer)
	}

	ctx := &renderer.ctx

	// -----------------------------------------------
	// 3. Load fonts + SVG icons into shared atlas
	// -----------------------------------------------

	{
		// Font 0: sans-serif + SVG icons
		font0, font0_ok := slug.font_load(FONT_SANS)
		if !font0_ok {
			fmt.eprintln("Failed to load font:", FONT_SANS)
			return
		}
		slug.font_load_ascii(&font0)
		slug.font_load_range(&font0, 160, 255) // Latin-1 Supplement
		slug.svg_load_into_font(&font0, ICON_SWORD, ICON_SWORD_PATH)
		slug.svg_load_into_font(&font0, ICON_HEART, ICON_HEART_PATH)
		slug.svg_load_into_font(&font0, ICON_SHIELD, ICON_SHIELD_PATH)
		slug.svg_load_into_font(&font0, ICON_CIRCLE, ICON_CIRCLE_PATH)
		slug.register_font(ctx, 0, font0)

		// Font 1: serif
		font1, font1_ok := slug.font_load(FONT_SERIF)
		if !font1_ok {
			fmt.eprintln("Failed to load font:", FONT_SERIF)
			return
		}
		slug.font_load_ascii(&font1)
		slug.font_load_range(&font1, 256, 383) // Latin Extended-A (Ş, ž, Ő, ę, ĺ, etc.)
		slug.register_font(ctx, 1, font1)

		slug.font_set_fallback(ctx, 0, 1)

		pack := slug.fonts_process_shared(ctx)
		defer slug.pack_result_destroy(&pack)
		slug_gl.upload_shared_textures(renderer, &pack)
	}

	// -----------------------------------------------
	// 4. Cache static text
	// -----------------------------------------------

	slug.begin(ctx)
	cached_label := slug.cache_text(
		ctx,
		"Crisp at any size (cached)",
		LEFT_X + PANEL_PAD,
		PANEL_CACHED_Y,
		SMALL_SIZE,
		COLOR_YELLOW,
	)
	defer slug.cache_destroy(&cached_label)

	// -----------------------------------------------
	// 5. Scroll region setup
	// -----------------------------------------------

	scroll_region := slug.Scroll_Region {
		x      = RIGHT_X,
		y      = SCROLL_Y,
		width  = SCROLL_W,
		height = SCROLL_H,
	}
	SCROLL_TEXT :: "The ancient tome reveals: Long ago, the Skeleton King ruled these lands with an iron fist. His army of undead warriors swept across the countryside, destroying everything in their path. Only the legendary heroes of the Silver Order stood against him. After a great battle that lasted seven days and seven nights, the heroes sealed the Skeleton King in a crypt beneath the mountains. But the seal grows weak..."

	// Cursor demo state
	cursor_text := "Click to position cursor"
	cursor_idx := 0
	prev_mouse_btn: i32 = glfw.RELEASE
	scroll_accum: f64 = 0

	glfw.SetScrollCallback(window, proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
		ptr := glfw.GetWindowUserPointer(window)
		if ptr != nil {
			(cast(^f64)ptr)^ += yoffset
		}
	})
	glfw.SetWindowUserPointer(window, &scroll_accum)

	// Camera pan state
	cam_x: f32 = 0
	cam_y: f32 = 0
	prev_mid_mouse: i32 = glfw.RELEASE
	prev_mid_mx: f64 = 0
	prev_mid_my: f64 = 0
	prev_tab_key: i32 = glfw.RELEASE

	// -----------------------------------------------
	// 6. Main render loop
	// -----------------------------------------------

	start_time := time.now()
	prev_elapsed: f32 = 0

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()

		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(window, true)
		}

		elapsed := f32(time.duration_seconds(time.since(start_time)))
		dt := elapsed - prev_elapsed
		prev_elapsed = elapsed
		fb_w, fb_h := glfw.GetFramebufferSize(window)
		mx, my := glfw.GetCursorPos(window)
		mouse_x := f32(mx)
		mouse_y := f32(my)

		// UI scale — Up/Down hold, Tab toggle, clamped
		if glfw.GetKey(window, glfw.KEY_UP) == glfw.PRESS   do slug.set_ui_scale(ctx, clamp(ctx.ui_scale + 0.01, ZOOM_MIN, ZOOM_MAX))
		if glfw.GetKey(window, glfw.KEY_DOWN) == glfw.PRESS do slug.set_ui_scale(ctx, clamp(ctx.ui_scale - 0.01, ZOOM_MIN, ZOOM_MAX))
		cur_tab := glfw.GetKey(window, glfw.KEY_TAB)
		if cur_tab == glfw.PRESS && prev_tab_key == glfw.RELEASE {
			slug.set_ui_scale(ctx, ZOOM_FIT_SCALE if ctx.ui_scale != ZOOM_FIT_SCALE else 1.0)
		}
		prev_tab_key = cur_tab

		// Camera pan — WASD keys (held)
		if glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS do cam_y -= CAMERA_SPEED * dt
		if glfw.GetKey(window, glfw.KEY_S) == glfw.PRESS do cam_y += CAMERA_SPEED * dt
		if glfw.GetKey(window, glfw.KEY_A) == glfw.PRESS do cam_x -= CAMERA_SPEED * dt
		if glfw.GetKey(window, glfw.KEY_D) == glfw.PRESS do cam_x += CAMERA_SPEED * dt

		// Camera pan — middle mouse drag
		cur_mid_mouse := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_MIDDLE)
		if cur_mid_mouse == glfw.PRESS && prev_mid_mouse == glfw.PRESS {
			cam_x += f32(mx - prev_mid_mx)
			cam_y += f32(my - prev_mid_my)
		}
		prev_mid_mouse = cur_mid_mouse
		prev_mid_mx = mx
		prev_mid_my = my

		// Camera reset
		if glfw.GetKey(window, glfw.KEY_R) == glfw.PRESS {
			cam_x = 0
			cam_y = 0
		}

		// Cursor keyboard movement
		if glfw.GetKey(window, glfw.KEY_LEFT) == glfw.PRESS && cursor_idx > 0 do cursor_idx -= 1
		if glfw.GetKey(window, glfw.KEY_RIGHT) == glfw.PRESS && cursor_idx < len(cursor_text) do cursor_idx += 1

		// Click-to-position cursor
		current_mouse_btn := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT)
		if current_mouse_btn == glfw.PRESS && prev_mouse_btn == glfw.RELEASE {
			cursor_font := slug.active_font(ctx)
			if idx, hit := slug.text_hit_test(
				cursor_font,
				cursor_text,
				LEFT_X,
				ROW_CURSOR,
				SMALL_SIZE,
				mouse_x - cam_x,
				mouse_y - cam_y,
			); hit {
				cursor_idx = idx
			}
		}
		prev_mouse_btn = current_mouse_btn

		// Scroll region: mouse wheel scrolls text when hovering, else zooms canvas
		scroll_content_h := slug.measure_text_wrapped(
			ctx,
			SCROLL_TEXT,
			SMALL_SIZE,
			scroll_region.width,
		)
		if scroll_accum != 0 {
			if mouse_x >= scroll_region.x &&
			   mouse_x <= scroll_region.x + scroll_region.width &&
			   mouse_y >= scroll_region.y &&
			   mouse_y <= scroll_region.y + scroll_region.height {
				slug.scroll_by(&scroll_region, f32(-scroll_accum) * 20.0, scroll_content_h)
			} else {
				slug.set_ui_scale(ctx, clamp(ctx.ui_scale + f32(scroll_accum) * ZOOM_WHEEL_STEP, ZOOM_MIN, ZOOM_MAX))
			}
			scroll_accum = 0
		}

		// --- Render ---
		gl.Viewport(0, 0, fb_w, fb_h)
		gl.ClearColor(0.08, 0.08, 0.12, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		slug.begin(ctx)
		slug.set_camera(ctx, cam_x, cam_y)

		// ---- Left column ----

		// Panel background rect (behind rainbow / wobble / cached text)
		slug.draw_rect(
			ctx,
			f32(PANEL_X),
			f32(PANEL_Y),
			f32(PANEL_W),
			f32(PANEL_H),
			{0.16, 0.16, 0.24, 1.0},
		)

		// Title with drop shadow
		slug.draw_text_shadow(
			ctx,
			"Slug + OpenGL",
			LEFT_X,
			ROW_TITLE,
			slug.scaled_size(ctx, TITLE_SIZE),
			COLOR_WHITE,
			shadow_offset = 2.0,
		)

		// Subtitle with outline
		slug.draw_text_outlined(
			ctx,
			"GPU Bezier text — OpenGL 3.3 backend.",
			LEFT_X,
			ROW_SUBTITLE,
			slug.scaled_size(ctx, BODY_SIZE),
			COLOR_CYAN,
			outline_thickness = 2.5,
			outline_color = {0.8, 0.2, 0.8, 1.0},
		)

		// Rich text markup
		slug.draw_rich_text(
			ctx,
			"You deal {red:15} dmg with {icon:128:yellow}{yellow:Golden Sword}!",
			LEFT_X,
			ROW_RICH_TEXT,
			BODY_SIZE,
			COLOR_WHITE,
		)

		// Unicode characters (Latin-1 Supplement)
		slug.draw_text(
			ctx,
			"Héros: épée, château, naïve, über, señor",
			LEFT_X,
			ROW_UNICODE,
			SMALL_SIZE,
			{0.7, 0.7, 0.9, 1.0},
		)

		// Highlighted text + {bg:} status tags
		slug.draw_text_highlighted(
			ctx,
			"SELECTED",
			LEFT_X,
			ROW_HIGHLIGHT,
			BODY_SIZE,
			slug.BLACK,
			{0.3, 0.6, 1.0, 1.0},
		)
		slug.draw_rich_text(
			ctx,
			"Status: {bg:red:POISONED}  {bg:green:HASTE}  {bg:#884400:BURNING}",
			LEFT_X,
			ROW_STATUS,
			SMALL_SIZE,
			COLOR_WHITE,
		)

		// Multi-font: switch to serif for one line
		slug.use_font(ctx, 1)
		slug.draw_text(
			ctx,
			"This line uses Liberation Serif (font slot 1)",
			LEFT_X,
			ROW_SERIF,
			SMALL_SIZE,
			{0.9, 0.8, 0.6, 1.0},
		)
		slug.use_font(ctx, 0)

		// Text_Style demo: underline, strikethrough, and both simultaneously
		slug.draw_text_styled(ctx, "Underlined", LEFT_X, ROW_DECORATION, STYLE_UNDERLINE)
		slug.draw_text_styled(ctx, "Struck-out", LEFT_X + 158, ROW_DECORATION, STYLE_STRIKE)
		slug.draw_text_styled(ctx, "Both", LEFT_X + 316, ROW_DECORATION, STYLE_BOTH)

		// Cursor positioning demo
		font := slug.active_font(ctx)
		slug.draw_text(ctx, cursor_text, LEFT_X, ROW_CURSOR, SMALL_SIZE, {0.7, 0.9, 0.7, 1.0})
		cursor_px := slug.cursor_x_from_index(font, cursor_text, SMALL_SIZE, cursor_idx)
		if int(elapsed * 2) % 2 == 0 {
			slug.draw_text(
				ctx,
				"|",
				LEFT_X + cursor_px - 2,
				ROW_CURSOR,
				SMALL_SIZE,
				{0.8, 1.0, 0.8, 1.0},
			)
		}
		slug.draw_text(
			ctx,
			fmt.tprintf("[</>] or click  idx:%d", cursor_idx),
			LEFT_X,
			ROW_CURSOR_HINT,
			14,
			{0.5, 0.5, 0.5, 1.0},
		)

		// Floating damage number (loops every 1.5s)
		float_age := math.mod(elapsed, 1.5)
		slug.draw_text_float(
			ctx,
			"-15",
			FLOAT_X,
			FLOAT_Y,
			BODY_SIZE,
			{1.0, 0.3, 0.3, 1.0},
			float_age,
			duration = 1.5,
		)

		// Panel contents: rainbow, wobble, cached
		slug.draw_text_rainbow(
			ctx,
			"Rainbow on a panel!",
			LEFT_X + PANEL_PAD,
			PANEL_RAINBOW_Y,
			BODY_SIZE,
			time = elapsed,
		)
		slug.draw_text_wobble(
			ctx,
			"Wobbly!",
			LEFT_X + PANEL_PAD,
			PANEL_WOBBLE_Y,
			BODY_SIZE,
			time = elapsed,
			amplitude = 5.0,
		)
		slug.draw_cached(ctx, &cached_label)

		// Serif font demo line (below panel)
		slug.use_font(ctx, 1)
		slug.draw_text(
			ctx,
			"Multi-font: Liberation Serif (slot 1)",
			LEFT_X,
			SERIF_LINE_Y,
			SMALL_SIZE,
			{0.9, 0.8, 0.6, 1.0},
		)
		slug.use_font(ctx, 0)

		// ---- Center column ----

		// SVG icons
		slug.draw_icon(ctx, ICON_SWORD, ICONS_X, ICONS_Y, ICON_SIZE, COLOR_YELLOW)
		slug.draw_icon(
			ctx,
			ICON_HEART,
			ICONS_X + ICON_STRIDE,
			ICONS_Y,
			ICON_SIZE,
			{1.0, 0.3, 0.3, 1.0},
		)
		slug.draw_icon(
			ctx,
			ICON_SHIELD,
			ICONS_X + ICON_STRIDE * 2,
			ICONS_Y,
			ICON_SIZE,
			{0.3, 0.8, 0.4, 1.0},
		)
		slug.draw_icon(
			ctx,
			ICON_CIRCLE,
			ICONS_X + ICON_STRIDE * 3,
			ICONS_Y,
			ICON_SIZE,
			{0.5, 0.5, 1.0, 1.0},
		)
		slug.draw_text(
			ctx,
			"SVG icons!",
			ICONS_X + ICON_STRIDE * 4 + 2,
			ICONS_Y - 10,
			SMALL_SIZE,
			COLOR_WHITE,
		)

		// Gradient, pulse, fade effects
		slug.draw_text_gradient(
			ctx,
			"Gradient text!",
			FX_X,
			FX_GRADIENT_Y,
			BODY_SIZE,
			{1.0, 0.8, 0.2, 1.0},
			{1.0, 0.2, 0.4, 1.0},
		)
		slug.draw_text_pulse(
			ctx,
			"Pulsing!",
			FX_X,
			FX_PULSE_Y,
			BODY_SIZE,
			COLOR_CYAN,
			time = elapsed,
		)
		fade_alpha := (math.sin(elapsed * 2.0) + 1.0) * 0.5
		slug.draw_text_fade(
			ctx,
			"Fading in and out...",
			FX_X,
			FX_FADE_Y,
			SMALL_SIZE,
			COLOR_WHITE,
			fade_alpha,
		)

		wave_state := Wave_Hue_State{elapsed}
		slug.draw_text_transformed(
			ctx,
			"Custom callback!",
			FX_X,
			FX_XFORM_Y,
			BODY_SIZE,
			COLOR_WHITE,
			wave_hue_xform,
			&wave_state,
		)

		// Subscript / superscript inline demo: "H₂O  x²"
		{
			font := slug.active_font(ctx)
			px := FX_X

			hw, _ := slug.measure_text(font, "H", SMALL_SIZE)
			slug.draw_text(ctx, "H", px, FX_SUBSUP_Y, SMALL_SIZE, COLOR_WHITE)
			px += hw

			sub2w, _ := slug.measure_text(font, "2", SMALL_SIZE * slug.SUB_SCALE)
			slug.draw_text_sub(ctx, "2", px, FX_SUBSUP_Y, SMALL_SIZE, {0.5, 0.85, 1.0, 1.0})
			px += sub2w

			ow, _ := slug.measure_text(font, "O", SMALL_SIZE)
			slug.draw_text(ctx, "O", px, FX_SUBSUP_Y, SMALL_SIZE, COLOR_WHITE)
			px += ow + 35

			xw, _ := slug.measure_text(font, "x", SMALL_SIZE)
			slug.draw_text(ctx, "x", px, FX_SUBSUP_Y, SMALL_SIZE, COLOR_WHITE)
			px += xw

			slug.draw_text_super(ctx, "2", px, FX_SUBSUP_Y, SMALL_SIZE, {1.0, 0.8, 0.35, 1.0})
		}

		// Circular orbit + rotated text (no background circle in GL demo)
		slug.draw_text_on_circle(
			ctx,
			"  text orbiting a circle  ",
			CIRCLE_CX,
			CIRCLE_CY,
			CIRCLE_R + 20,
			start_angle = -elapsed * 0.4,
			font_size = SMALL_SIZE,
			color = {0.8, 0.5, 1.0, 1.0},
		)
		slug.draw_text_rotated(
			ctx,
			"Rotated",
			CIRCLE_CX,
			CIRCLE_CY,
			BODY_SIZE,
			elapsed * 0.6,
			COLOR_YELLOW,
		)

		// ---- Right column ----

		// Pulsing size text
		pulse_size := 60.0 + math.sin(elapsed * 1.5) * 20.0
		slug.draw_text(ctx, "Zoom!", RIGHT_X + 10, ZOOM_Y, f32(pulse_size), {1.0, 0.5, 0.3, 1.0})

		// Truncated text: long string clipped at TRUNCATE_MAX_W with "..."
		slug.draw_text(ctx, "clip:", RIGHT_X + 10, TRUNCATE_Y - 18, 12, {0.4, 0.4, 0.5, 1.0})
		slug.draw_text_truncated(
			ctx,
			"This long name gets clipped with an ellipsis",
			RIGHT_X + 10,
			TRUNCATE_Y,
			SMALL_SIZE,
			TRUNCATE_MAX_W,
			COLOR_WHITE,
		)

		// Monospace grid
		cell_w := slug.mono_width(font, SMALL_SIZE)
		grid_text := "GRID"
		for ch, i in grid_text {
			ch_w := slug.char_advance(font, ch, SMALL_SIZE)
			char_x := RIGHT_X + f32(i) * cell_w + (cell_w - ch_w) * 0.5
			slug.draw_text(ctx, grid_text[i:][:1], char_x, GRID_Y, SMALL_SIZE, COLOR_CYAN)
		}
		slug.draw_text(
			ctx,
			fmt.tprintf("cell: %.1fpx", cell_w),
			RIGHT_X,
			GRID_Y + 25,
			SMALL_SIZE,
			{0.5, 0.5, 0.5, 1.0},
		)

		// Alignment demo
		slug.draw_text(ctx, "Left-aligned", ALIGN_X, ALIGN_Y0, SMALL_SIZE, {0.8, 0.6, 0.6, 1.0})
		slug.draw_text_centered(
			ctx,
			"Centered",
			ALIGN_X,
			ALIGN_Y1,
			SMALL_SIZE,
			{0.6, 0.6, 0.8, 1.0},
		)
		slug.draw_text_right(
			ctx,
			"Right-aligned",
			ALIGN_X,
			ALIGN_Y2,
			SMALL_SIZE,
			{0.6, 0.8, 0.6, 1.0},
		)

		// Fallback chain: font 0 lacks Latin Extended-A; font 1 (serif) covers it.
		slug.draw_text(
			ctx,
			"Fallback: Ş ž Ő ę ĺ (font 0 → serif)",
			RIGHT_X,
			FALLBACK_Y,
			SMALL_SIZE,
			{0.7, 0.9, 0.7, 1.0},
		)

		// Justified alignment
		slug.draw_text_justified(
			ctx,
			"Word justification fills the column width exactly.",
			RIGHT_X,
			JUSTIFY_Y,
			SMALL_SIZE,
			JUSTIFY_W,
			{0.9, 0.8, 0.6, 1.0},
		)

		// Word wrap
		WRAP_TEXT :: "The ancient scroll reads: You have defeated the Skeleton King and earned 250 gold. Your sword glows with newfound power."
		slug.draw_text_wrapped(
			ctx,
			WRAP_TEXT,
			RIGHT_X + WRAP_PAD,
			WRAP_Y + WRAP_PAD,
			SMALL_SIZE,
			WRAP_W - WRAP_PAD * 2,
			COLOR_WHITE,
		)

		// Scroll region background + content
		slug.draw_rect(
			ctx,
			scroll_region.x,
			scroll_region.y,
			scroll_region.width,
			scroll_region.height,
			{0.12, 0.12, 0.20, 1.0},
		)
		slug.draw_text_scrolled(ctx, SCROLL_TEXT, &scroll_region, SMALL_SIZE, {0.8, 0.8, 0.9, 1.0})
		slug.draw_text(
			ctx,
			"Scroll me! [wheel]",
			scroll_region.x,
			scroll_region.y - 18,
			14,
			{0.5, 0.5, 0.7, 1.0},
		)

		// Scissor demo: draw_rect border + label unclipped in this pass
		slug.draw_rect(
			ctx,
			CLIP_BOX_X,
			CLIP_BOX_Y,
			CLIP_BOX_W,
			CLIP_BOX_H,
			{0.08, 0.14, 0.22, 1.0},
		)
		slug.draw_text(ctx, "GPU scissor:", CLIP_BOX_X, CLIP_LABEL_Y, 13, {0.5, 0.5, 0.7, 1.0})

		// Scale indicator
		slug.draw_text(
			ctx,
			fmt.tprintf("Scale: %.2fx [Up/Down/Wheel/Tab]  Cam: %.0f,%.0f [WASD/MMB  R=reset]", ctx.ui_scale, cam_x, cam_y),
			10,
			SCALE_Y,
			16,
			{0.5, 0.5, 0.5, 1.0},
		)

		slug.end(ctx)
		slug_gl.flush(renderer, fb_w, fb_h) // pass 1: all main content, no scissor

		// Pass 2: clipped panel text — scissor follows canvas pan
		slug.begin(ctx)
		slug.use_font(ctx, 0)
		slug.set_camera(ctx, cam_x, cam_y)
		slug.draw_text(
			ctx,
			"GPU-clipped panel text overflows →",
			CLIP_BOX_X + 5,
			CLIP_TEXT_Y,
			SMALL_SIZE,
			COLOR_WHITE,
		)
		slug.end(ctx)
		slug_gl.flush(
			renderer,
			fb_w,
			fb_h,
			scissor = slug.Scissor_Rect {
				x = CLIP_BOX_X + cam_x,
				y = CLIP_BOX_Y + cam_y,
				w = CLIP_BOX_W,
				h = CLIP_BOX_H,
			},
		)

		glfw.SwapBuffers(window)
	}

	fmt.println("Demo exiting.")
}
