package main

// ===================================================
// odin-slug Vulkan Demo
//
// Standalone example showing GPU-accelerated Bezier text rendering
// using odin-slug with a Vulkan backend. Uses SDL3 for windowing.
//
// Build:
//   1. Compile shaders: ./build.sh shaders
//   2. Build demo:      ./build.sh vulkan
// Run:    ./demo_vulkan
//
// Prerequisites:
//   - Liberation fonts in examples/assets/fonts/
//   - Vulkan SDK + SDL3
//   - Compiled SPIR-V shaders in slug/shaders/
// ===================================================

import "core:fmt"

import sdl "vendor:sdl3"

import slug "../../slug"
import slug_vk "../../slug/backends/vulkan"

// --- Window constants ---

WINDOW_TITLE :: "odin-slug Vulkan Demo"
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

// --- Font paths (relative to working directory) ---

FONT_SANS :: "examples/assets/fonts/LiberationSans-Regular.ttf"
FONT_MONO :: "examples/assets/fonts/LiberationMono-Regular.ttf"

// --- SVG icon paths and glyph slots ---

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
CIRCLE_CX :: 900.0
CIRCLE_CY :: 400.0

// --- Colors ---

COLOR_WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.3, 1.0}
COLOR_CYAN :: [4]f32{0.3, 0.9, 1.0, 1.0}
COLOR_GREEN :: [4]f32{0.4, 1.0, 0.5, 1.0}
COLOR_MAGENTA :: [4]f32{1.0, 0.4, 0.8, 1.0}

main :: proc() {
	// -----------------------------------------------
	// 1. Initialize SDL3 and create a Vulkan window
	// -----------------------------------------------

	if !sdl.Init({.VIDEO, .EVENTS}) {
		fmt.eprintln("Failed to initialize SDL3:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow(WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT, {.VULKAN, .RESIZABLE})
	if window == nil {
		fmt.eprintln("Failed to create SDL3 window:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// -----------------------------------------------
	// 2. Initialize the slug Vulkan renderer
	// -----------------------------------------------

	renderer := new(slug_vk.Renderer)
	defer free(renderer)

	renderer.zoom = 1.0

	if !slug_vk.init(renderer, window) {
		fmt.eprintln("Failed to initialize Vulkan renderer")
		return
	}
	defer slug_vk.destroy(renderer)

	// -----------------------------------------------
	// 3. Load fonts
	// -----------------------------------------------

	// Slot 0: Sans + SVG icons (manual pipeline — icons must load before process_font)
	{
		font, font_ok := slug.font_load(FONT_SANS)
		if !font_ok {
			fmt.eprintln("Failed to load sans font")
			return
		}
		slug.font_load_ascii(&font)
		slug.svg_load_into_font(&font, ICON_SWORD, ICON_SWORD_PATH)
		slug.svg_load_into_font(&font, ICON_HEART, ICON_HEART_PATH)
		slug.svg_load_into_font(&font, ICON_MEGAPHONE, ICON_MEGAPHONE_PATH)

		pack := slug.font_process(&font)
		defer slug.pack_result_destroy(&pack)

		renderer.ctx.fonts[0] = font
		renderer.ctx.font_loaded[0] = true
		renderer.ctx.font_count = 1
		slug_vk.upload_font_textures(renderer, 0, &pack, "Sans")
	}

	// Slot 1: Monospace (convenience load — no icons)
	if !slug_vk.load_font(renderer, 1, FONT_MONO, "Mono") {
		fmt.eprintln("Failed to load mono font")
		return
	}

	fmt.println("Vulkan renderer ready. Entering main loop.")

	// -----------------------------------------------
	// 4. Main loop
	// -----------------------------------------------

	running := true
	start_ticks := sdl.GetPerformanceCounter()
	freq := f64(sdl.GetPerformanceFrequency())

	for running {
		// Poll events
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.key == sdl.K_ESCAPE {
					running = false
				}
			case .WINDOW_RESIZED:
				renderer.framebuffer_resized = true
			}
		}

		// Elapsed time for animations
		now := sdl.GetPerformanceCounter()
		elapsed := f32(f64(now - start_ticks) / freq)

		// --- Begin frame ---
		slug_vk.begin_frame(renderer)

		// -- Title with drop shadow --
		y := f32(TOP_START)

		slug.draw_text_shadow(
			&renderer.ctx,
			"odin-slug: Vulkan Backend",
			LEFT_MARGIN,
			y,
			TITLE_SIZE,
			COLOR_WHITE,
			shadow_offset = 3.0,
		)
		y += LINE_SPACING * 1.4

		slug.draw_text(
			&renderer.ctx,
			"Resolution-independent GPU Bezier text.",
			LEFT_MARGIN,
			y,
			BODY_SIZE,
			COLOR_CYAN,
		)
		y += LINE_SPACING

		// -- Rainbow text --
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

		// -- Wobble text --
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

		// -- Shake text --
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

		// -- Wave text --
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

		// -- Rotated text --
		slug.draw_text_rotated(
			&renderer.ctx,
			"Rotated!",
			CIRCLE_CX,
			CIRCLE_CY - CIRCLE_RADIUS - 40,
			BODY_SIZE,
			elapsed * 0.5,
			COLOR_YELLOW,
		)

		// -- Circular text --
		slug.draw_text_on_circle(
			&renderer.ctx,
			"  text curving around a circle  ",
			CIRCLE_CX,
			CIRCLE_CY,
			CIRCLE_RADIUS,
			start_angle = -elapsed * 0.3,
			font_size = SMALL_SIZE,
			color = COLOR_MAGENTA,
		)

		// -- Typewriter --
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
		slug_vk.use_font(renderer, 1)

		slug.draw_text(
			&renderer.ctx,
			"Monospace font slot 1: fn main() {}",
			LEFT_MARGIN,
			y,
			SMALL_SIZE,
			COLOR_GREEN,
		)

		// --- End frame and draw ---
		slug_vk.end_frame(renderer)

		if !slug_vk.draw_frame(renderer) {
			fmt.eprintln("Draw frame failed")
			break
		}
	}

	fmt.println("Vulkan demo exiting.")
}
