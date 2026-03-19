package main

// ===================================================
// odin-slug OpenGL Demo
//
// Standalone example showing GPU-accelerated Bezier text rendering
// using odin-slug with an OpenGL 3.3 backend. Uses GLFW for windowing.
//
// Build:  odin build examples/demo_opengl -out:demo_opengl
// Run:    ./demo_opengl
//
// Prerequisites:
//   - Liberation fonts in examples/assets/fonts/
//   - OpenGL 3.3+ capable GPU
// ===================================================

import "core:fmt"
import "core:time"

import gl "vendor:OpenGL"
import "vendor:glfw"

import slug "../../slug"
import slug_gl "../../slug/backends/opengl"

// --- Window constants ---

WINDOW_TITLE :: "odin-slug OpenGL Demo"
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

// --- Font paths (relative to working directory) ---

FONT_SANS :: "examples/assets/fonts/LiberationSans-Regular.ttf"
FONT_SERIF :: "examples/assets/fonts/LiberationSerif-Regular.ttf"
FONT_MONO :: "examples/assets/fonts/LiberationMono-Regular.ttf"

// --- SVG icon paths and glyph slots ---
// Icons are loaded into glyph slots 128+ (outside ASCII range).

ICON_SWORD :: 128
ICON_HEART :: 129
ICON_MEGAPHONE :: 130

ICON_SWORD_PATH :: "examples/assets/icons/sword.svg"
ICON_HEART_PATH :: "examples/assets/icons/heart.svg"
ICON_MEGAPHONE_PATH :: "examples/assets/icons/megaphone.svg"

// --- Text layout constants ---

TITLE_SIZE :: 48.0
BODY_SIZE :: 28.0
SMALL_SIZE :: 20.0
ICON_SIZE :: 48.0
LEFT_MARGIN :: 40.0
TOP_START :: 80.0
LINE_SPACING :: 50.0
CIRCLE_RADIUS :: 120.0
CIRCLE_CENTER_X :: 900.0
CIRCLE_CENTER_Y :: 400.0

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}
COLOR_GREEN :: [4]f32{0.4, 1.0, 0.5, 1.0}
COLOR_MAGENTA :: [4]f32{1.0, 0.4, 0.8, 1.0}

main :: proc() {
	// -----------------------------------------------
	// 1. Create a window and OpenGL context with GLFW
	// -----------------------------------------------

	if !glfw.Init() {
		fmt.eprintln("Failed to initialize GLFW")
		return
	}
	defer glfw.Terminate()

	// Request OpenGL 3.3 core profile — the minimum for odin-slug's shaders.
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
	glfw.SwapInterval(1) // vsync

	// Load OpenGL function pointers. GLFW provides the loader proc.
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	// -----------------------------------------------
	// 2. Initialize the slug OpenGL renderer
	// -----------------------------------------------
	//
	// The renderer wraps a slug.Context and adds GL-specific state:
	// shader program, textures, VAO/VBO/EBO. One renderer per GL context.

	renderer := new(slug_gl.Renderer)
	if !slug_gl.init(renderer) {
		fmt.eprintln("Failed to initialize slug GL renderer")
		return
	}
	defer {
		slug_gl.destroy(renderer)
		free(renderer)
	}

	// -----------------------------------------------
	// 3. Load fonts and SVG icons
	// -----------------------------------------------
	//
	// Each font occupies a "slot" (0 to MAX_FONT_SLOTS-1). SVG icons are
	// loaded into glyph slots 128+ on a font, then processed together.
	//
	// SVG icons must be loaded BEFORE font_process() is called, so we use
	// the manual pipeline for slot 0 (which has icons). Slot 1 uses the
	// convenience load_font() since it has no icons.

	// Slot 0: Sans-serif + SVG icons (manual pipeline)
	{
		font, font_ok := slug.font_load(FONT_SANS)
		if !font_ok {
			fmt.eprintln("Failed to load sans font")
			return
		}
		slug.font_load_ascii(&font)

		// Load SVG icons into glyph slots 128+.
		// These get packed into the same GPU textures as the font glyphs.
		slug.svg_load_into_font(&font, ICON_SWORD, ICON_SWORD_PATH)
		slug.svg_load_into_font(&font, ICON_HEART, ICON_HEART_PATH)
		slug.svg_load_into_font(&font, ICON_MEGAPHONE, ICON_MEGAPHONE_PATH)

		pack := slug.font_process(&font)
		defer slug.pack_result_destroy(&pack)

		slug.register_font(&renderer.ctx, 0, font)
		slug_gl.upload_font_textures(renderer, 0, &pack)
	}

	// Slot 1: Monospace (convenience load — no icons needed)
	if !slug_gl.load_font(renderer, 1, FONT_MONO) {
		fmt.eprintln("Failed to load mono font")
		return
	}

	fmt.println("Fonts loaded and uploaded. Entering render loop.")

	// -----------------------------------------------
	// 4. Main render loop
	// -----------------------------------------------

	start_time := time.now()

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()

		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(window, true)
		}

		// Elapsed time drives animated effects (rainbow, wobble, etc.)
		elapsed := f32(time.duration_seconds(time.since(start_time)))

		// Get current framebuffer size (handles DPI scaling / window resize)
		fb_w, fb_h := glfw.GetFramebufferSize(window)
		gl.Viewport(0, 0, fb_w, fb_h)

		// Clear to dark background
		gl.ClearColor(0.08, 0.08, 0.12, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		// --- Begin slug frame ---
		// Resets the internal quad counter. All draw_text / draw_text_* calls
		// between begin() and end() write glyph quads into the CPU vertex buffer.
		slug.begin(&renderer.ctx)

		// -- Static text (white, default font slot 0) --
		y := f32(TOP_START)

		slug.draw_text_shadow(
			&renderer.ctx,
			"odin-slug: GPU Bezier Text",
			LEFT_MARGIN,
			y,
			TITLE_SIZE,
			COLOR_WHITE,
			shadow_offset = 3.0,
		)
		y += LINE_SPACING * 1.4

		slug.draw_text(
			&renderer.ctx,
			"Resolution-independent text at any size or rotation.",
			LEFT_MARGIN,
			y,
			BODY_SIZE,
			COLOR_CYAN,
		)
		y += LINE_SPACING

		// -- Rainbow text (animated hue cycling) --
		slug.draw_text_rainbow(
			&renderer.ctx,
			"Rainbow text with per-character hue!",
			LEFT_MARGIN,
			y,
			BODY_SIZE,
			time = elapsed,
			speed = 100.0,
			spread = 30.0,
		)
		y += LINE_SPACING

		// -- Wobble text (animated vertical sine wave) --
		slug.draw_text_wobble(
			&renderer.ctx,
			"Wobbly bouncing letters~",
			LEFT_MARGIN,
			y,
			BODY_SIZE,
			time = elapsed,
			amplitude = 6.0,
			frequency = 4.0,
		)
		y += LINE_SPACING

		// -- Shake text (pseudo-random jitter) --
		slug.draw_text_shake(
			&renderer.ctx,
			"DANGER! Shaking text!",
			LEFT_MARGIN,
			y,
			BODY_SIZE,
			intensity = 2.5,
			time = elapsed,
			color = {1.0, 0.3, 0.2, 1.0},
		)
		y += LINE_SPACING

		// -- Wave text (characters follow a sine path) --
		slug.draw_text_on_wave(
			&renderer.ctx,
			"Text flowing on a wave path",
			LEFT_MARGIN,
			y + 20,
			SMALL_SIZE,
			amplitude = 12.0,
			wavelength = 250.0,
			phase = elapsed * 2.0,
			color = COLOR_GREEN,
		)
		y += LINE_SPACING * 1.5

		// -- Rotated text (arbitrary angle) --
		angle := elapsed * 0.5 // slow rotation
		slug.draw_text_rotated(
			&renderer.ctx,
			"Rotated!",
			CIRCLE_CENTER_X,
			CIRCLE_CENTER_Y - CIRCLE_RADIUS - 40,
			BODY_SIZE,
			angle,
			COLOR_YELLOW,
		)

		// -- Circular text (characters along a circle) --
		slug.draw_text_on_circle(
			&renderer.ctx,
			"  text curving around a circle  ",
			CIRCLE_CENTER_X,
			CIRCLE_CENTER_Y,
			CIRCLE_RADIUS,
			start_angle = -elapsed * 0.3,
			font_size = SMALL_SIZE,
			color = COLOR_MAGENTA,
		)

		// -- Typewriter reveal --
		slug.draw_text_typewriter(
			&renderer.ctx,
			"Typewriter effect reveals one character at a time...",
			LEFT_MARGIN,
			y,
			BODY_SIZE,
			COLOR_WHITE,
			time = elapsed,
			chars_per_sec = 8.0,
		)
		y += LINE_SPACING

		// -- SVG icons (same GPU pipeline as text) --
		icon_x := f32(LEFT_MARGIN)
		slug.draw_icon(&renderer.ctx, ICON_SWORD, icon_x, y + 24, ICON_SIZE, COLOR_YELLOW)
		icon_x += ICON_SIZE + 16
		slug.draw_icon(&renderer.ctx, ICON_HEART, icon_x, y + 24, ICON_SIZE, {1.0, 0.3, 0.3, 1.0})
		icon_x += ICON_SIZE + 16
		slug.draw_icon(&renderer.ctx, ICON_MEGAPHONE, icon_x, y + 24, ICON_SIZE, COLOR_CYAN)
		icon_x += ICON_SIZE + 16
		slug.draw_text(
			&renderer.ctx,
			"SVG icons in the same pipeline",
			icon_x,
			y,
			SMALL_SIZE,
			COLOR_WHITE,
		)
		y += LINE_SPACING * 1.2

		// -- Switch to monospace font (slot 1) --
		slug.use_font(&renderer.ctx, 1)

		slug.draw_text(
			&renderer.ctx,
			"Monospace font slot 1: fn main() {}",
			LEFT_MARGIN,
			y,
			SMALL_SIZE,
			COLOR_GREEN,
		)

		// --- End slug frame ---
		// Finalizes the per-font quad ranges so the backend knows how many
		// quads to draw for each font's texture set.
		slug.end(&renderer.ctx)

		// --- Flush to GPU ---
		// Uploads the CPU vertex buffer, binds the slug shader + textures,
		// and issues one draw call per active font slot.
		slug_gl.flush(renderer, fb_w, fb_h)

		glfw.SwapBuffers(window)
	}

	fmt.println("Demo exiting.")
}
