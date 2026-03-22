package main

// ===================================================
// odin-slug + Raylib Integration Demo
//
// Shows how to render GPU-accelerated Bezier text alongside normal
// Raylib drawing using the slug Raylib backend. The backend handles
// GL function pointer loading and Raylib batch flushing automatically.
//
// Build:  odin build examples/demo_raylib -out:demo_raylib
// Run:    ./demo_raylib
//
// Prerequisites:
//   - Liberation fonts in examples/assets/fonts/
//   - Raylib vendor library (ships with Odin)
// ===================================================

import "core:fmt"
import "core:math"

import rl "vendor:raylib"

import slug "../../slug"
import slug_rl "../../slug/backends/raylib"

// --- Window ---

WINDOW_TITLE  :: "odin-slug + Raylib"
WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720
TARGET_FPS    :: 60

// --- Font paths ---

FONT_PATH      :: "examples/assets/fonts/LiberationSans-Regular.ttf"
FONT_SERIF_PATH :: "examples/assets/fonts/LiberationSerif-Regular.ttf"

// --- SVG icon glyph slots ---

ICON_SWORD  :: 128
ICON_HEART  :: 129
ICON_SHIELD :: 130
ICON_CIRCLE :: 131

ICON_SWORD_PATH  :: "examples/assets/icons/sword.svg"
ICON_HEART_PATH  :: "examples/assets/icons/heart.svg"
ICON_SHIELD_PATH :: "examples/assets/icons/shield.svg"
ICON_CIRCLE_PATH :: "examples/assets/icons/circle.svg"

// --- Text sizes ---

TITLE_SIZE :: f32(42)
BODY_SIZE  :: f32(28)
SMALL_SIZE :: f32(20)
ICON_SIZE  :: f32(36)

// =============================================================
// Position table — every layout coordinate in one named place.
// Edit here to reflow the demo without hunting through draw code.
// =============================================================

// ---- Left column (x=40..390): text feature demos ----

LEFT_X :: f32(40)

ROW_TITLE       :: f32(60)   // title, TITLE_SIZE, drop shadow
ROW_SUBTITLE    :: f32(115)  // subtitle, BODY_SIZE, outlined
ROW_RICH_TEXT   :: f32(175)  // rich text markup
ROW_UNICODE     :: f32(218)  // unicode characters
ROW_HIGHLIGHT   :: f32(263)  // highlighted text + status row
ROW_SERIF       :: f32(310)  // multi-font serif line
ROW_CURSOR      :: f32(355)  // cursor demo text (size SMALL_SIZE)
ROW_CURSOR_HINT :: f32(378)  // "[</>] or click  idx:N" (size 14)

FLOAT_X :: f32(310)          // floating damage number: different x, same row as cursor
FLOAT_Y :: f32(355)

// Panel box (rainbow / wobble / cached), lower left
PANEL_X   :: 40
PANEL_Y   :: 408
PANEL_W   :: 310
PANEL_H   :: 190
PANEL_PAD :: f32(15)  // inner margin from panel left edge to text

PANEL_RAINBOW_Y :: f32(PANEL_Y + 50)   // 458
PANEL_WOBBLE_Y  :: f32(PANEL_Y + 95)   // 503
PANEL_CACHED_Y  :: f32(PANEL_Y + 140)  // 548

SERIF_LINE_Y :: f32(PANEL_Y + PANEL_H + 25)  // 623

// ---- Center column (x=420..760): animated effects ----

ICONS_X     :: f32(420)  // first icon x
ICONS_Y     :: f32(80)   // icon baseline
ICON_STRIDE :: f32(50)   // x step between icons

FX_X          :: f32(420)  // animated effect text left edge
FX_GRADIENT_Y :: f32(145)
FX_PULSE_Y    :: f32(193)
FX_FADE_Y     :: f32(241)

// Circle (background shape + orbital text + rotated text)
CIRCLE_CX :: 560   // untyped: used as i32 for rl.DrawCircle, f32 for slug
CIRCLE_CY :: 460
CIRCLE_R  :: 80

// ---- Right column (x=800..1240): structural demos ----

RIGHT_X :: f32(800)

ZOOM_Y :: f32(200)  // pulsing-size "Zoom!" text

TRUNCATE_Y     :: f32(255)  // truncated text demo
TRUNCATE_MAX_W :: f32(240)  // clip boundary in pixels

GRID_Y :: f32(310)  // monospace grid demo

ALIGN_X  :: f32(1050)  // x anchor for all three alignment variants
ALIGN_Y0 :: f32(62)    // left-aligned
ALIGN_Y1 :: f32(87)    // centered
ALIGN_Y2 :: f32(112)   // right-aligned

WRAP_W   :: f32(420)
WRAP_Y   :: f32(365)
WRAP_PAD :: f32(8)

SCROLL_W :: f32(420)
SCROLL_Y :: f32(510)
SCROLL_H :: f32(100)

SCALE_Y :: f32(700)

// --- Colors ---

COLOR_WHITE  :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN   :: [4]f32{0.3, 0.9, 1.0, 1.0}

main :: proc() {
	// -----------------------------------------------
	// 1. Initialize Raylib window
	// -----------------------------------------------

	rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
	defer rl.CloseWindow()
	rl.SetTargetFPS(TARGET_FPS)

	// -----------------------------------------------
	// 2. Initialize slug renderer
	// -----------------------------------------------
	//
	// The Raylib backend handles loading Odin's vendor:OpenGL
	// function pointers automatically — no need to import
	// vendor:OpenGL or vendor:glfw yourself.

	renderer := new(slug_rl.Renderer)
	if !slug_rl.init(renderer) {
		fmt.eprintln("Failed to initialize slug Raylib renderer")
		return
	}
	defer {
		slug_rl.destroy(renderer)
		free(renderer)
	}

	// -----------------------------------------------
	// 3. Load fonts + SVG icons into shared atlas
	// -----------------------------------------------
	//
	// All fonts are packed into a single pair of GPU textures (curve + band).
	// This means: one texture bind, one draw call for all text, and free
	// font interleaving (no restriction on use_font switching order).

	ctx := slug_rl.ctx(renderer)
	{
		// Font 0: sans-serif + SVG icons
		font0, font0_ok := slug.font_load(FONT_PATH)
		if !font0_ok {
			fmt.eprintln("Failed to load font:", FONT_PATH)
			return
		}
		slug.font_load_ascii(&font0)
		slug.font_load_range(&font0, 160, 255) // Latin-1 Supplement (é, ñ, ü, etc.)
		slug.svg_load_into_font(&font0, ICON_SWORD, ICON_SWORD_PATH)
		slug.svg_load_into_font(&font0, ICON_HEART, ICON_HEART_PATH)
		slug.svg_load_into_font(&font0, ICON_SHIELD, ICON_SHIELD_PATH)
		slug.svg_load_into_font(&font0, ICON_CIRCLE, ICON_CIRCLE_PATH)
		slug.register_font(ctx, 0, font0)

		// Font 1: serif
		font1, font1_ok := slug.font_load(FONT_SERIF_PATH)
		if !font1_ok {
			fmt.eprintln("Failed to load font:", FONT_SERIF_PATH)
			return
		}
		slug.font_load_ascii(&font1)
		slug.register_font(ctx, 1, font1)

		// Pack all fonts into a shared atlas — one texture pair for everything
		pack := slug.fonts_process_shared(ctx)
		defer slug.pack_result_destroy(&pack)
		slug_rl.upload_shared_textures(renderer, &pack)
	}

	// -----------------------------------------------
	// 4. Cache static text (created once, drawn every frame)
	// -----------------------------------------------

	// We need begin() active to emit quads into the vertex buffer.
	// cache_text() saves and restores quad_count internally.
	slug.begin(ctx)
	cached_label := slug.cache_text(ctx, "Crisp at any size (cached)", LEFT_X + PANEL_PAD, PANEL_CACHED_Y, SMALL_SIZE, COLOR_YELLOW)
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
	cursor_idx  := 0

	// -----------------------------------------------
	// 6. Main game loop
	// -----------------------------------------------

	for !rl.WindowShouldClose() {
		elapsed   := f32(rl.GetTime())
		screen_w  := rl.GetScreenWidth()
		screen_h  := rl.GetScreenHeight()
		mouse_x   := f32(rl.GetMouseX())
		mouse_y   := f32(rl.GetMouseY())

		// UI scale
		if rl.IsKeyPressed(.UP)   do slug.set_ui_scale(ctx, ctx.ui_scale + 0.25)
		if rl.IsKeyPressed(.DOWN) do slug.set_ui_scale(ctx, ctx.ui_scale - 0.25)

		// Cursor keyboard movement
		if rl.IsKeyPressed(.LEFT)  && cursor_idx > 0               do cursor_idx -= 1
		if rl.IsKeyPressed(.RIGHT) && cursor_idx < len(cursor_text) do cursor_idx += 1

		// Click-to-position cursor
		CURSOR_HIT_HEIGHT :: f32(24)
		if rl.IsMouseButtonPressed(.LEFT) {
			if mouse_y >= ROW_CURSOR - CURSOR_HIT_HEIGHT && mouse_y <= ROW_CURSOR + 4 &&
			   mouse_x >= LEFT_X {
				cursor_font := slug.active_font(ctx)
				cursor_idx = slug.index_from_x(cursor_font, cursor_text, SMALL_SIZE, mouse_x - LEFT_X)
			}
		}

		// Scroll region: mouse wheel when hovering
		scroll_content_h := slug.measure_text_wrapped(ctx, SCROLL_TEXT, SMALL_SIZE, scroll_region.width)
		if mouse_x >= scroll_region.x && mouse_x <= scroll_region.x + scroll_region.width &&
		   mouse_y >= scroll_region.y && mouse_y <= scroll_region.y + scroll_region.height {
			wheel := rl.GetMouseWheelMove()
			if wheel != 0 {
				slug.scroll_by(&scroll_region, -wheel * 20.0, scroll_content_h)
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 20, 30, 255})

		// ===========================================
		// PHASE 1: Normal Raylib drawing
		// ===========================================
		//
		// Draw shapes, sprites, tilemaps — anything Raylib handles.
		// Slug text comes AFTER this phase.

		// Panel background
		rl.DrawRectangle(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, rl.Color{40, 40, 60, 255})
		rl.DrawRectangleLines(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, rl.Color{100, 100, 140, 255})

		// Decorative circle (center column)
		rl.DrawCircle(CIRCLE_CX, CIRCLE_CY, CIRCLE_R, rl.Color{60, 20, 80, 255})
		rl.DrawCircleLines(CIRCLE_CX, CIRCLE_CY, CIRCLE_R, rl.Color{140, 80, 200, 255})

		// Gradient bar at bottom
		rl.DrawRectangleGradientH(40, 655, 370, 20, rl.DARKBLUE, rl.SKYBLUE)

		// Alignment guide line
		rl.DrawLine(i32(ALIGN_X), i32(ALIGN_Y0) - 10, i32(ALIGN_X), i32(ALIGN_Y2) + 15, rl.Color{80, 80, 80, 255})

		// Word-wrap box outline (adapts to text height)
		WRAP_TEXT :: "The ancient scroll reads: You have defeated the Skeleton King and earned 250 gold. Your sword glows with newfound power."
		text_h := slug.measure_text_wrapped(ctx, WRAP_TEXT, SMALL_SIZE, WRAP_W - WRAP_PAD * 2)
		rl.DrawRectangleLines(i32(RIGHT_X), i32(WRAP_Y), i32(WRAP_W), i32(text_h) + i32(WRAP_PAD) * 2, rl.Color{80, 80, 120, 255})

		// Scroll region background
		rl.DrawRectangle(i32(scroll_region.x), i32(scroll_region.y), i32(scroll_region.width), i32(scroll_region.height), rl.Color{30, 30, 50, 255})
		rl.DrawRectangleLines(i32(scroll_region.x), i32(scroll_region.y), i32(scroll_region.width), i32(scroll_region.height), rl.Color{80, 80, 120, 255})

		// Scrollbar thumb
		frac  := slug.scroll_fraction(&scroll_region, scroll_content_h)
		vis   := slug.scroll_visible_fraction(&scroll_region, scroll_content_h)
		thumb_h := i32(scroll_region.height * vis)
		if thumb_h < 10 do thumb_h = 10
		thumb_y := i32(scroll_region.y + frac * (scroll_region.height - f32(thumb_h)))
		rl.DrawRectangle(i32(scroll_region.x + scroll_region.width - 4), thumb_y, 4, thumb_h, rl.Color{100, 100, 160, 200})

		// Raylib's built-in text (for comparison — bitmap-based, blurry at large sizes)
		rl.DrawText("Raylib built-in text (bitmap)", 500, 680, 18, rl.GRAY)

		// ===========================================
		// PHASE 2: Slug text rendering
		// ===========================================
		//
		// The Raylib backend's flush() automatically flushes Raylib's
		// internal draw batch before issuing slug's GL draw calls.
		// No need to call rlgl.DrawRenderBatchActive() yourself.

		slug.begin(ctx)

		// ---- Left column ----

		// Title with drop shadow (scales with UI scale)
		slug.draw_text_shadow(
			ctx,
			"Slug + Raylib",
			LEFT_X,
			ROW_TITLE,
			slug.scaled_size(ctx, TITLE_SIZE),
			COLOR_WHITE,
			shadow_offset = 2.0,
		)

		// Subtitle with outline
		slug.draw_text_outlined(
			ctx,
			"GPU Bezier text mixed with Raylib shapes.",
			LEFT_X,
			ROW_SUBTITLE,
			slug.scaled_size(ctx, BODY_SIZE),
			COLOR_CYAN,
			outline_thickness = 2.5,
			outline_color     = {0.8, 0.2, 0.8, 1.0},
		)

		// Rich text markup
		slug.draw_rich_text(ctx, "You deal {red:15} damage with {yellow:Golden Sword}!", LEFT_X, ROW_RICH_TEXT, BODY_SIZE, COLOR_WHITE)

		// Unicode characters (Latin-1 Supplement)
		slug.draw_text(ctx, "Héros: épée, château, naïve, über, señor", LEFT_X, ROW_UNICODE, SMALL_SIZE, {0.7, 0.7, 0.9, 1.0})

		// Highlighted text + {bg:} status tags
		slug.draw_text_highlighted(ctx, "SELECTED", LEFT_X, ROW_HIGHLIGHT, BODY_SIZE, slug.BLACK, {0.3, 0.6, 1.0, 1.0})
		slug.draw_rich_text(ctx, "  Status: {bg:red:POISONED}  {bg:green:HASTE}  {bg:#884400:BURNING}", LEFT_X + 130, ROW_HIGHLIGHT, BODY_SIZE, COLOR_WHITE)

		// Multi-font: switch to serif for one line
		slug.use_font(ctx, 1)
		slug.draw_text(ctx, "This line uses Liberation Serif (font slot 1)", LEFT_X, ROW_SERIF, SMALL_SIZE, {0.9, 0.8, 0.6, 1.0})
		slug.use_font(ctx, 0)

		// Cursor positioning demo
		font := slug.active_font(ctx)
		slug.draw_text(ctx, cursor_text, LEFT_X, ROW_CURSOR, SMALL_SIZE, {0.7, 0.9, 0.7, 1.0})
		cursor_px := slug.cursor_x_from_index(font, cursor_text, SMALL_SIZE, cursor_idx)
		// Blinking cursor line (drawn with Raylib so it appears above slug text)
		if int(elapsed * 2) % 2 == 0 {
			cx := i32(LEFT_X + cursor_px)
			rl.DrawLine(cx, i32(ROW_CURSOR) - 18, cx, i32(ROW_CURSOR) + 4, rl.Color{200, 255, 200, 255})
		}
		slug.draw_text(ctx, fmt.tprintf("[</>] or click  idx:%d", cursor_idx), LEFT_X, ROW_CURSOR_HINT, 14, {0.5, 0.5, 0.5, 1.0})

		// Floating damage number (loops every 1.5s)
		float_age := math.mod(elapsed, 1.5)
		slug.draw_text_float(ctx, "-15", FLOAT_X, FLOAT_Y, BODY_SIZE, {1.0, 0.3, 0.3, 1.0}, float_age, duration = 1.5)

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
			time      = elapsed,
			amplitude = 5.0,
		)
		slug.draw_cached(ctx, &cached_label)

		// Serif font demo line (below panel)
		slug.use_font(ctx, 1)
		slug.draw_text(ctx, "Multi-font: Liberation Serif (slot 1)", LEFT_X, SERIF_LINE_Y, SMALL_SIZE, {0.9, 0.8, 0.6, 1.0})
		slug.use_font(ctx, 0)

		// ---- Center column ----

		// SVG icons (rendered through the same GPU pipeline as text)
		slug.draw_icon(ctx, ICON_SWORD,  ICONS_X,                ICONS_Y, ICON_SIZE, COLOR_YELLOW)
		slug.draw_icon(ctx, ICON_HEART,  ICONS_X + ICON_STRIDE,  ICONS_Y, ICON_SIZE, {1.0, 0.3, 0.3, 1.0})
		slug.draw_icon(ctx, ICON_SHIELD, ICONS_X + ICON_STRIDE*2, ICONS_Y, ICON_SIZE, {0.3, 0.8, 0.4, 1.0})
		slug.draw_icon(ctx, ICON_CIRCLE, ICONS_X + ICON_STRIDE*3, ICONS_Y, ICON_SIZE, {0.5, 0.5, 1.0, 1.0})
		slug.draw_text(ctx, "SVG icons!", ICONS_X + ICON_STRIDE*4 + 2, ICONS_Y - 10, SMALL_SIZE, COLOR_WHITE)

		// Gradient, pulse, fade effects
		slug.draw_text_gradient(ctx, "Gradient text!", FX_X, FX_GRADIENT_Y, BODY_SIZE, {1.0, 0.8, 0.2, 1.0}, {1.0, 0.2, 0.4, 1.0})
		slug.draw_text_pulse(ctx, "Pulsing!", FX_X, FX_PULSE_Y, BODY_SIZE, COLOR_CYAN, time = elapsed)
		fade_alpha := (math.sin(elapsed * 2.0) + 1.0) * 0.5
		slug.draw_text_fade(ctx, "Fading in and out...", FX_X, FX_FADE_Y, SMALL_SIZE, COLOR_WHITE, fade_alpha)

		// Text around and inside the circle
		slug.draw_text_on_circle(
			ctx,
			"  text orbiting a circle  ",
			f32(CIRCLE_CX),
			f32(CIRCLE_CY),
			f32(CIRCLE_R + 20),
			start_angle = -elapsed * 0.4,
			font_size   = SMALL_SIZE,
			color       = {0.8, 0.5, 1.0, 1.0},
		)
		slug.draw_text_rotated(
			ctx,
			"Rotated",
			f32(CIRCLE_CX),
			f32(CIRCLE_CY),
			BODY_SIZE,
			elapsed * 0.6,
			COLOR_YELLOW,
		)

		// ---- Right column ----

		// Pulsing size text
		pulse_size := 60.0 + math.sin(elapsed * 1.5) * 20.0
		slug.draw_text(ctx, "Zoom!", RIGHT_X + 10, ZOOM_Y, f32(pulse_size), {1.0, 0.5, 0.3, 1.0})

		// Truncated text: long string clipped at TRUNCATE_MAX_W with "..."
		// The clip boundary is visualized with a Raylib line.
		rl.DrawLine(i32(RIGHT_X + 10 + TRUNCATE_MAX_W), i32(TRUNCATE_Y) - 18, i32(RIGHT_X + 10 + TRUNCATE_MAX_W), i32(TRUNCATE_Y) + 4, rl.Color{80, 80, 80, 255})
		slug.draw_text(ctx, "clip:", RIGHT_X + 10, TRUNCATE_Y - 18, 12, {0.4, 0.4, 0.5, 1.0})
		slug.draw_text_truncated(ctx, "This long name gets clipped with an ellipsis", RIGHT_X + 10, TRUNCATE_Y, SMALL_SIZE, TRUNCATE_MAX_W, COLOR_WHITE)

		// Monospace grid: each char centered in a fixed-width cell
		cell_w    := slug.mono_width(font, SMALL_SIZE)
		grid_text := "GRID"
		for ch, i in grid_text {
			ch_w   := slug.char_advance(font, ch, SMALL_SIZE)
			char_x := RIGHT_X + f32(i) * cell_w + (cell_w - ch_w) * 0.5
			slug.draw_text(ctx, grid_text[i:][:1], char_x, GRID_Y, SMALL_SIZE, COLOR_CYAN)
		}
		slug.draw_text(ctx, fmt.tprintf("cell: %.1fpx", cell_w), RIGHT_X, GRID_Y + 25, SMALL_SIZE, {0.5, 0.5, 0.5, 1.0})

		// Alignment demo: all three anchored to ALIGN_X
		slug.draw_text(ctx, "Left-aligned", ALIGN_X, ALIGN_Y0, SMALL_SIZE, {0.8, 0.6, 0.6, 1.0})
		slug.draw_text_centered(ctx, "Centered", ALIGN_X, ALIGN_Y1, SMALL_SIZE, {0.6, 0.6, 0.8, 1.0})
		slug.draw_text_right(ctx, "Right-aligned", ALIGN_X, ALIGN_Y2, SMALL_SIZE, {0.6, 0.8, 0.6, 1.0})

		// Word wrap
		slug.draw_text_wrapped(ctx, WRAP_TEXT, RIGHT_X + WRAP_PAD, WRAP_Y + WRAP_PAD, SMALL_SIZE, WRAP_W - WRAP_PAD * 2, COLOR_WHITE)

		// Scrollable text region
		slug.draw_text_scrolled(ctx, SCROLL_TEXT, &scroll_region, SMALL_SIZE, {0.8, 0.8, 0.9, 1.0})
		slug.draw_text(ctx, "Scroll me! [wheel]", scroll_region.x, scroll_region.y - 18, 14, {0.5, 0.5, 0.7, 1.0})

		// Scale indicator
		slug.draw_text(ctx, fmt.tprintf("Scale: %.2fx [Up/Down]", ctx.ui_scale), 10, SCALE_Y, 16, {0.5, 0.5, 0.5, 1.0})

		slug.end(ctx)
		slug_rl.flush(renderer, screen_w, screen_h)

		// FPS counter (Raylib, drawn on top)
		rl.DrawFPS(WINDOW_WIDTH - 100, 10)

		rl.EndDrawing()
	}

	fmt.println("Demo exiting.")
}
