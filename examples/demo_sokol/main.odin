package main

// ===================================================
// odin-slug Sokol GFX Demo
//
// Standalone example showing GPU-accelerated Bezier text rendering
// using odin-slug with a Sokol GFX backend. Uses sokol_app for windowing
// and sokol_gfx for rendering.
// Showcases all library features: effects, wrapping, scrolling, cursor
// positioning, rich text, caching, alignment, shared font atlas, etc.
//
// Build:
//   odin build examples/demo_sokol/ -out:demo_sokol \
//     -collection:libs=. -collection:sokol=/path/to/sokol-odin
//
// Prerequisites:
//   - Liberation fonts in examples/assets/fonts/
//   - sokol-odin cloned (github.com/floooh/sokol-odin)
//   - OpenGL 4.3+ capable GPU (for GLSL 430)
// ===================================================

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:time"

import sapp "sokol:app"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

import slug "libs:slug"
import slug_sokol "libs:slug/backends/sokol"

// --- Window ---

WINDOW_TITLE :: "odin-slug Sokol GFX Demo"
WINDOW_WIDTH :: 1600
WINDOW_HEIGHT :: 1060

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
// =============================================================

// ---- Left column (x=40..390): text feature demos ----

LEFT_X :: f32(40)

ROW_TITLE :: f32(60)
ROW_SUBTITLE :: f32(132)
ROW_RICH_TEXT :: f32(192)
ROW_UNICODE :: f32(238)
ROW_HIGHLIGHT :: f32(282)
ROW_STATUS :: f32(330)
ROW_SERIF :: f32(380)
ROW_CURSOR :: f32(426)
ROW_CURSOR_HINT :: f32(454)

FLOAT_X :: f32(310)
FLOAT_Y :: f32(426)

ROW_DECORATION :: f32(480)

PANEL_X :: 40
PANEL_Y :: 516
PANEL_W :: 340
PANEL_H :: 210
PANEL_PAD :: f32(15)

PANEL_RAINBOW_Y :: f32(PANEL_Y + 55)
PANEL_WOBBLE_Y :: f32(PANEL_Y + 108)
PANEL_CACHED_Y :: f32(PANEL_Y + 161)

SERIF_LINE_Y :: f32(PANEL_Y + PANEL_H + 25)

ROW_TRACKING :: f32(SERIF_LINE_Y + 30)
ROW_TABS :: f32(ROW_TRACKING + 28)

// ---- Center column (x=420..760): animated effects ----

ICONS_X :: f32(420)
ICONS_Y :: f32(88)
ICON_STRIDE :: f32(56)

FX_X :: f32(420)
FX_GRADIENT_Y :: f32(160)
FX_PULSE_Y :: f32(212)
FX_FADE_Y :: f32(264)
FX_XFORM_Y :: f32(320)
FX_SUBSUP_Y :: f32(378)

CIRCLE_CX :: f32(560)
CIRCLE_CY :: f32(490)
CIRCLE_R :: f32(90)

LOG_X :: f32(420)
LOG_Y :: f32(740)
LOG_SIZE :: SMALL_SIZE
LOG_PUSH_INTERVAL :: f32(2.5)
LOG_FADE_TIME :: f32(4.0)
LOG_FADE_DURATION :: f32(2.0)
LOG_MAX_VISIBLE :: 6

// ---- Right column (x=800..1240): structural demos ----

RIGHT_X :: f32(800)

ZOOM_Y :: f32(250)

TRUNCATE_Y :: f32(315)
TRUNCATE_MAX_W :: f32(240)
TRUNCATE_WORD_Y :: f32(345)

GRID_Y :: f32(380)

ALIGN_X :: f32(1050)
ALIGN_Y0 :: f32(65)
ALIGN_Y1 :: f32(97)
ALIGN_Y2 :: f32(129)

FALLBACK_Y :: f32(163)

JUSTIFY_Y :: f32(196)
JUSTIFY_W :: f32(380)

SELECTION_Y :: f32(228)

WRAP_W :: f32(420)
WRAP_Y :: f32(425)
WRAP_PAD :: f32(8)

SCROLL_W :: f32(420)
SCROLL_Y :: f32(590)
SCROLL_H :: f32(110)

CLIP_LABEL_Y :: f32(720)
CLIP_BOX_X :: RIGHT_X
CLIP_BOX_Y :: f32(738)
CLIP_BOX_W :: f32(200)
CLIP_BOX_H :: f32(44)
CLIP_TEXT_Y :: CLIP_BOX_Y + 29

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

CAMERA_SPEED :: f32(400.0)
ZOOM_WHEEL_STEP :: f32(0.1)
ZOOM_FIT_SCALE :: f32(0.6)
ZOOM_MIN :: f32(0.25)
ZOOM_MAX :: f32(3.0)

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
	size                = SMALL_SIZE,
	color               = COLOR_CYAN,
	underline           = true,
	strikethrough       = true,
	underline_color     = {1.0, 0.3, 0.3, 1.0},
	strikethrough_color = {1.0, 0.9, 0.3, 1.0},
}

// ===================================================
// Global state — sokol_app callbacks use this
// ===================================================

state: struct {
	renderer:      ^slug_sokol.Renderer,
	pass_action:   sg.Pass_Action,

	// Timing
	start_time:    time.Time,
	prev_elapsed:  f32,

	// Input tracking
	keys_held:     [512]bool,
	keys_pressed:  [512]bool, // rising edge, cleared each frame
	mouse_x:       f32,
	mouse_y:       f32,
	mouse_clicked: bool, // left button just pressed
	mid_held:      bool, // middle button held for camera drag
	prev_mouse_x:  f32,
	prev_mouse_y:  f32,
	scroll_accum:  f32,

	// Camera
	cam_x:         f32,
	cam_y:         f32,

	// Cursor demo
	cursor_text:   string,
	cursor_idx:    int,

	// Scroll region
	scroll_region: slug.Scroll_Region,

	// Message log
	msg_log:       slug.Message_Log,
	next_msg_time: f32,
	msg_index:     int,

	// Cached label
	cached_label:  slug.Text_Cache,

	// Custom transform callback state
	wave_state:    Wave_Hue_State,
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
	ws := (^Wave_Hue_State)(userdata)
	phase := f32(char_idx) * 0.7
	bob := math.sin(ws.time * 4.0 + phase) * 7.0
	hue := math.mod(ws.time * 90.0 + f32(char_idx) * 35.0, 360.0)
	rgb := slug.hsv_to_rgb(hue, 0.85, 1.0)
	return slug.Glyph_Xform{offset = {0, -bob}, color = {rgb.x, rgb.y, rgb.z, 1.0}}
}

// ===================================================
// Log messages
// ===================================================

LOG_MESSAGES :: [?]struct {
	text:  string,
	color: slug.Color,
}{
	{"You enter the dungeon.", {0.7, 0.7, 0.9, 1.0}},
	{"A goblin lunges from the shadows!", {1.0, 0.5, 0.3, 1.0}},
	{"You swing your sword for 12 damage.", {1.0, 0.9, 0.3, 1.0}},
	{"The goblin retaliates for 5 damage!", {1.0, 0.3, 0.3, 1.0}},
	{"You found a healing potion.", {0.3, 1.0, 0.5, 1.0}},
	{"The goblin collapses. +25 XP.", {0.5, 0.85, 1.0, 1.0}},
	{"You descend deeper into the crypt...", {0.7, 0.7, 0.9, 1.0}},
	{"A skeleton king awakens!", {1.0, 0.3, 0.3, 1.0}},
	{"Your sword glows with holy light.", {1.0, 0.9, 0.5, 1.0}},
	{"Critical hit! 48 damage!", {1.0, 1.0, 0.3, 1.0}},
	{"The crypt trembles...", {0.6, 0.4, 0.8, 1.0}},
	{"Victory! The skeleton king is vanquished.", {0.3, 1.0, 0.5, 1.0}},
}

SCROLL_TEXT :: "The ancient tome reveals: Long ago, the Skeleton King ruled these lands with an iron fist. His army of undead warriors swept across the countryside, destroying everything in their path. Only the legendary heroes of the Silver Order stood against him. After a great battle that lasted seven days and seven nights, the heroes sealed the Skeleton King in a crypt beneath the mountains. But the seal grows weak..."
WRAP_TEXT :: "The ancient scroll reads: You have defeated the Skeleton King and earned 250 gold. Your sword glows with newfound power."

// ===================================================
// Sokol App Callbacks
// ===================================================

init_cb :: proc "c" () {
	context = runtime.default_context()

	// Initialize Sokol GFX
	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})

	// Pass action: clear to dark background
	state.pass_action = {
		colors = {
			0 = {load_action = .CLEAR, clear_value = {0.08, 0.08, 0.12, 1.0}},
		},
	}

	// Initialize slug renderer
	state.renderer = slug_sokol.init()
	if state.renderer == nil {
		fmt.eprintln("Failed to initialize slug Sokol renderer")
		return
	}

	ctx := slug_sokol.ctx(state.renderer)

	// Load fonts + SVG icons into shared atlas
	{
		font0, font0_ok := slug.font_load(FONT_SANS)
		if !font0_ok {
			fmt.eprintln("Failed to load font:", FONT_SANS)
			return
		}
		slug.font_load_ascii(&font0)
		slug.font_load_range(&font0, 160, 255)
		slug.font_load_glyph(&font0, '☺') // CP437 smiley for grid demo
		slug.svg_load_into_font(&font0, ICON_SWORD, ICON_SWORD_PATH)
		slug.svg_load_into_font(&font0, ICON_HEART, ICON_HEART_PATH)
		slug.svg_load_into_font(&font0, ICON_SHIELD, ICON_SHIELD_PATH)
		slug.svg_load_into_font(&font0, ICON_CIRCLE, ICON_CIRCLE_PATH)
		slug.register_font(ctx, 0, font0)

		font1, font1_ok := slug.font_load(FONT_SERIF)
		if !font1_ok {
			fmt.eprintln("Failed to load font:", FONT_SERIF)
			return
		}
		slug.font_load_ascii(&font1)
		slug.font_load_range(&font1, 256, 383)
		slug.register_font(ctx, 1, font1)

		slug.font_set_fallback(ctx, 0, 1)

		pack := slug.fonts_process_shared(ctx)
		defer slug.pack_result_destroy(&pack)
		slug_sokol.upload_shared_textures(state.renderer, &pack)
	}

	ctx.weight_boost = true

	// Cache static text
	slug.begin(ctx)
	state.cached_label = slug.cache_text(
		ctx,
		"Crisp at any size (cached)",
		LEFT_X + PANEL_PAD,
		PANEL_CACHED_Y,
		SMALL_SIZE,
		COLOR_YELLOW,
	)

	// Init state
	state.cursor_text = "Click to position cursor"
	state.scroll_region = {
		x      = RIGHT_X,
		y      = SCROLL_Y,
		width  = SCROLL_W,
		height = SCROLL_H,
	}
	slug.log_init(&state.msg_log, LOG_FADE_TIME, LOG_FADE_DURATION, LOG_MAX_VISIBLE)
	state.next_msg_time = 1.0
	state.start_time = time.now()
}

frame_cb :: proc "c" () {
	context = runtime.default_context()

	ctx := slug_sokol.ctx(state.renderer)

	elapsed := f32(time.duration_seconds(time.since(state.start_time)))
	dt := elapsed - state.prev_elapsed
	state.prev_elapsed = elapsed

	fb_w := sapp.width()
	fb_h := sapp.height()

	// --- Input processing ---

	// UI scale — Up/Down hold, Tab toggle
	if state.keys_held[sapp.Keycode.UP] do slug.set_ui_scale(ctx, clamp(ctx.ui_scale + 0.01, ZOOM_MIN, ZOOM_MAX))
	if state.keys_held[sapp.Keycode.DOWN] do slug.set_ui_scale(ctx, clamp(ctx.ui_scale - 0.01, ZOOM_MIN, ZOOM_MAX))
	if state.keys_pressed[sapp.Keycode.TAB] {
		slug.set_ui_scale(ctx, ZOOM_FIT_SCALE if ctx.ui_scale != ZOOM_FIT_SCALE else 1.0)
	}

	// Camera pan — WASD
	if state.keys_held[sapp.Keycode.W] do state.cam_y -= CAMERA_SPEED * dt
	if state.keys_held[sapp.Keycode.S] do state.cam_y += CAMERA_SPEED * dt
	if state.keys_held[sapp.Keycode.A] do state.cam_x -= CAMERA_SPEED * dt
	if state.keys_held[sapp.Keycode.D] do state.cam_x += CAMERA_SPEED * dt

	// Camera pan — middle mouse drag
	if state.mid_held {
		state.cam_x += state.mouse_x - state.prev_mouse_x
		state.cam_y += state.mouse_y - state.prev_mouse_y
	}
	state.prev_mouse_x = state.mouse_x
	state.prev_mouse_y = state.mouse_y

	// Camera reset
	if state.keys_held[sapp.Keycode.R] {
		state.cam_x = 0
		state.cam_y = 0
	}

	// Cursor keyboard movement
	if state.keys_pressed[sapp.Keycode.LEFT] && state.cursor_idx > 0 do state.cursor_idx -= 1
	if state.keys_pressed[sapp.Keycode.RIGHT] && state.cursor_idx < len(state.cursor_text) do state.cursor_idx += 1

	// Click-to-position cursor
	if state.mouse_clicked {
		cursor_font := slug.active_font(ctx)
		if idx, hit := slug.text_hit_test(
			cursor_font,
			state.cursor_text,
			LEFT_X,
			ROW_CURSOR,
			SMALL_SIZE,
			state.mouse_x - state.cam_x,
			state.mouse_y - state.cam_y,
		); hit {
			state.cursor_idx = idx
		}
	}

	// Scroll region
	scroll_content_h, _ := slug.measure_text_wrapped(ctx, SCROLL_TEXT, SMALL_SIZE, state.scroll_region.width)
	world_mx := state.mouse_x - state.cam_x
	world_my := state.mouse_y - state.cam_y

	if state.scroll_accum != 0 {
		sr := &state.scroll_region
		if world_mx >= sr.x && world_mx <= sr.x + sr.width &&
		   world_my >= sr.y && world_my <= sr.y + sr.height {
			slug.scroll_by(sr, -state.scroll_accum * 20.0, scroll_content_h)
		} else {
			slug.set_ui_scale(ctx, clamp(ctx.ui_scale + state.scroll_accum * ZOOM_WHEEL_STEP, ZOOM_MIN, ZOOM_MAX))
		}
		state.scroll_accum = 0
	}

	// Push fake roguelike messages
	if elapsed >= state.next_msg_time {
		messages := LOG_MESSAGES
		m := messages[state.msg_index % len(LOG_MESSAGES)]
		slug.log_push(&state.msg_log, m.text, m.color, elapsed)
		state.msg_index += 1
		state.next_msg_time = elapsed + LOG_PUSH_INTERVAL
	}

	// Clear per-frame input
	state.mouse_clicked = false
	state.keys_pressed = {}

	// --- Render ---
	sg.begin_pass({action = state.pass_action, swapchain = sglue.swapchain()})

	slug.begin(ctx)
	slug.set_camera(ctx, state.cam_x, state.cam_y)

	// ---- Left column ----

	slug.draw_rect(ctx, f32(PANEL_X), f32(PANEL_Y), f32(PANEL_W), f32(PANEL_H), {0.16, 0.16, 0.24, 1.0})

	slug.draw_text_shadow(ctx, "Slug + Sokol", LEFT_X, ROW_TITLE, slug.scaled_size(ctx, TITLE_SIZE), COLOR_WHITE, shadow_offset = 2.0)
	slug.draw_text_outlined(ctx, "GPU Bezier text \u2014 Sokol GFX backend.", LEFT_X, ROW_SUBTITLE, slug.scaled_size(ctx, BODY_SIZE), COLOR_CYAN, outline_thickness = 2.5, outline_color = {0.8, 0.2, 0.8, 1.0})
	slug.draw_rich_text(ctx, "You deal {red:15} dmg with {icon:128:yellow}{yellow:Golden Sword}!", LEFT_X, ROW_RICH_TEXT, BODY_SIZE, COLOR_WHITE)
	slug.draw_text(ctx, "H\u00e9ros: \u00e9p\u00e9e, ch\u00e2teau, na\u00efve, \u00fcber, se\u00f1or", LEFT_X, ROW_UNICODE, SMALL_SIZE, {0.7, 0.7, 0.9, 1.0})
	slug.draw_text_highlighted(ctx, "SELECTED", LEFT_X, ROW_HIGHLIGHT, BODY_SIZE, slug.BLACK, {0.3, 0.6, 1.0, 1.0})
	slug.draw_rich_text(ctx, "Status: {bg:red:POISONED}  {bg:green:HASTE}  {bg:#884400:BURNING}", LEFT_X, ROW_STATUS, SMALL_SIZE, COLOR_WHITE)

	slug.use_font(ctx, 1)
	slug.draw_text(ctx, "This line uses Liberation Serif (font slot 1)", LEFT_X, ROW_SERIF, SMALL_SIZE, {0.9, 0.8, 0.6, 1.0})
	slug.use_font(ctx, 0)

	slug.draw_text_styled(ctx, "Underlined", LEFT_X, ROW_DECORATION, STYLE_UNDERLINE)
	slug.draw_text_styled(ctx, "Struck-out", LEFT_X + 158, ROW_DECORATION, STYLE_STRIKE)
	slug.draw_text_styled(ctx, "Both", LEFT_X + 316, ROW_DECORATION, STYLE_BOTH)

	font := slug.active_font(ctx)
	slug.draw_text(ctx, state.cursor_text, LEFT_X, ROW_CURSOR, SMALL_SIZE, {0.7, 0.9, 0.7, 1.0})
	cursor_px := slug.cursor_x_from_index(font, state.cursor_text, SMALL_SIZE, state.cursor_idx)
	if int(elapsed * 2) % 2 == 0 {
		slug.draw_text(ctx, "|", LEFT_X + cursor_px - 2, ROW_CURSOR, SMALL_SIZE, {0.8, 1.0, 0.8, 1.0})
	}
	slug.draw_text(ctx, fmt.tprintf("[</>] or click  idx:%d", state.cursor_idx), LEFT_X, ROW_CURSOR_HINT, 14, {0.5, 0.5, 0.5, 1.0})

	float_age := math.mod(elapsed, 1.5)
	slug.draw_text_float(ctx, "-15", FLOAT_X, FLOAT_Y, BODY_SIZE, {1.0, 0.3, 0.3, 1.0}, float_age, duration = 1.5)

	slug.draw_text_rainbow(ctx, "Rainbow on a panel!", LEFT_X + PANEL_PAD, PANEL_RAINBOW_Y, BODY_SIZE, time = elapsed)
	slug.draw_text_wobble(ctx, "Wobbly!", LEFT_X + PANEL_PAD, PANEL_WOBBLE_Y, BODY_SIZE, time = elapsed, amplitude = 5.0)
	slug.draw_cached(ctx, &state.cached_label)

	slug.use_font(ctx, 1)
	slug.draw_text(ctx, "Multi-font: Liberation Serif (slot 1)", LEFT_X, SERIF_LINE_Y, SMALL_SIZE, {0.9, 0.8, 0.6, 1.0})
	slug.use_font(ctx, 0)

	// Letter spacing (tracking)
	slug.draw_text(ctx, "W i d e  tracking", LEFT_X, ROW_TRACKING, SMALL_SIZE, {0.7, 0.8, 1.0, 1.0}, tracking = 4.0)

	// Tab stops
	slug.draw_text(ctx, "Name\tHP\tMP", LEFT_X, ROW_TABS, SMALL_SIZE, {0.7, 1.0, 0.7, 1.0})

	// ---- Center column ----

	slug.draw_icon(ctx, ICON_SWORD, ICONS_X, ICONS_Y, ICON_SIZE, COLOR_YELLOW)
	slug.draw_icon(ctx, ICON_HEART, ICONS_X + ICON_STRIDE, ICONS_Y, ICON_SIZE, {1.0, 0.3, 0.3, 1.0})
	slug.draw_icon(ctx, ICON_SHIELD, ICONS_X + ICON_STRIDE * 2, ICONS_Y, ICON_SIZE, {0.3, 0.8, 0.4, 1.0})
	slug.draw_icon(ctx, ICON_CIRCLE, ICONS_X + ICON_STRIDE * 3, ICONS_Y, ICON_SIZE, {0.5, 0.5, 1.0, 1.0})
	slug.draw_text(ctx, "SVG icons!", ICONS_X + ICON_STRIDE * 4 + 2, ICONS_Y - 10, SMALL_SIZE, COLOR_WHITE)

	slug.draw_text_gradient(ctx, "Gradient text!", FX_X, FX_GRADIENT_Y, BODY_SIZE, {1.0, 0.8, 0.2, 1.0}, {1.0, 0.2, 0.4, 1.0})
	slug.draw_text_pulse(ctx, "Pulsing!", FX_X, FX_PULSE_Y, BODY_SIZE, COLOR_CYAN, time = elapsed)
	fade_alpha := (math.sin(elapsed * 2.0) + 1.0) * 0.5
	slug.draw_text_fade(ctx, "Fading in and out...", FX_X, FX_FADE_Y, SMALL_SIZE, COLOR_WHITE, fade_alpha)

	state.wave_state = {elapsed}
	slug.draw_text_transformed(ctx, "Custom callback!", FX_X, FX_XFORM_Y, BODY_SIZE, COLOR_WHITE, wave_hue_xform, &state.wave_state)

	// Subscript / superscript
	{
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

	slug.draw_text_on_circle(ctx, "  text orbiting a circle  ", CIRCLE_CX, CIRCLE_CY, CIRCLE_R + 20, start_angle = -elapsed * 0.4, font_size = SMALL_SIZE, color = {0.8, 0.5, 1.0, 1.0})
	slug.draw_text_rotated(ctx, "Rotated", CIRCLE_CX, CIRCLE_CY, BODY_SIZE, elapsed * 0.6, COLOR_YELLOW)

	slug.draw_text(ctx, "Message Log:", LOG_X, LOG_Y - f32(LOG_MAX_VISIBLE) * 28 - 14, 13, {0.5, 0.5, 0.7, 1.0})
	slug.draw_message_log(ctx, &state.msg_log, LOG_X, LOG_Y, LOG_SIZE, elapsed)

	// ---- Right column ----

	pulse_size := 60.0 + math.sin(elapsed * 1.5) * 20.0
	slug.draw_text(ctx, "Zoom!", RIGHT_X + 10, ZOOM_Y, f32(pulse_size), {1.0, 0.5, 0.3, 1.0})

	slug.draw_text(ctx, "clip:", RIGHT_X + 10, TRUNCATE_Y - 18, 12, {0.4, 0.4, 0.5, 1.0})
	slug.draw_text_truncated(ctx, "This long name gets clipped with an ellipsis", RIGHT_X + 10, TRUNCATE_Y, SMALL_SIZE, TRUNCATE_MAX_W, COLOR_WHITE, ellipsis = " [...]")

	// Word-boundary truncation
	slug.draw_text_truncated_word(
		ctx,
		"Word-boundary truncation clips at spaces",
		RIGHT_X + 10,
		TRUNCATE_WORD_Y,
		SMALL_SIZE,
		TRUNCATE_MAX_W,
		{0.8, 0.8, 0.6, 1.0},
	)

	grid_cell_w := slug.mono_width(font, SMALL_SIZE)
	grid_cell_h := slug.line_height(font, SMALL_SIZE)
	slug.draw_text_grid(ctx, "##.@..g..##\n##..☺....##", RIGHT_X, GRID_Y, SMALL_SIZE, grid_cell_w, grid_cell_h, COLOR_CYAN)
	slug.draw_text(ctx, fmt.tprintf("cell: %.0fx%.0fpx", grid_cell_w, grid_cell_h), RIGHT_X, GRID_Y + grid_cell_h * 2 + 4, 13, {0.5, 0.5, 0.7, 1.0})

	slug.draw_text(ctx, "Left-aligned", ALIGN_X, ALIGN_Y0, SMALL_SIZE, {0.8, 0.6, 0.6, 1.0})
	slug.draw_text_centered(ctx, "Centered", ALIGN_X, ALIGN_Y1, SMALL_SIZE, {0.6, 0.6, 0.8, 1.0})
	slug.draw_text_right(ctx, "Right-aligned", ALIGN_X, ALIGN_Y2, SMALL_SIZE, {0.6, 0.8, 0.6, 1.0})

	slug.draw_text(ctx, "Fallback: \u015e \u017e \u0150 \u0119 \u013a (font 0 \u2192 serif)", RIGHT_X, FALLBACK_Y, SMALL_SIZE, {0.7, 0.9, 0.7, 1.0})
	slug.draw_text_justified(ctx, "Word justification fills the column width exactly.", RIGHT_X, JUSTIFY_Y, SMALL_SIZE, JUSTIFY_W, {0.9, 0.8, 0.6, 1.0})

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

	slug.draw_text_wrapped(ctx, WRAP_TEXT, RIGHT_X + WRAP_PAD, WRAP_Y + WRAP_PAD, SMALL_SIZE, WRAP_W - WRAP_PAD * 2, COLOR_WHITE, line_spacing = 1.4)

	slug.draw_rect(ctx, state.scroll_region.x, state.scroll_region.y, state.scroll_region.width, state.scroll_region.height, {0.12, 0.12, 0.20, 1.0})
	slug.draw_text_scrolled(ctx, SCROLL_TEXT, &state.scroll_region, SMALL_SIZE, {0.8, 0.8, 0.9, 1.0})
	slug.draw_text(ctx, "Scroll me! [wheel]", state.scroll_region.x, state.scroll_region.y - 18, 14, {0.5, 0.5, 0.7, 1.0})

	slug.draw_rect(ctx, CLIP_BOX_X, CLIP_BOX_Y, CLIP_BOX_W, CLIP_BOX_H, {0.08, 0.14, 0.22, 1.0})
	slug.draw_text(ctx, "GPU scissor:", CLIP_BOX_X, CLIP_LABEL_Y, 13, {0.5, 0.5, 0.7, 1.0})

	// ---- Bottom section: UI widget demos ----

	// Bordered panel with rect outline
	slug.draw_rect_bordered(
		ctx,
		UI_PANEL_X, UI_PANEL_Y, UI_PANEL_W, UI_PANEL_H,
		{0.1, 0.1, 0.18, 1.0},
		{0.4, 0.4, 0.7, 1.0},
		border = 2,
	)
	slug.draw_text(ctx, "Bordered Panel", UI_PANEL_X + 15, UI_PANEL_Y + 26, SMALL_SIZE, COLOR_WHITE)

	// Progress bars inside panel
	hp := f32(72.0 + math.sin(elapsed * 0.5) * 28.0)
	slug.draw_bar(
		ctx,
		BAR_X, BAR_Y, BAR_W, BAR_H,
		hp, 100,
		{0.2, 0.8, 0.3, 1.0},
		{0.15, 0.15, 0.25, 1.0},
		label = fmt.tprintf("HP %d/100", int(hp)),
		label_size = 14,
		label_color = COLOR_WHITE,
		border_color = {0.4, 0.6, 0.4, 1.0},
		border = 1,
	)
	mp := f32(35.0 + math.sin(elapsed * 0.7) * 15.0)
	slug.draw_bar(
		ctx,
		BAR_X, BAR_Y + 30, BAR_W, BAR_H,
		mp, 80,
		{0.3, 0.4, 0.9, 1.0},
		{0.15, 0.15, 0.25, 1.0},
		label = fmt.tprintf("MP %d/80", int(mp)),
		label_size = 14,
		border_color = {0.3, 0.4, 0.7, 1.0},
		border = 1,
	)

	// Rect outline demo
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

	// Blinking cursor demo
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
		fmt.tprintf("Scale: %.2fx [Up/Down/Wheel/Tab]  Cam: %.0f,%.0f [WASD/MMB  R=reset]", ctx.ui_scale, state.cam_x, state.cam_y),
		10,
		SCALE_Y,
		16,
		{0.5, 0.5, 0.5, 1.0},
	)

	slug.end(ctx)
	slug_sokol.flush(state.renderer, fb_w, fb_h)

	// Pass 2: clipped panel text — scissor follows canvas pan
	slug.begin(ctx)
	slug.use_font(ctx, 0)
	slug.set_camera(ctx, state.cam_x, state.cam_y)
	slug.draw_text(ctx, "GPU-clipped panel text overflows \u2192", CLIP_BOX_X + 5, CLIP_TEXT_Y, SMALL_SIZE, COLOR_WHITE)
	slug.end(ctx)
	slug_sokol.flush(
		state.renderer,
		fb_w,
		fb_h,
		scissor = slug.Scissor_Rect{
			x = CLIP_BOX_X + state.cam_x,
			y = CLIP_BOX_Y + state.cam_y,
			w = CLIP_BOX_W,
			h = CLIP_BOX_H,
		},
	)

	sg.end_pass()
	sg.commit()
}

event_cb :: proc "c" (event: ^sapp.Event) {
	context = runtime.default_context()

	#partial switch event.type {
	case .KEY_DOWN:
		kc := int(event.key_code)
		if kc >= 0 && kc < len(state.keys_held) {
			if !state.keys_held[kc] {
				state.keys_pressed[kc] = true
			}
			state.keys_held[kc] = true
		}
		if event.key_code == .ESCAPE {
			sapp.request_quit()
		}
	case .KEY_UP:
		kc := int(event.key_code)
		if kc >= 0 && kc < len(state.keys_held) {
			state.keys_held[kc] = false
		}
	case .MOUSE_DOWN:
		if event.mouse_button == .LEFT {
			state.mouse_clicked = true
		}
		if event.mouse_button == .MIDDLE {
			state.mid_held = true
		}
	case .MOUSE_UP:
		if event.mouse_button == .MIDDLE {
			state.mid_held = false
		}
	case .MOUSE_MOVE:
		state.mouse_x = event.mouse_x
		state.mouse_y = event.mouse_y
	case .MOUSE_SCROLL:
		state.scroll_accum += event.scroll_y
	}
}

cleanup_cb :: proc "c" () {
	context = runtime.default_context()
	slug.cache_destroy(&state.cached_label)
	slug_sokol.destroy(state.renderer)
	sg.shutdown()
}

// ===================================================
// Entry point
// ===================================================

main :: proc() {
	sapp.run({
		init_cb = init_cb,
		frame_cb = frame_cb,
		cleanup_cb = cleanup_cb,
		event_cb = event_cb,
		width = WINDOW_WIDTH,
		height = WINDOW_HEIGHT,
		window_title = WINDOW_TITLE,
		icon = {sokol_default = true},
		logger = {func = slog.func},
	})
}
