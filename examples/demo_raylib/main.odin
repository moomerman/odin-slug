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

WINDOW_TITLE :: "odin-slug + Raylib"
WINDOW_WIDTH :: 1600
WINDOW_HEIGHT :: 1060
TARGET_FPS :: 60

// --- Font paths ---

FONT_PATH :: "examples/assets/fonts/LiberationSans-Regular.ttf"
FONT_SERIF_PATH :: "examples/assets/fonts/LiberationSerif-Regular.ttf"

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
ROW_TRACKING :: f32(SERIF_LINE_Y + 30) // letter spacing demo
ROW_TABS :: f32(ROW_TRACKING + 28) // tab stop demo

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

// Circle (background shape + orbital text + rotated text)
CIRCLE_CX :: 560 // untyped: used as i32 for rl.DrawCircle, f32 for slug
CIRCLE_CY :: 490
CIRCLE_R :: 90

// Message log (center column, below circle)
LOG_X :: f32(420)
LOG_Y :: f32(740) // bottom line of newest message
LOG_SIZE :: SMALL_SIZE
LOG_PUSH_INTERVAL :: f32(2.5) // seconds between fake messages
LOG_FADE_TIME :: f32(4.0) // seconds before fade starts
LOG_FADE_DURATION :: f32(2.0) // seconds to fade to invisible
LOG_MAX_VISIBLE :: 6

// ---- Right column (x=800..1240): structural demos ----

RIGHT_X :: f32(800)

ZOOM_Y :: f32(250) // pulsing-size "Zoom!" text — shifted down so ascenders don't hit fallback/justify

TRUNCATE_Y :: f32(315) // truncated text demo
TRUNCATE_MAX_W :: f32(240) // clip boundary in pixels
TRUNCATE_WORD_Y :: f32(345) // word-boundary truncation demo

GRID_Y :: f32(380) // monospace grid demo

ALIGN_X :: f32(1050) // x anchor for all three alignment variants
ALIGN_Y0 :: f32(65) // left-aligned
ALIGN_Y1 :: f32(97) // centered
ALIGN_Y2 :: f32(129) // right-aligned

FALLBACK_Y :: f32(163) // fallback chain demo (sans + auto-serif for missing codepoints)

JUSTIFY_Y :: f32(196) // justified alignment demo
JUSTIFY_W :: f32(380) // column width — text expands to fill this exactly

SELECTION_Y :: f32(228) // text selection range highlight demo

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

// ---- Bottom section: new UI widget demos ----

// Bordered panel (left)
UI_PANEL_X :: f32(40)
UI_PANEL_Y :: f32(820)
UI_PANEL_W :: f32(340)
UI_PANEL_H :: f32(180)

// Progress bars (inside panel)
BAR_X :: f32(UI_PANEL_X + 15)
BAR_Y :: f32(UI_PANEL_Y + 40)
BAR_W :: f32(200)
BAR_H :: f32(20)

// Columns demo (center bottom)
COLUMNS_X :: f32(420)
COLUMNS_Y :: f32(840)

// Cursor demo (below columns)
CURSOR2_X :: f32(420)
CURSOR2_Y :: f32(940)

// Rich text wrapped (right bottom)
RICH_WRAP_X :: f32(800)
RICH_WRAP_Y :: f32(820)
RICH_WRAP_W :: f32(420)

SCALE_Y :: f32(1020)

// Camera pan speed in pixels/second for WASD keys
CAMERA_SPEED :: f32(400.0)

// Zoom
ZOOM_WHEEL_STEP :: f32(0.1)  // scale change per mouse wheel notch
ZOOM_FIT_SCALE  :: f32(0.6)  // Tab "fit-all" scale
ZOOM_MIN        :: f32(0.25)
ZOOM_MAX        :: f32(3.0)

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}

// --- Named text styles ---
// Compile-time constants — bundle font, size, color, and decorations together.
// Pass to draw_text_styled for clean, consistent call sites.

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
	size                = SMALL_SIZE,
	color               = COLOR_CYAN,
	underline           = true,
	strikethrough       = true,
	underline_color     = {1.0, 0.3, 0.3, 1.0},
	strikethrough_color = {1.0, 0.9, 0.3, 1.0},
}

// --- Per-character transform callback demo ---
// Demonstrates draw_text_transformed: each glyph bobs on a sine wave and
// shifts hue independently. State is carried via userdata — the idiomatic
// pattern for stateful callbacks in Odin (no closures needed).

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

	renderer := slug_rl.init()
	if renderer == nil {
		fmt.eprintln("Failed to initialize slug Raylib renderer")
		return
	}
	defer slug_rl.destroy(renderer)

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
		slug.font_load_glyph(&font0, '☺') // CP437 smiley for grid demo
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
		slug.font_load_range(&font1, 256, 383) // Latin Extended-A (Ş, ž, Ő, ę, ĺ, etc.)
		slug.register_font(ctx, 1, font1)

		// Font 0 falls back to font 1 for any codepoint not in its loaded range.
		// Characters like Ş ž Ő are absent from font 0 but present in font 1 (serif),
		// so they render in serif automatically when drawn with font 0 active.
		// Requires shared_atlas — enforced by using fonts_process_shared below.
		slug.font_set_fallback(ctx, 0, 1)

		// Pack all fonts into a shared atlas — one texture pair for everything
		pack := slug.fonts_process_shared(ctx)
		defer slug.pack_result_destroy(&pack)
		slug_rl.upload_shared_textures(renderer, &pack)
	}

	ctx.weight_boost = true

	// -----------------------------------------------
	// 4. Cache static text (created once, drawn every frame)
	// -----------------------------------------------

	// We need begin() active to emit quads into the vertex buffer.
	// cache_text() saves and restores quad_count internally.
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

	// Message log state
	msg_log: slug.Message_Log
	slug.log_init(&msg_log, LOG_FADE_TIME, LOG_FADE_DURATION, LOG_MAX_VISIBLE)
	next_msg_time: f32 = 1.0 // first message after 1 second
	msg_index := 0
	LOG_MESSAGES :: [?]struct {
		text:  string,
		color: slug.Color,
	}{
		{"You enter the dungeon.",                        {0.7, 0.7, 0.9, 1.0}},
		{"A goblin lunges from the shadows!",             {1.0, 0.5, 0.3, 1.0}},
		{"You swing your sword for 12 damage.",           {1.0, 0.9, 0.3, 1.0}},
		{"The goblin retaliates for 5 damage!",           {1.0, 0.3, 0.3, 1.0}},
		{"You found a healing potion.",                   {0.3, 1.0, 0.5, 1.0}},
		{"The goblin collapses. +25 XP.",                 {0.5, 0.85, 1.0, 1.0}},
		{"You descend deeper into the crypt...",          {0.7, 0.7, 0.9, 1.0}},
		{"A skeleton king awakens!",                      {1.0, 0.3, 0.3, 1.0}},
		{"Your sword glows with holy light.",             {1.0, 0.9, 0.5, 1.0}},
		{"Critical hit! 48 damage!",                      {1.0, 1.0, 0.3, 1.0}},
		{"The crypt trembles...",                         {0.6, 0.4, 0.8, 1.0}},
		{"Victory! The skeleton king is vanquished.",     {0.3, 1.0, 0.5, 1.0}},
	}

	// Camera pan state
	cam_x: f32 = 0
	cam_y: f32 = 0

	// -----------------------------------------------
	// 6. Main game loop
	// -----------------------------------------------

	for !rl.WindowShouldClose() {
		elapsed := f32(rl.GetTime())
		dt := rl.GetFrameTime()
		screen_w := rl.GetScreenWidth()
		screen_h := rl.GetScreenHeight()
		mouse_x := f32(rl.GetMouseX())
		mouse_y := f32(rl.GetMouseY())

		// UI scale — Up/Down keys, Tab toggle, clamped
		if rl.IsKeyPressed(.UP)  do slug.set_ui_scale(ctx, clamp(ctx.ui_scale + 0.25, ZOOM_MIN, ZOOM_MAX))
		if rl.IsKeyPressed(.DOWN) do slug.set_ui_scale(ctx, clamp(ctx.ui_scale - 0.25, ZOOM_MIN, ZOOM_MAX))
		if rl.IsKeyPressed(.TAB) {
			slug.set_ui_scale(ctx, ZOOM_FIT_SCALE if ctx.ui_scale != ZOOM_FIT_SCALE else 1.0)
		}

		// Camera pan — WASD keys
		if rl.IsKeyDown(.W) do cam_y -= CAMERA_SPEED * dt
		if rl.IsKeyDown(.S) do cam_y += CAMERA_SPEED * dt
		if rl.IsKeyDown(.A) do cam_x -= CAMERA_SPEED * dt
		if rl.IsKeyDown(.D) do cam_x += CAMERA_SPEED * dt

		// Camera pan — middle mouse drag
		if rl.IsMouseButtonDown(.MIDDLE) {
			delta := rl.GetMouseDelta()
			cam_x += delta.x
			cam_y += delta.y
		}

		// Camera reset
		if rl.IsKeyPressed(.R) {
			cam_x = 0
			cam_y = 0
		}

		// Cursor keyboard movement
		if rl.IsKeyPressed(.LEFT) && cursor_idx > 0 do cursor_idx -= 1
		if rl.IsKeyPressed(.RIGHT) && cursor_idx < len(cursor_text) do cursor_idx += 1

		// Click-to-position cursor
		if rl.IsMouseButtonPressed(.LEFT) {
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

		// Scroll region: mouse wheel scrolls text when hovering, else zooms canvas
		scroll_content_h, _ := slug.measure_text_wrapped(
			ctx,
			SCROLL_TEXT,
			SMALL_SIZE,
			scroll_region.width,
		)
		// Convert mouse to world space for hit testing against world-space layout
		world_mx := mouse_x - cam_x
		world_my := mouse_y - cam_y

		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			if world_mx >= scroll_region.x &&
			   world_mx <= scroll_region.x + scroll_region.width &&
			   world_my >= scroll_region.y &&
			   world_my <= scroll_region.y + scroll_region.height {
				slug.scroll_by(&scroll_region, -wheel * 20.0, scroll_content_h)
			} else {
				slug.set_ui_scale(ctx, clamp(ctx.ui_scale + wheel * ZOOM_WHEEL_STEP, ZOOM_MIN, ZOOM_MAX))
			}
		}

		// Push fake roguelike messages on a timer
		if elapsed >= next_msg_time {
			messages := LOG_MESSAGES
			m := messages[msg_index % len(LOG_MESSAGES)]
			slug.log_push(&msg_log, m.text, m.color, elapsed)
			msg_index += 1
			next_msg_time = elapsed + LOG_PUSH_INTERVAL
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 20, 30, 255})

		// ===========================================
		// PHASE 1: Normal Raylib drawing
		// ===========================================
		//
		// Draw shapes, sprites, tilemaps — anything Raylib handles.
		// Slug text comes AFTER this phase.

		// Camera-adjusted integer offsets for Raylib draw calls
		cx := i32(cam_x)
		cy := i32(cam_y)

		// Panel background
		rl.DrawRectangle(PANEL_X + cx, PANEL_Y + cy, PANEL_W, PANEL_H, rl.Color{40, 40, 60, 255})
		rl.DrawRectangleLines(PANEL_X + cx, PANEL_Y + cy, PANEL_W, PANEL_H, rl.Color{100, 100, 140, 255})

		// Decorative circle (center column)
		rl.DrawCircle(CIRCLE_CX + cx, CIRCLE_CY + cy, CIRCLE_R, rl.Color{60, 20, 80, 255})
		rl.DrawCircleLines(CIRCLE_CX + cx, CIRCLE_CY + cy, CIRCLE_R, rl.Color{140, 80, 200, 255})

		// Gradient bar at bottom
		rl.DrawRectangleGradientH(40 + cx, 655 + cy, 370, 20, rl.DARKBLUE, rl.SKYBLUE)

		// Alignment guide line
		rl.DrawLine(
			i32(ALIGN_X) + cx,
			i32(ALIGN_Y0) - 10 + cy,
			i32(ALIGN_X) + cx,
			i32(ALIGN_Y2) + 15 + cy,
			rl.Color{80, 80, 80, 255},
		)

		// Word-wrap box outline (adapts to text height)
		WRAP_TEXT :: "The ancient scroll reads: You have defeated the Skeleton King and earned 250 gold. Your sword glows with newfound power."
		text_h, _ := slug.measure_text_wrapped(ctx, WRAP_TEXT, SMALL_SIZE, WRAP_W - WRAP_PAD * 2)
		rl.DrawRectangleLines(
			i32(RIGHT_X) + cx,
			i32(WRAP_Y) + cy,
			i32(WRAP_W),
			i32(text_h) + i32(WRAP_PAD) * 2,
			rl.Color{80, 80, 120, 255},
		)

		// Scroll region background
		rl.DrawRectangle(
			i32(scroll_region.x) + cx,
			i32(scroll_region.y) + cy,
			i32(scroll_region.width),
			i32(scroll_region.height),
			rl.Color{30, 30, 50, 255},
		)
		rl.DrawRectangleLines(
			i32(scroll_region.x) + cx,
			i32(scroll_region.y) + cy,
			i32(scroll_region.width),
			i32(scroll_region.height),
			rl.Color{80, 80, 120, 255},
		)

		// Scrollbar thumb
		frac := slug.scroll_fraction(&scroll_region, scroll_content_h)
		vis := slug.scroll_visible_fraction(&scroll_region, scroll_content_h)
		thumb_h := i32(scroll_region.height * vis)
		if thumb_h < 10 do thumb_h = 10
		thumb_y := i32(scroll_region.y + frac * (scroll_region.height - f32(thumb_h)))
		rl.DrawRectangle(
			i32(scroll_region.x + scroll_region.width - 4) + cx,
			thumb_y + cy,
			4,
			thumb_h,
			rl.Color{100, 100, 160, 200},
		)

		// GPU scissor demo box outline — drawn with Raylib (unclipped)
		rl.DrawRectangle(
			i32(CLIP_BOX_X) + cx,
			i32(CLIP_BOX_Y) + cy,
			i32(CLIP_BOX_W),
			i32(CLIP_BOX_H),
			rl.Color{20, 36, 56, 255},
		)
		rl.DrawRectangleLines(
			i32(CLIP_BOX_X) + cx,
			i32(CLIP_BOX_Y) + cy,
			i32(CLIP_BOX_W),
			i32(CLIP_BOX_H),
			rl.Color{80, 100, 150, 255},
		)

		// Raylib's built-in text (for comparison — bitmap-based, blurry at large sizes)
		rl.DrawText("Raylib built-in text (bitmap)", 500 + cx, 680 + cy, 18, rl.GRAY)

		// ===========================================
		// PHASE 2: Slug text rendering
		// ===========================================
		//
		// The Raylib backend's flush() automatically flushes Raylib's
		// internal draw batch before issuing slug's GL draw calls.
		// No need to call rlgl.DrawRenderBatchActive() yourself.

		slug.begin(ctx)
		slug.set_camera(ctx, cam_x, cam_y)

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
		// Blinking cursor line (drawn with Raylib so it appears above slug text)
		if int(elapsed * 2) % 2 == 0 {
			cursor_screen_x := i32(LEFT_X + cursor_px) + cx
			rl.DrawLine(
				cursor_screen_x,
				i32(ROW_CURSOR) - 18 + cy,
				cursor_screen_x,
				i32(ROW_CURSOR) + 4 + cy,
				rl.Color{200, 255, 200, 255},
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

		// Letter spacing (tracking)
		slug.draw_text(ctx, "W i d e  tracking", LEFT_X, ROW_TRACKING, SMALL_SIZE, {0.7, 0.8, 1.0, 1.0}, tracking = 4.0)

		// Tab stops
		slug.draw_text(ctx, "Name\tHP\tMP", LEFT_X, ROW_TABS, SMALL_SIZE, {0.7, 1.0, 0.7, 1.0})

		// ---- Center column ----

		// SVG icons (rendered through the same GPU pipeline as text)
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

		// Per-character transform callback: wave + hue shift
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

		// Text around and inside the circle
		slug.draw_text_on_circle(
			ctx,
			"  text orbiting a circle  ",
			f32(CIRCLE_CX),
			f32(CIRCLE_CY),
			f32(CIRCLE_R + 20),
			start_angle = -elapsed * 0.4,
			font_size = SMALL_SIZE,
			color = {0.8, 0.5, 1.0, 1.0},
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

		// Message log (below circle)
		slug.draw_text(ctx, "Message Log:", LOG_X, LOG_Y - f32(LOG_MAX_VISIBLE) * 28 - 14, 13, {0.5, 0.5, 0.7, 1.0})
		slug.draw_message_log(ctx, &msg_log, LOG_X, LOG_Y, LOG_SIZE, elapsed)

		// ---- Right column ----

		// Pulsing size text
		pulse_size := 60.0 + math.sin(elapsed * 1.5) * 20.0
		slug.draw_text(ctx, "Zoom!", RIGHT_X + 10, ZOOM_Y, f32(pulse_size), {1.0, 0.5, 0.3, 1.0})

		// Truncated text: long string clipped at TRUNCATE_MAX_W with "..."
		// The clip boundary is visualized with a Raylib line.
		rl.DrawLine(
			i32(RIGHT_X + 10 + TRUNCATE_MAX_W) + cx,
			i32(TRUNCATE_Y) - 18 + cy,
			i32(RIGHT_X + 10 + TRUNCATE_MAX_W) + cx,
			i32(TRUNCATE_Y) + 4 + cy,
			rl.Color{80, 80, 80, 255},
		)
		// Truncated text: custom ellipsis string
		slug.draw_text(ctx, "clip:", RIGHT_X + 10, TRUNCATE_Y - 18, 12, {0.4, 0.4, 0.5, 1.0})
		slug.draw_text_truncated(
			ctx,
			"This long name gets clipped with an ellipsis",
			RIGHT_X + 10,
			TRUNCATE_Y,
			SMALL_SIZE,
			TRUNCATE_MAX_W,
			COLOR_WHITE,
			ellipsis = " [...]",
		)

		// Word-boundary truncation: backs up to last space
		slug.draw_text_truncated_word(
			ctx,
			"Word-boundary truncation clips at spaces",
			RIGHT_X + 10,
			TRUNCATE_WORD_Y,
			SMALL_SIZE,
			TRUNCATE_MAX_W,
			{0.8, 0.8, 0.6, 1.0},
		)

		// Fixed-width grid: roguelike map row, each char centered in its cell
		grid_cell_w := slug.mono_width(font, SMALL_SIZE)
		grid_cell_h := slug.line_height(font, SMALL_SIZE)
		slug.draw_text_grid(
			ctx,
			"##.@..g..##\n##..☺....##",
			RIGHT_X,
			GRID_Y,
			SMALL_SIZE,
			grid_cell_w,
			grid_cell_h,
			COLOR_CYAN,
		)
		slug.draw_text(
			ctx,
			fmt.tprintf("cell: %.0fx%.0fpx", grid_cell_w, grid_cell_h),
			RIGHT_X,
			GRID_Y + grid_cell_h * 2 + 4,
			13,
			{0.5, 0.5, 0.7, 1.0},
		)

		// Alignment demo: all three anchored to ALIGN_X
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

		// Fallback chain demo: font 0 lacks Latin Extended-A (256-383), font 1 has it.
		// Drawing with font 0 active: ASCII renders sans-serif, Ş ž Ő render in serif.
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

		// Text selection range highlight
		slug.draw_text_selection(
			ctx,
			"Select range demo",
			RIGHT_X,
			SELECTION_Y,
			SMALL_SIZE,
			COLOR_WHITE,
			7,
			12,
			{0.2, 0.3, 0.8, 0.6},
		)

		// Word wrap
		slug.draw_text_wrapped(
			ctx,
			WRAP_TEXT,
			RIGHT_X + WRAP_PAD,
			WRAP_Y + WRAP_PAD,
			SMALL_SIZE,
			WRAP_W - WRAP_PAD * 2,
			COLOR_WHITE,
			line_spacing = 1.4,
		)

		// Scrollable text region
		slug.draw_text_scrolled(ctx, SCROLL_TEXT, &scroll_region, SMALL_SIZE, {0.8, 0.8, 0.9, 1.0})
		slug.draw_text(
			ctx,
			"Scroll me! [wheel]",
			scroll_region.x,
			scroll_region.y - 18,
			14,
			{0.5, 0.5, 0.7, 1.0},
		)

		// Scissor demo label (unclipped — lives in the main pass)
		slug.draw_text(ctx, "GPU scissor:", CLIP_BOX_X, CLIP_LABEL_Y, 13, {0.5, 0.5, 0.7, 1.0})

		// ---- Bottom section: UI widget demos ----

		// Bordered panel with rect outline
		slug.draw_rect_bordered(
			ctx,
			UI_PANEL_X, UI_PANEL_Y, UI_PANEL_W, UI_PANEL_H,
			{0.1, 0.1, 0.18, 1.0},  // fill
			{0.4, 0.4, 0.7, 1.0},   // border
			border = 2,
		)
		slug.draw_text(ctx, "Bordered Panel", UI_PANEL_X + 15, UI_PANEL_Y + 26, SMALL_SIZE, COLOR_WHITE)

		// Progress bars inside panel
		hp := 72.0 + math.sin(elapsed * 0.5) * 28.0 // animated HP
		slug.draw_bar(
			ctx,
			BAR_X, BAR_Y, BAR_W, BAR_H,
			f32(hp), 100,
			{0.2, 0.8, 0.3, 1.0}, // fill green
			{0.15, 0.15, 0.25, 1.0}, // bg
			label = fmt.tprintf("HP %d/100", int(hp)),
			label_size = 14,
			label_color = COLOR_WHITE,
			border_color = {0.4, 0.6, 0.4, 1.0},
			border = 1,
		)
		mp := 35.0 + math.sin(elapsed * 0.7) * 15.0
		slug.draw_bar(
			ctx,
			BAR_X, BAR_Y + 30, BAR_W, BAR_H,
			f32(mp), 80,
			{0.3, 0.4, 0.9, 1.0},
			{0.15, 0.15, 0.25, 1.0},
			label = fmt.tprintf("MP %d/80", int(mp)),
			label_size = 14,
			border_color = {0.3, 0.4, 0.7, 1.0},
			border = 1,
		)

		// Rect outline demo (standalone)
		slug.draw_rect_outline(ctx, UI_PANEL_X + 15, BAR_Y + 70, 120, 50, {0.6, 0.3, 0.8, 1.0}, 2)
		slug.draw_text(ctx, "Outline", UI_PANEL_X + 35, BAR_Y + 100, 14, {0.6, 0.3, 0.8, 1.0})

		// Columns demo
		slug.draw_text(ctx, "Columnar layout:", COLUMNS_X, COLUMNS_Y - 10, 13, {0.5, 0.5, 0.7, 1.0})
		slug.draw_text_columns(ctx, {
			{text = "Name",      width = 160, align = .Left,  color = {0.5, 0.5, 0.7, 1.0}},
			{text = "HP",        width = 80,  align = .Right, color = {0.5, 0.5, 0.7, 1.0}},
			{text = "Status",    width = 120, align = .Center, color = {0.5, 0.5, 0.7, 1.0}},
		}, COLUMNS_X, COLUMNS_Y + 14, SMALL_SIZE, COLOR_WHITE)
		slug.draw_text_columns(ctx, {
			{text = "Skeleton",  width = 160, align = .Left,  color = {0.8, 0.6, 0.6, 1.0}},
			{text = "45/80",     width = 80,  align = .Right, color = {1.0, 0.5, 0.3, 1.0}},
			{text = "BURNING",   width = 120, align = .Center, color = {1.0, 0.6, 0.2, 1.0}},
		}, COLUMNS_X, COLUMNS_Y + 42, SMALL_SIZE, COLOR_WHITE)
		slug.draw_text_columns(ctx, {
			{text = "Goblin",    width = 160, align = .Left,  color = {0.6, 0.8, 0.6, 1.0}},
			{text = "12/30",     width = 80,  align = .Right, color = {1.0, 0.3, 0.3, 1.0}},
			{text = "POISONED",  width = 120, align = .Center, color = {0.3, 0.9, 0.3, 1.0}},
		}, COLUMNS_X, COLUMNS_Y + 70, SMALL_SIZE, COLOR_WHITE)

		// Blinking cursor demo (slug-native, not Raylib lines)
		slug.draw_text(ctx, "Cursor:", CURSOR2_X, CURSOR2_Y - 10, 13, {0.5, 0.5, 0.7, 1.0})
		slug.draw_text(ctx, "Text input field", CURSOR2_X, CURSOR2_Y + 16, SMALL_SIZE, {0.7, 0.9, 0.7, 1.0})
		cursor2_px := slug.cursor_x_from_index(font, "Text input field", SMALL_SIZE, 10)
		slug.draw_cursor(ctx, CURSOR2_X + cursor2_px, CURSOR2_Y + 16, SMALL_SIZE, {0.3, 1.0, 0.5, 1.0}, time = f64(elapsed))

		// Rich text wrapped
		slug.draw_text(ctx, "Rich text wrapped:", RICH_WRAP_X, RICH_WRAP_Y - 10, 13, {0.5, 0.5, 0.7, 1.0})
		slug.draw_rect_bordered(
			ctx,
			RICH_WRAP_X, RICH_WRAP_Y, RICH_WRAP_W, 120,
			{0.08, 0.08, 0.14, 1.0},
			{0.3, 0.3, 0.5, 1.0},
			border = 1,
		)
		slug.draw_rich_text_wrapped(
			ctx,
			"The {red:goblin} attacks for {yellow:8 damage}! You counter with {icon:128:yellow}{yellow:Golden Sword} for {green:15 damage}. The {red:goblin} is {bg:red:DEFEATED}! You gain {cyan:25 XP}.",
			RICH_WRAP_X + 10, RICH_WRAP_Y + 8,
			SMALL_SIZE,
			RICH_WRAP_W - 20,
			COLOR_WHITE,
			line_spacing = 1.4,
		)

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
		slug_rl.flush(renderer, screen_w, screen_h) // pass 1: all main content, no scissor

		// Pass 2: clipped panel text — scissor follows canvas pan
		slug.begin(ctx)
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
		slug_rl.flush(
			renderer,
			screen_w,
			screen_h,
			scissor = slug.Scissor_Rect {
				x = CLIP_BOX_X + cam_x,
				y = CLIP_BOX_Y + cam_y,
				w = CLIP_BOX_W,
				h = CLIP_BOX_H,
			},
		)

		// FPS counter (Raylib, drawn on top)
		rl.DrawFPS(WINDOW_WIDTH - 100, 10)

		rl.EndDrawing()
	}

	fmt.println("Demo exiting.")
}
