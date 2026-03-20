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

// --- Window constants ---

WINDOW_TITLE :: "odin-slug + Raylib"
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
TARGET_FPS :: 60

// --- Font path ---

FONT_PATH :: "examples/assets/fonts/LiberationSans-Regular.ttf"

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

CIRCLE_X :: 640
CIRCLE_Y :: 520
CIRCLE_RADIUS :: 80

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}

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
	// 3. Load font + SVG icons
	// -----------------------------------------------
	//
	// SVG icons must be loaded before font_process(), so we use the
	// manual pipeline here. For fonts without icons, use slug_rl.load_font().

	ctx := slug_rl.ctx(renderer)
	{
		font, font_ok := slug.font_load(FONT_PATH)
		if !font_ok {
			fmt.eprintln("Failed to load font:", FONT_PATH)
			return
		}
		slug.font_load_ascii(&font)
		slug.font_load_range(&font, 160, 255) // Latin-1 Supplement (é, ñ, ü, etc.)
		slug.svg_load_into_font(&font, ICON_SWORD, ICON_SWORD_PATH)
		slug.svg_load_into_font(&font, ICON_HEART, ICON_HEART_PATH)
		slug.svg_load_into_font(&font, ICON_SHIELD, ICON_SHIELD_PATH)
		slug.svg_load_into_font(&font, ICON_CIRCLE, ICON_CIRCLE_PATH)

		pack := slug.font_process(&font)
		defer slug.pack_result_destroy(&pack)

		slug.register_font(ctx, 0, font)
		slug_rl.upload_font_textures(renderer, 0, &pack)
	}

	// -----------------------------------------------
	// 4. Cache static text (created once, drawn every frame)
	// -----------------------------------------------

	// We need begin() active to emit quads into the vertex buffer.
	// cache_text() saves and restores quad_count internally.
	slug.begin(ctx)
	cached_label := slug.cache_text(ctx, "Crisp at any size (cached)", f32(BOX_X + 15), f32(BOX_Y + 155), SMALL_SIZE, COLOR_YELLOW)
	defer slug.cache_destroy(&cached_label)

	// -----------------------------------------------
	// 5. Main game loop
	// -----------------------------------------------

	for !rl.WindowShouldClose() {
		elapsed := f32(rl.GetTime())
		screen_w := rl.GetScreenWidth()
		screen_h := rl.GetScreenHeight()

		// UI scale with Up/Down arrow keys
		if rl.IsKeyPressed(.UP) do slug.set_ui_scale(ctx, ctx.ui_scale + 0.25)
		if rl.IsKeyPressed(.DOWN) do slug.set_ui_scale(ctx, ctx.ui_scale - 0.25)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 20, 30, 255})

		// ===========================================
		// PHASE 1: Normal Raylib drawing
		// ===========================================
		//
		// Draw shapes, sprites, tilemaps — anything Raylib handles.
		// Slug text comes AFTER this phase.

		// A panel background
		rl.DrawRectangle(BOX_X, BOX_Y, BOX_WIDTH, BOX_HEIGHT, rl.Color{40, 40, 60, 255})
		rl.DrawRectangleLines(BOX_X, BOX_Y, BOX_WIDTH, BOX_HEIGHT, rl.Color{100, 100, 140, 255})

		// Some decorative shapes
		rl.DrawCircle(CIRCLE_X, CIRCLE_Y, CIRCLE_RADIUS, rl.Color{60, 20, 80, 255})
		rl.DrawCircleLines(CIRCLE_X, CIRCLE_Y, CIRCLE_RADIUS, rl.Color{140, 80, 200, 255})

		// A gradient bar
		rl.DrawRectangleGradientH(40, 660, 400, 30, rl.DARKBLUE, rl.SKYBLUE)

		// Raylib's built-in text (for comparison — bitmap-based, blurry at large sizes)
		rl.DrawText("Raylib built-in text (bitmap)", 500, 660, 20, rl.GRAY)

		// ===========================================
		// PHASE 2: Slug text rendering
		// ===========================================
		//
		// The Raylib backend's flush() automatically flushes Raylib's
		// internal draw batch before issuing slug's GL draw calls.
		// No need to call rlgl.DrawRenderBatchActive() yourself.

		slug.begin(ctx)

		// -- Title with drop shadow (scales with UI scale) --
		slug.draw_text_shadow(
			ctx,
			"Slug + Raylib",
			LEFT_MARGIN,
			TOP_START,
			slug.scaled_size(ctx, TITLE_SIZE),
			COLOR_WHITE,
			shadow_offset = 2.0,
		)

		// -- Description text with outline (scales with UI scale) --
		slug.draw_text_outlined(
			ctx,
			"GPU Bezier text mixed with Raylib shapes.",
			LEFT_MARGIN,
			TOP_START + LINE_SPACING,
			slug.scaled_size(ctx, BODY_SIZE),
			COLOR_CYAN,
			outline_thickness = 2.5,
			outline_color = {0.8, 0.2, 0.8, 1.0},
		)

		// -- Rainbow text over the panel --
		slug.draw_text_rainbow(
			ctx,
			"Rainbow on a panel!",
			f32(BOX_X + 15),
			f32(BOX_Y + 45),
			BODY_SIZE,
			time = elapsed,
		)

		// -- Wobble text inside the panel --
		slug.draw_text_wobble(
			ctx,
			"Wobbly!",
			f32(BOX_X + 15),
			f32(BOX_Y + 100),
			BODY_SIZE,
			time = elapsed,
			amplitude = 5.0,
		)

		// -- Cached static text inside the panel --
		// No per-character processing — just a memcopy of pre-built vertices.
		slug.draw_cached(ctx, &cached_label)

		// -- SVG icons (rendered through the same GPU pipeline as text) --
		slug.draw_icon(ctx, ICON_SWORD, 420, 460, ICON_SIZE, COLOR_YELLOW)
		slug.draw_icon(ctx, ICON_HEART, 470, 460, ICON_SIZE, {1.0, 0.3, 0.3, 1.0})
		slug.draw_icon(ctx, ICON_SHIELD, 520, 460, ICON_SIZE, {0.3, 0.8, 0.4, 1.0})
		slug.draw_icon(ctx, ICON_CIRCLE, 570, 460, ICON_SIZE, {0.5, 0.5, 1.0, 1.0})
		slug.draw_text(ctx, "SVG icons!", 620, 448, SMALL_SIZE, COLOR_WHITE)

		// -- Text around the circle --
		slug.draw_text_on_circle(
			ctx,
			"  text orbiting a circle  ",
			f32(CIRCLE_X),
			f32(CIRCLE_Y),
			f32(CIRCLE_RADIUS + 20),
			start_angle = -elapsed * 0.4,
			font_size = SMALL_SIZE,
			color = {0.8, 0.5, 1.0, 1.0},
		)

		// -- Rotated text near the circle --
		slug.draw_text_rotated(
			ctx,
			"Rotated",
			f32(CIRCLE_X),
			f32(CIRCLE_Y),
			BODY_SIZE,
			elapsed * 0.6,
			COLOR_YELLOW,
		)

		// -- Large text to show resolution independence --
		pulse_size := 60.0 + math.sin(elapsed * 1.5) * 20.0
		slug.draw_text(ctx, "Zoom!", 800, 200, f32(pulse_size), {1.0, 0.5, 0.3, 1.0})

		// -- Measurement API demo: manually positioned colored text segments --
		font := slug.active_font(ctx)
		seg_y: f32 = 350
		seg_x: f32 = LEFT_MARGIN
		slug.draw_text(ctx, "You deal ", seg_x, seg_y, BODY_SIZE, COLOR_WHITE)
		seg_w, _ := slug.measure_text(font, "You deal ", BODY_SIZE)
		seg_x += seg_w
		slug.draw_text(ctx, "15", seg_x, seg_y, BODY_SIZE, {1.0, 0.3, 0.3, 1.0})
		dmg_w, _ := slug.measure_text(font, "15", BODY_SIZE)
		seg_x += dmg_w
		slug.draw_text(ctx, " damage!", seg_x, seg_y, BODY_SIZE, COLOR_WHITE)

		// -- Unicode demo --
		slug.draw_text(ctx, "Héros: épée, château, naïve, über, señor", LEFT_MARGIN, seg_y + LINE_SPACING, SMALL_SIZE, {0.7, 0.7, 0.9, 1.0})

		// -- Monospace grid demo --
		// Each character is centered within a fixed-width cell,
		// so even proportional fonts align to a grid.
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

		// -- Word wrap demo --
		// draw_text_wrapped returns total height, so we can size the box to fit.
		WRAP_TEXT :: "The ancient scroll reads: You have defeated the Skeleton King and earned 250 gold. Your sword glows with newfound power."
		WRAP_X :: 800
		WRAP_Y :: 420
		WRAP_WIDTH :: f32(420)
		WRAP_PAD :: 8
		text_h := slug.draw_text_wrapped(ctx, WRAP_TEXT, f32(WRAP_X + WRAP_PAD), f32(WRAP_Y + WRAP_PAD), SMALL_SIZE, WRAP_WIDTH - WRAP_PAD * 2, COLOR_WHITE)
		rl.DrawRectangleLines(WRAP_X, WRAP_Y, i32(WRAP_WIDTH), i32(text_h) + WRAP_PAD * 2, rl.Color{80, 80, 120, 255})

		// Finalize and draw.
		slug.end(ctx)
		slug_rl.flush(renderer, screen_w, screen_h)

		// ===========================================
		// PHASE 3: Post-slug Raylib drawing (optional)
		// ===========================================
		//
		// If you need to draw Raylib content ON TOP of slug text (e.g., a
		// cursor, tooltip border), you can do more Raylib draws here.
		// Raylib will re-bind its own shader on the next rl.Draw* call.

		// FPS counter and scale indicator
		rl.DrawFPS(WINDOW_WIDTH - 100, 10)
		rl.DrawText(fmt.ctprintf("Scale: %.2fx [Up/Down]", ctx.ui_scale), 10, WINDOW_HEIGHT - 25, 16, rl.GRAY)

		rl.EndDrawing()
	}

	fmt.println("Demo exiting.")
}
