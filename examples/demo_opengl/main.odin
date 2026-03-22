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

// --- Window constants ---

WINDOW_TITLE :: "odin-slug OpenGL Demo"
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

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

// --- Layout constants ---

TITLE_SIZE :: 42.0
BODY_SIZE :: 28.0
SMALL_SIZE :: 20.0
ICON_SIZE :: 36.0
LEFT_MARGIN :: 40.0
TOP_START :: 60.0
LINE_SPACING :: 50.0

// --- UI element positions ---

BOX_X :: 40
BOX_Y :: 420
BOX_WIDTH :: 300
BOX_HEIGHT :: 200

CIRCLE_X :: 640.0
CIRCLE_Y :: 520.0
CIRCLE_RADIUS :: 80.0

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}

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
		slug.font_load_range(&font0, 160, 255)
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
		slug.register_font(ctx, 1, font1)

		// Pack all fonts into shared atlas
		pack := slug.fonts_process_shared(ctx)
		defer slug.pack_result_destroy(&pack)
		slug_gl.upload_shared_textures(renderer, &pack)
	}

	// -----------------------------------------------
	// 4. Cache static text
	// -----------------------------------------------

	slug.begin(ctx)
	cached_label := slug.cache_text(ctx, "Crisp at any size (cached)", f32(BOX_X + 15), f32(BOX_Y + 155), SMALL_SIZE, COLOR_YELLOW)
	defer slug.cache_destroy(&cached_label)

	// -----------------------------------------------
	// 5. Scroll region setup
	// -----------------------------------------------

	scroll_region := slug.Scroll_Region {
		x      = 800,
		y      = 540,
		width  = 420,
		height = 100,
	}
	SCROLL_TEXT :: "The ancient tome reveals: Long ago, the Skeleton King ruled these lands with an iron fist. His army of undead warriors swept across the countryside, destroying everything in their path. Only the legendary heroes of the Silver Order stood against him. After a great battle that lasted seven days and seven nights, the heroes sealed the Skeleton King in a crypt beneath the mountains. But the seal grows weak..."

	// Cursor demo state
	cursor_text := "Click to position cursor"
	cursor_idx := 0

	// Mouse state tracking (GLFW doesn't have Raylib's simple API)
	prev_mouse_btn: i32 = glfw.RELEASE
	scroll_accum: f64 = 0

	// Set scroll callback
	glfw.SetScrollCallback(window, proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
		// Store in window user pointer
		ptr := glfw.GetWindowUserPointer(window)
		if ptr != nil {
			(cast(^f64)ptr)^ += yoffset
		}
	})
	glfw.SetWindowUserPointer(window, &scroll_accum)

	// -----------------------------------------------
	// 6. Main render loop
	// -----------------------------------------------

	start_time := time.now()

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()

		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(window, true)
		}

		elapsed := f32(time.duration_seconds(time.since(start_time)))
		fb_w, fb_h := glfw.GetFramebufferSize(window)

		// UI scale with Up/Down
		if glfw.GetKey(window, glfw.KEY_UP) == glfw.PRESS {
			slug.set_ui_scale(ctx, ctx.ui_scale + 0.01)
		}
		if glfw.GetKey(window, glfw.KEY_DOWN) == glfw.PRESS {
			slug.set_ui_scale(ctx, ctx.ui_scale - 0.01)
		}

		// Mouse state
		mx, my := glfw.GetCursorPos(window)
		mouse_x := f32(mx)
		mouse_y := f32(my)

		// Scroll region: mouse wheel when hovering
		scroll_content_h := slug.measure_text_wrapped(ctx, SCROLL_TEXT, SMALL_SIZE, scroll_region.width)
		if mouse_x >= scroll_region.x && mouse_x <= scroll_region.x + scroll_region.width &&
		   mouse_y >= scroll_region.y && mouse_y <= scroll_region.y + scroll_region.height {
			if scroll_accum != 0 {
				slug.scroll_by(&scroll_region, f32(-scroll_accum) * 20.0, scroll_content_h)
				scroll_accum = 0
			}
		} else {
			scroll_accum = 0
		}

		// Cursor positioning: Left/Right keys
		if glfw.GetKey(window, glfw.KEY_LEFT) == glfw.PRESS && cursor_idx > 0 do cursor_idx -= 1
		if glfw.GetKey(window, glfw.KEY_RIGHT) == glfw.PRESS && cursor_idx < len(cursor_text) do cursor_idx += 1

		// Click-to-position cursor
		CURSOR_X :: f32(40)
		CURSOR_Y :: f32(290)
		CURSOR_HIT_HEIGHT :: f32(24)
		current_mouse_btn := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT)
		if current_mouse_btn == glfw.PRESS && prev_mouse_btn == glfw.RELEASE {
			if mouse_y >= CURSOR_Y - CURSOR_HIT_HEIGHT && mouse_y <= CURSOR_Y + 4 &&
			   mouse_x >= CURSOR_X {
				cursor_font := slug.active_font(ctx)
				cursor_idx = slug.index_from_x(cursor_font, cursor_text, SMALL_SIZE, mouse_x - CURSOR_X)
			}
		}
		prev_mouse_btn = current_mouse_btn

		// --- Render ---
		gl.Viewport(0, 0, fb_w, fb_h)
		gl.ClearColor(0.08, 0.08, 0.12, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		slug.begin(ctx)

		// -- Title with drop shadow --
		slug.draw_text_shadow(
			ctx,
			"Slug + OpenGL",
			LEFT_MARGIN,
			TOP_START,
			slug.scaled_size(ctx, TITLE_SIZE),
			COLOR_WHITE,
			shadow_offset = 2.0,
		)

		// -- Description with outline --
		slug.draw_text_outlined(
			ctx,
			"GPU Bezier text — OpenGL 3.3 backend.",
			LEFT_MARGIN,
			TOP_START + LINE_SPACING,
			slug.scaled_size(ctx, BODY_SIZE),
			COLOR_CYAN,
			outline_thickness = 2.5,
			outline_color = {0.8, 0.2, 0.8, 1.0},
		)

		// -- Rainbow text --
		slug.draw_text_rainbow(
			ctx,
			"Rainbow on a panel!",
			f32(BOX_X + 15),
			f32(BOX_Y + 45),
			BODY_SIZE,
			time = elapsed,
		)

		// -- Wobble text --
		slug.draw_text_wobble(
			ctx,
			"Wobbly!",
			f32(BOX_X + 15),
			f32(BOX_Y + 100),
			BODY_SIZE,
			time = elapsed,
			amplitude = 5.0,
		)

		// -- Cached static text --
		slug.draw_cached(ctx, &cached_label)

		// -- SVG icons --
		slug.draw_icon(ctx, ICON_SWORD, 420, 460, ICON_SIZE, COLOR_YELLOW)
		slug.draw_icon(ctx, ICON_HEART, 470, 460, ICON_SIZE, {1.0, 0.3, 0.3, 1.0})
		slug.draw_icon(ctx, ICON_SHIELD, 520, 460, ICON_SIZE, {0.3, 0.8, 0.4, 1.0})
		slug.draw_icon(ctx, ICON_CIRCLE, 570, 460, ICON_SIZE, {0.5, 0.5, 1.0, 1.0})
		slug.draw_text(ctx, "SVG icons!", 620, 448, SMALL_SIZE, COLOR_WHITE)

		// -- Circular text --
		slug.draw_text_on_circle(
			ctx,
			"  text orbiting a circle  ",
			CIRCLE_X,
			CIRCLE_Y,
			CIRCLE_RADIUS + 20,
			start_angle = -elapsed * 0.4,
			font_size = SMALL_SIZE,
			color = {0.8, 0.5, 1.0, 1.0},
		)

		// -- Rotated text --
		slug.draw_text_rotated(
			ctx,
			"Rotated",
			CIRCLE_X,
			CIRCLE_Y,
			BODY_SIZE,
			elapsed * 0.6,
			COLOR_YELLOW,
		)

		// -- Pulsing size text --
		pulse_size := 60.0 + math.sin(elapsed * 1.5) * 20.0
		slug.draw_text(ctx, "Zoom!", 800, 200, f32(pulse_size), {1.0, 0.5, 0.3, 1.0})

		// -- Rich text markup --
		font := slug.active_font(ctx)
		seg_y: f32 = 350
		slug.draw_rich_text(ctx, "You deal {red:15} damage with {yellow:Golden Sword}!", LEFT_MARGIN, seg_y, BODY_SIZE, COLOR_WHITE)

		// -- Background highlights / draw_rect demo --
		highlight_y := seg_y + LINE_SPACING * 2
		slug.draw_text_highlighted(ctx, "SELECTED", LEFT_MARGIN, highlight_y, BODY_SIZE, slug.BLACK, {0.3, 0.6, 1.0, 1.0})
		slug.draw_rich_text(ctx, "  Status: {bg:red:POISONED}  {bg:green:HASTE}  {bg:#884400:BURNING}", LEFT_MARGIN + 130, highlight_y, BODY_SIZE, COLOR_WHITE)

		// -- Unicode --
		slug.draw_text(ctx, "Héros: épée, château, naïve, über, señor", LEFT_MARGIN, seg_y + LINE_SPACING, SMALL_SIZE, {0.7, 0.7, 0.9, 1.0})

		// -- Monospace grid --
		cell_w := slug.mono_width(font, SMALL_SIZE)
		grid_x: f32 = 800
		grid_y: f32 = 350
		grid_text := "GRID"
		for ch, i in grid_text {
			ch_w := slug.char_advance(font, ch, SMALL_SIZE)
			char_x := grid_x + f32(i) * cell_w + (cell_w - ch_w) * 0.5
			slug.draw_text(ctx, grid_text[i:][:1], char_x, grid_y, SMALL_SIZE, COLOR_CYAN)
		}
		slug.draw_text(ctx, fmt.tprintf("cell: %.1fpx", cell_w), grid_x, grid_y + 25, SMALL_SIZE, {0.5, 0.5, 0.5, 1.0})

		// -- Floating damage number --
		float_age := math.mod(elapsed, 1.5)
		slug.draw_text_float(ctx, "-15", 350, 350, BODY_SIZE, {1.0, 0.3, 0.3, 1.0}, float_age, duration = 1.5)

		// -- Gradient, pulse, fade --
		slug.draw_text_gradient(ctx, "Gradient text!", 420, 520, BODY_SIZE, {1.0, 0.8, 0.2, 1.0}, {1.0, 0.2, 0.4, 1.0})
		slug.draw_text_pulse(ctx, "Pulsing!", 420, 570, BODY_SIZE, COLOR_CYAN, time = elapsed)
		fade_alpha := (math.sin(elapsed * 2.0) + 1.0) * 0.5
		slug.draw_text_fade(ctx, "Fading in and out...", 420, 620, SMALL_SIZE, COLOR_WHITE, fade_alpha)

		// -- Alignment demo --
		ALIGN_X :: f32(1050)
		slug.draw_text(ctx, "Left-aligned", ALIGN_X, 245, SMALL_SIZE, {0.8, 0.6, 0.6, 1.0})
		slug.draw_text_centered(ctx, "Centered", ALIGN_X, 270, SMALL_SIZE, {0.6, 0.6, 0.8, 1.0})
		slug.draw_text_right(ctx, "Right-aligned", ALIGN_X, 295, SMALL_SIZE, {0.6, 0.8, 0.6, 1.0})

		// -- Word wrap --
		WRAP_TEXT :: "The ancient scroll reads: You have defeated the Skeleton King and earned 250 gold. Your sword glows with newfound power."
		WRAP_X :: f32(800)
		WRAP_Y :: f32(420)
		WRAP_WIDTH :: f32(420)
		WRAP_PAD :: f32(8)
		slug.draw_text_wrapped(ctx, WRAP_TEXT, WRAP_X + WRAP_PAD, WRAP_Y + WRAP_PAD, SMALL_SIZE, WRAP_WIDTH - WRAP_PAD * 2, COLOR_WHITE)

		// -- Scrollable text --
		slug.draw_text_scrolled(ctx, SCROLL_TEXT, &scroll_region, SMALL_SIZE, {0.8, 0.8, 0.9, 1.0})
		slug.draw_text(ctx, "Scroll me! [wheel]", scroll_region.x, scroll_region.y - 18, 14, {0.5, 0.5, 0.7, 1.0})

		// -- Cursor positioning --
		slug.draw_text(ctx, cursor_text, CURSOR_X, CURSOR_Y, SMALL_SIZE, {0.7, 0.9, 0.7, 1.0})
		cursor_px := slug.cursor_x_from_index(font, cursor_text, SMALL_SIZE, cursor_idx)
		if int(elapsed * 2) % 2 == 0 {
			slug.draw_text(ctx, "|", CURSOR_X + cursor_px - 2, CURSOR_Y, SMALL_SIZE, {0.8, 1.0, 0.8, 1.0})
		}
		slug.draw_text(ctx, fmt.tprintf("[</>] or click  idx:%d", cursor_idx), CURSOR_X, CURSOR_Y + 20, 14, {0.5, 0.5, 0.5, 1.0})

		// -- Multi-font: serif --
		slug.use_font(ctx, 1)
		slug.draw_text(ctx, "This line uses Liberation Serif (font slot 1)", LEFT_MARGIN, f32(BOX_Y + BOX_HEIGHT + 30), SMALL_SIZE, {0.9, 0.8, 0.6, 1.0})

		slug.end(ctx)
		slug_gl.flush(renderer, fb_w, fb_h)

		// Scale indicator (drawn as slug text in a second pass)
		slug.begin(ctx)
		slug.use_font(ctx, 0)
		slug.draw_text(ctx, fmt.tprintf("Scale: %.2fx [Up/Down]", ctx.ui_scale), 10, f32(fb_h) - 25, 16, {0.5, 0.5, 0.5, 1.0})
		slug.end(ctx)
		slug_gl.flush(renderer, fb_w, fb_h)

		glfw.SwapBuffers(window)
	}

	fmt.println("Demo exiting.")
}
