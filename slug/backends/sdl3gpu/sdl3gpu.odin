package slug_sdl3gpu

// ===================================================
// SDL3 GPU Backend for odin-slug
//
// Cross-platform GPU backend using SDL3's GPU API abstraction.
// Supports Vulkan (Linux/Windows), D3D12 (Windows), and Metal (macOS)
// through SDL3's internal backend selection.
//
// Reuses the existing SPIR-V shaders compiled for the Vulkan backend.
// For cross-platform shader support (D3D12/Metal), use SDL_shadercross
// or provide additional bytecode formats at build time.
//
// Rendering pipeline per frame:
//   1. begin_frame()   — acquire command buffer + swapchain texture
//   2. (caller emits quads via slug.draw_text / slug.emit_glyph_quad on r.ctx)
//   3. flush()         — copy pass (upload vertices) + render pass (draw)
//   4. present_frame() — submit command buffer
//
// Key difference from Vulkan backend: SDL3 GPU strictly separates copy
// passes and render passes. Each flush creates a copy pass to upload
// vertices, then a render pass to draw. Multi-flush frames use CLEAR
// on the first pass and LOAD on subsequent passes to preserve output.
// ===================================================

import "core:c"
import "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"

import slug "../.."

// --- Push constant layout (must match vertex shader) ---
Push_Constants :: struct {
	mvp:      matrix[4, 4]f32, // 64 bytes
	viewport: [2]f32, // 8 bytes
}

// --- Per-font GPU textures ---
Font_GPU :: struct {
	curve_texture: ^sdl.GPUTexture,
	band_texture:  ^sdl.GPUTexture,
	loaded:        bool,
}

// --- Renderer ---
Renderer :: struct {
	// Core slug context (CPU-side fonts, vertices, quad tracking)
	ctx:             slug.Context,

	// SDL3 GPU handles
	device:          ^sdl.GPUDevice,
	window:          ^sdl.Window,

	// Pipelines
	slug_pipeline:   ^sdl.GPUGraphicsPipeline,
	rect_pipeline:   ^sdl.GPUGraphicsPipeline,

	// Shared sampler (nearest/clamp for both curve and band textures)
	sampler:         ^sdl.GPUSampler,

	// Slug vertex/index buffers (GPU-side)
	vertex_buffer:   ^sdl.GPUBuffer,
	index_buffer:    ^sdl.GPUBuffer,

	// Rect vertex/index buffers (GPU-side)
	rect_vb:         ^sdl.GPUBuffer,
	rect_ib:         ^sdl.GPUBuffer,

	// Transfer buffers (CPU-visible staging, reused each frame)
	transfer_buffer: ^sdl.GPUTransferBuffer,
	rect_transfer:   ^sdl.GPUTransferBuffer,

	// Per-frame state (valid between begin_frame and present_frame)
	cmd:             ^sdl.GPUCommandBuffer,
	swapchain_tex:   ^sdl.GPUTexture,
	swapchain_w:     u32,
	swapchain_h:     u32,
	first_flush:     bool,

	// Per-font GPU textures (unused in shared atlas mode)
	font_gpu:        [slug.MAX_FONT_SLOTS]Font_GPU,

	// Shared atlas GPU textures (used when ctx.shared_atlas is true)
	shared_gpu:      Font_GPU,
}

// --- Public API ---

// SPIR-V bytecode embedded at compile time.
// SDL3 GPU uses UBO-based uniforms, not push constants, so these are
// SDL3-specific shader variants (slug_sdl3_*.spv / rect_sdl3_*.spv).
// The rect fragment shader has no uniforms/samplers and is shared with Vulkan.
VERT_SHADER_CODE :: #load("../../shaders/slug_sdl3_vert.spv")
FRAG_SHADER_CODE :: #load("../../shaders/slug_sdl3_frag.spv")
RECT_VERT_SHADER_CODE :: #load("../../shaders/rect_sdl3_vert.spv")
RECT_FRAG_SHADER_CODE :: #load("../../shaders/rect_frag.spv")

// Create and initialize the SDL3 GPU renderer.
// The caller owns the device — init does NOT create or destroy it.
// Call after sdl.ClaimWindowForGPUDevice.
// Returns nil if any setup step fails. Caller must call destroy() to free.
init :: proc(window: ^sdl.Window, device: ^sdl.GPUDevice) -> ^Renderer {
	r, alloc_err := new(Renderer)
	if alloc_err != .None do return nil
	r.device = device
	r.window = window

	swapchain_format := sdl.GetGPUSwapchainTextureFormat(device, window)

	// --- Create shaders ---
	slug_vert := sdl.CreateGPUShader(device, sdl.GPUShaderCreateInfo{
		code_size           = len(VERT_SHADER_CODE),
		code                = raw_data(VERT_SHADER_CODE),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	})
	if slug_vert == nil { free(r); return nil }

	slug_frag := sdl.CreateGPUShader(device, sdl.GPUShaderCreateInfo{
		code_size           = len(FRAG_SHADER_CODE),
		code                = raw_data(FRAG_SHADER_CODE),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .FRAGMENT,
		num_samplers        = 2,
		num_uniform_buffers = 1,
	})
	if slug_frag == nil {
		sdl.ReleaseGPUShader(device, slug_vert)
		free(r)
		return nil
	}

	rect_vert := sdl.CreateGPUShader(device, sdl.GPUShaderCreateInfo{
		code_size           = len(RECT_VERT_SHADER_CODE),
		code                = raw_data(RECT_VERT_SHADER_CODE),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	})
	if rect_vert == nil {
		sdl.ReleaseGPUShader(device, slug_frag)
		sdl.ReleaseGPUShader(device, slug_vert)
		free(r)
		return nil
	}

	rect_frag := sdl.CreateGPUShader(device, sdl.GPUShaderCreateInfo{
		code_size  = len(RECT_FRAG_SHADER_CODE),
		code       = raw_data(RECT_FRAG_SHADER_CODE),
		entrypoint = "main",
		format     = {.SPIRV},
		stage      = .FRAGMENT,
	})
	if rect_frag == nil {
		sdl.ReleaseGPUShader(device, rect_vert)
		sdl.ReleaseGPUShader(device, slug_frag)
		sdl.ReleaseGPUShader(device, slug_vert)
		free(r)
		return nil
	}

	// --- Blend state (standard alpha blending) ---
	blend_state := sdl.GPUColorTargetBlendState{
		enable_blend          = true,
		src_color_blendfactor = .SRC_ALPHA,
		dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
		color_blend_op        = .ADD,
		src_alpha_blendfactor = .SRC_ALPHA,
		dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
		alpha_blend_op        = .ADD,
	}

	color_target_desc := sdl.GPUColorTargetDescription{
		format      = swapchain_format,
		blend_state = blend_state,
	}

	// --- Slug pipeline (5x vec4, stride 80 bytes) ---
	slug_vertex_attrs := [5]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT4, offset = 0},   // pos
		{location = 1, buffer_slot = 0, format = .FLOAT4, offset = 16},  // tex
		{location = 2, buffer_slot = 0, format = .FLOAT4, offset = 32},  // jac
		{location = 3, buffer_slot = 0, format = .FLOAT4, offset = 48},  // bnd
		{location = 4, buffer_slot = 0, format = .FLOAT4, offset = 64},  // col
	}
	slug_vb_desc := sdl.GPUVertexBufferDescription{
		slot       = 0,
		pitch      = size_of(slug.Vertex), // 80
		input_rate = .VERTEX,
	}

	r.slug_pipeline = sdl.CreateGPUGraphicsPipeline(device, sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = slug_vert,
		fragment_shader = slug_frag,
		vertex_input_state = sdl.GPUVertexInputState{
			vertex_buffer_descriptions = &slug_vb_desc,
			num_vertex_buffers         = 1,
			vertex_attributes          = raw_data(slug_vertex_attrs[:]),
			num_vertex_attributes      = 5,
		},
		primitive_type   = .TRIANGLELIST,
		rasterizer_state = sdl.GPURasterizerState{
			fill_mode  = .FILL,
			cull_mode  = .NONE,
			front_face = .COUNTER_CLOCKWISE,
		},
		target_info = sdl.GPUGraphicsPipelineTargetInfo{
			color_target_descriptions = &color_target_desc,
			num_color_targets         = 1,
		},
	})
	if r.slug_pipeline == nil {
		sdl.ReleaseGPUShader(device, rect_frag)
		sdl.ReleaseGPUShader(device, rect_vert)
		sdl.ReleaseGPUShader(device, slug_frag)
		sdl.ReleaseGPUShader(device, slug_vert)
		free(r)
		return nil
	}

	// --- Rect pipeline (vec2 pos + vec4 col, stride 24 bytes) ---
	rect_vertex_attrs := [2]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = 0},  // pos
		{location = 1, buffer_slot = 0, format = .FLOAT4, offset = 8},  // col
	}
	rect_vb_desc := sdl.GPUVertexBufferDescription{
		slot       = 0,
		pitch      = size_of(slug.Rect_Vertex), // 24
		input_rate = .VERTEX,
	}

	r.rect_pipeline = sdl.CreateGPUGraphicsPipeline(device, sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = rect_vert,
		fragment_shader = rect_frag,
		vertex_input_state = sdl.GPUVertexInputState{
			vertex_buffer_descriptions = &rect_vb_desc,
			num_vertex_buffers         = 1,
			vertex_attributes          = raw_data(rect_vertex_attrs[:]),
			num_vertex_attributes      = 2,
		},
		primitive_type   = .TRIANGLELIST,
		rasterizer_state = sdl.GPURasterizerState{
			fill_mode  = .FILL,
			cull_mode  = .NONE,
			front_face = .COUNTER_CLOCKWISE,
		},
		target_info = sdl.GPUGraphicsPipelineTargetInfo{
			color_target_descriptions = &color_target_desc,
			num_color_targets         = 1,
		},
	})
	if r.rect_pipeline == nil {
		sdl.ReleaseGPUShader(device, rect_frag)
		sdl.ReleaseGPUShader(device, rect_vert)
		sdl.ReleaseGPUShader(device, slug_frag)
		sdl.ReleaseGPUShader(device, slug_vert)
		destroy(r)
		return nil
	}

	// Shaders are baked into the pipelines — safe to release
	sdl.ReleaseGPUShader(device, rect_frag)
	sdl.ReleaseGPUShader(device, rect_vert)
	sdl.ReleaseGPUShader(device, slug_frag)
	sdl.ReleaseGPUShader(device, slug_vert)

	// --- Sampler (nearest/clamp for texelFetch-based curve and band textures) ---
	r.sampler = sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{
		min_filter     = .NEAREST,
		mag_filter     = .NEAREST,
		mipmap_mode    = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	})
	if r.sampler == nil { destroy(r); return nil }

	// --- GPU buffers ---

	// Slug vertex buffer (overwritten each frame via transfer buffer)
	r.vertex_buffer = sdl.CreateGPUBuffer(device, sdl.GPUBufferCreateInfo{
		usage = {.VERTEX},
		size  = u32(slug.MAX_GLYPH_VERTICES * size_of(slug.Vertex)),
	})
	if r.vertex_buffer == nil { destroy(r); return nil }

	// Slug index buffer (static, uploaded once)
	r.index_buffer = sdl.CreateGPUBuffer(device, sdl.GPUBufferCreateInfo{
		usage = {.INDEX},
		size  = u32(slug.MAX_GLYPH_INDICES * size_of(u32)),
	})
	if r.index_buffer == nil { destroy(r); return nil }

	// Rect vertex buffer
	r.rect_vb = sdl.CreateGPUBuffer(device, sdl.GPUBufferCreateInfo{
		usage = {.VERTEX},
		size  = u32(slug.MAX_RECTS * slug.VERTICES_PER_QUAD * size_of(slug.Rect_Vertex)),
	})
	if r.rect_vb == nil { destroy(r); return nil }

	// Rect index buffer (static, uploaded once)
	r.rect_ib = sdl.CreateGPUBuffer(device, sdl.GPUBufferCreateInfo{
		usage = {.INDEX},
		size  = u32(slug.MAX_RECTS * slug.INDICES_PER_QUAD * size_of(u32)),
	})
	if r.rect_ib == nil { destroy(r); return nil }

	// --- Transfer buffers (CPU-visible staging, reused each frame) ---
	r.transfer_buffer = sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(slug.MAX_GLYPH_VERTICES * size_of(slug.Vertex)),
	})
	if r.transfer_buffer == nil { destroy(r); return nil }

	r.rect_transfer = sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(slug.MAX_RECTS * slug.VERTICES_PER_QUAD * size_of(slug.Rect_Vertex)),
	})
	if r.rect_transfer == nil { destroy(r); return nil }

	// --- Upload static index buffers ---
	if !upload_static_indices(r) { destroy(r); return nil }

	return r
}

// Return a pointer to the slug context for draw calls.
ctx :: proc(r: ^Renderer) -> ^slug.Context {
	return &r.ctx
}

// Unload a font from a slot, releasing GPU textures and CPU glyph data.
unload_font :: proc(r: ^Renderer, slot: int) {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return

	fg := &r.font_gpu[slot]
	if fg.loaded {
		_ = sdl.WaitForGPUIdle(r.device)
		if fg.curve_texture != nil do sdl.ReleaseGPUTexture(r.device, fg.curve_texture)
		if fg.band_texture != nil do sdl.ReleaseGPUTexture(r.device, fg.band_texture)
		fg^ = {}
	}
	slug.unload_font(&r.ctx, slot)
}

// Release all GPU resources and free the renderer. Does NOT destroy the device.
destroy :: proc(r: ^Renderer) {
	if r == nil do return
	_ = sdl.WaitForGPUIdle(r.device)

	// Font textures
	for &fg in r.font_gpu {
		if fg.loaded {
			if fg.curve_texture != nil do sdl.ReleaseGPUTexture(r.device, fg.curve_texture)
			if fg.band_texture != nil do sdl.ReleaseGPUTexture(r.device, fg.band_texture)
		}
	}
	if r.shared_gpu.loaded {
		if r.shared_gpu.curve_texture != nil do sdl.ReleaseGPUTexture(r.device, r.shared_gpu.curve_texture)
		if r.shared_gpu.band_texture != nil do sdl.ReleaseGPUTexture(r.device, r.shared_gpu.band_texture)
	}

	if r.sampler != nil         do sdl.ReleaseGPUSampler(r.device, r.sampler)
	if r.slug_pipeline != nil   do sdl.ReleaseGPUGraphicsPipeline(r.device, r.slug_pipeline)
	if r.rect_pipeline != nil   do sdl.ReleaseGPUGraphicsPipeline(r.device, r.rect_pipeline)
	if r.vertex_buffer != nil   do sdl.ReleaseGPUBuffer(r.device, r.vertex_buffer)
	if r.index_buffer != nil    do sdl.ReleaseGPUBuffer(r.device, r.index_buffer)
	if r.rect_vb != nil         do sdl.ReleaseGPUBuffer(r.device, r.rect_vb)
	if r.rect_ib != nil         do sdl.ReleaseGPUBuffer(r.device, r.rect_ib)
	if r.transfer_buffer != nil do sdl.ReleaseGPUTransferBuffer(r.device, r.transfer_buffer)
	if r.rect_transfer != nil   do sdl.ReleaseGPUTransferBuffer(r.device, r.rect_transfer)

	sdl.ReleaseWindowFromGPUDevice(r.device, r.window)

	slug.destroy(&r.ctx)
	free(r)
}

// Load a TTF font file, process it, and upload textures to the GPU.
load_font :: proc(r: ^Renderer, slot: int, path: string) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	font, font_ok := slug.font_load(path)
	if !font_ok do return false

	slug.register_font(&r.ctx, slot, font)
	loaded := slug.font_load_ascii(&r.ctx.fonts[slot])
	if loaded == 0 do return false

	pack := slug.font_process(&r.ctx.fonts[slot])
	defer slug.pack_result_destroy(&pack)

	return upload_font_textures(r, slot, &pack)
}

// Upload pre-packed font textures to the GPU.
// Use this when you need the manual pipeline (e.g., loading SVG icons into
// a font before processing). For simple cases, use load_font() instead.
upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	fg := &r.font_gpu[slot]

	curve_tex := upload_texture(
		r,
		pack.curve_width,
		pack.curve_height,
		.R16G16B16A16_FLOAT,
		raw_data(pack.curve_data),
		len(pack.curve_data) * size_of([4]u16),
	)
	if curve_tex == nil do return false
	fg.curve_texture = curve_tex

	band_tex := upload_texture(
		r,
		pack.band_width,
		pack.band_height,
		.R16G16_UINT,
		raw_data(pack.band_data),
		len(pack.band_data) * size_of([2]u16),
	)
	if band_tex == nil {
		sdl.ReleaseGPUTexture(r.device, fg.curve_texture)
		fg.curve_texture = nil
		return false
	}
	fg.band_texture = band_tex

	fg.loaded = true
	return true
}

// Upload a shared font atlas (all fonts packed into one texture pair).
// Call with the result of slug.fonts_process_shared().
upload_shared_textures :: proc(r: ^Renderer, pack: ^slug.Texture_Pack_Result) -> bool {
	fg := &r.shared_gpu

	curve_tex := upload_texture(
		r,
		pack.curve_width,
		pack.curve_height,
		.R16G16B16A16_FLOAT,
		raw_data(pack.curve_data),
		len(pack.curve_data) * size_of([4]u16),
	)
	if curve_tex == nil do return false
	fg.curve_texture = curve_tex

	band_tex := upload_texture(
		r,
		pack.band_width,
		pack.band_height,
		.R16G16_UINT,
		raw_data(pack.band_data),
		len(pack.band_data) * size_of([2]u16),
	)
	if band_tex == nil {
		sdl.ReleaseGPUTexture(r.device, fg.curve_texture)
		fg.curve_texture = nil
		return false
	}
	fg.band_texture = band_tex

	fg.loaded = true
	return true
}

// Load multiple fonts and pack them into a shared atlas.
// paths is a slice of TTF file paths, loaded into slots 0, 1, 2, ...
load_fonts_shared :: proc(r: ^Renderer, paths: []string) -> bool {
	if len(paths) > slug.MAX_FONT_SLOTS do return false

	for path, slot in paths {
		font, font_ok := slug.font_load(path)
		if !font_ok do return false

		slug.register_font(&r.ctx, slot, font)
		loaded := slug.font_load_ascii(&r.ctx.fonts[slot])
		if loaded == 0 do return false
	}

	pack := slug.fonts_process_shared(&r.ctx)
	defer slug.pack_result_destroy(&pack)

	return upload_shared_textures(r, &pack)
}

// Begin a new frame: acquire command buffer and swapchain texture.
// Returns false if the swapchain is unavailable (e.g., window minimized).
begin_frame :: proc(r: ^Renderer) -> bool {
	r.cmd = sdl.AcquireGPUCommandBuffer(r.device)
	if r.cmd == nil do return false

	swapchain_tex: ^sdl.GPUTexture
	w, h: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(r.cmd, r.window, &swapchain_tex, &w, &h) {
		_ = sdl.CancelGPUCommandBuffer(r.cmd)
		return false
	}

	if swapchain_tex == nil {
		// Window minimized or swapchain unavailable
		_ = sdl.CancelGPUCommandBuffer(r.cmd)
		return false
	}

	r.swapchain_tex = swapchain_tex
	r.swapchain_w = w
	r.swapchain_h = h
	r.first_flush = true

	slug.begin(&r.ctx)
	return true
}

// Record draw calls for the current slug batch.
// scissor restricts this pass to a screen-space rectangle; zero value = full screen.
// Can be called multiple times per frame with different scissor rects.
//
// Each call implicitly calls slug.end() for the current batch and slug.begin()
// for the next — the caller does not need to call these manually.
//
// Must be called between begin_frame() and present_frame().
flush :: proc(r: ^Renderer, scissor: slug.Scissor_Rect = {}) {
	slug.end(&r.ctx)

	vert_count := slug.vertex_count(&r.ctx)
	rect_vert_count := u32(r.ctx.rect_count) * slug.VERTICES_PER_QUAD
	w := f32(r.swapchain_w)
	h := f32(r.swapchain_h)

	// --- Copy pass: upload vertex data from CPU to GPU ---
	if vert_count > 0 || rect_vert_count > 0 {
		copy_pass := sdl.BeginGPUCopyPass(r.cmd)

		if vert_count > 0 {
			ptr := sdl.MapGPUTransferBuffer(r.device, r.transfer_buffer, true)
			mem.copy(ptr, &r.ctx.vertices[0], int(vert_count) * size_of(slug.Vertex))
			sdl.UnmapGPUTransferBuffer(r.device, r.transfer_buffer)

			sdl.UploadToGPUBuffer(
				copy_pass,
				sdl.GPUTransferBufferLocation{transfer_buffer = r.transfer_buffer},
				sdl.GPUBufferRegion{
					buffer = r.vertex_buffer,
					size   = vert_count * size_of(slug.Vertex),
				},
				true, // cycle GPU buffer
			)
		}

		if rect_vert_count > 0 {
			ptr := sdl.MapGPUTransferBuffer(r.device, r.rect_transfer, true)
			mem.copy(ptr, &r.ctx.rect_vertices[0], int(rect_vert_count) * size_of(slug.Rect_Vertex))
			sdl.UnmapGPUTransferBuffer(r.device, r.rect_transfer)

			sdl.UploadToGPUBuffer(
				copy_pass,
				sdl.GPUTransferBufferLocation{transfer_buffer = r.rect_transfer},
				sdl.GPUBufferRegion{
					buffer = r.rect_vb,
					size   = rect_vert_count * size_of(slug.Rect_Vertex),
				},
				true,
			)
		}

		sdl.EndGPUCopyPass(copy_pass)
	}

	// --- Render pass ---
	load_op: sdl.GPULoadOp = .CLEAR if r.first_flush else .LOAD

	color_target := sdl.GPUColorTargetInfo{
		texture     = r.swapchain_tex,
		load_op     = load_op,
		store_op    = .STORE,
		clear_color = sdl.FColor{0.05, 0.05, 0.08, 1.0},
	}

	render_pass := sdl.BeginGPURenderPass(r.cmd, &color_target, 1, nil)

	// Viewport
	sdl.SetGPUViewport(render_pass, sdl.GPUViewport{
		w = w, h = h, min_depth = 0, max_depth = 1,
	})

	// Scissor (Y-down from top-left, same as Vulkan — no flip needed)
	if scissor.w > 0 && scissor.h > 0 {
		sdl.SetGPUScissor(render_pass, sdl.Rect{
			x = c.int(scissor.x), y = c.int(scissor.y),
			w = c.int(scissor.w), h = c.int(scissor.h),
		})
	} else {
		sdl.SetGPUScissor(render_pass, sdl.Rect{
			w = c.int(r.swapchain_w), h = c.int(r.swapchain_h),
		})
	}

	// Rect pass (before text — rects always behind glyphs)
	if r.ctx.rect_count > 0 {
		sdl.BindGPUGraphicsPipeline(render_pass, r.rect_pipeline)

		// SDL3 GPU normalizes NDC Y-up across backends: ortho(0,w,h,0) maps y=0 top, y=h bottom
		proj := linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)
		sdl.PushGPUVertexUniformData(r.cmd, 0, &proj, size_of(matrix[4, 4]f32))

		vb_binding := sdl.GPUBufferBinding{buffer = r.rect_vb}
		sdl.BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1)
		sdl.BindGPUIndexBuffer(render_pass, sdl.GPUBufferBinding{buffer = r.rect_ib}, ._32BIT)
		sdl.DrawGPUIndexedPrimitives(
			render_pass,
			r.ctx.rect_count * slug.INDICES_PER_QUAD, // num_indices
			1,                                         // num_instances
			0,                                         // first_index
			0,                                         // vertex_offset
			0,                                         // first_instance
		)
	}

	// Slug text pass
	if r.ctx.quad_count > 0 {
		sdl.BindGPUGraphicsPipeline(render_pass, r.slug_pipeline)

		pc := Push_Constants{
			mvp      = linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1),
			viewport = {w, h},
		}
		sdl.PushGPUVertexUniformData(r.cmd, 0, &pc, size_of(Push_Constants))

		// Fragment uniform: weight boost flag (std140 pads to 16 bytes)
		frag_params: [4]f32 = {r.ctx.weight_boost ? 1.0 : 0.0, 0, 0, 0}
		sdl.PushGPUFragmentUniformData(r.cmd, 0, &frag_params, size_of(frag_params))

		vb_binding := sdl.GPUBufferBinding{buffer = r.vertex_buffer}
		sdl.BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1)
		sdl.BindGPUIndexBuffer(render_pass, sdl.GPUBufferBinding{buffer = r.index_buffer}, ._32BIT)

		if r.ctx.shared_atlas && r.shared_gpu.loaded {
			bindings := [2]sdl.GPUTextureSamplerBinding{
				{texture = r.shared_gpu.curve_texture, sampler = r.sampler},
				{texture = r.shared_gpu.band_texture,  sampler = r.sampler},
			}
			sdl.BindGPUFragmentSamplers(render_pass, 0, raw_data(bindings[:]), 2)
			sdl.DrawGPUIndexedPrimitives(
				render_pass,
				r.ctx.quad_count * slug.INDICES_PER_QUAD,
				1, 0, 0, 0,
			)
		} else {
			for fi in 0 ..< slug.MAX_FONT_SLOTS {
				qcount := r.ctx.font_quad_count[fi]
				if qcount == 0 do continue
				fg := &r.font_gpu[fi]
				if !fg.loaded do continue

				bindings := [2]sdl.GPUTextureSamplerBinding{
					{texture = fg.curve_texture, sampler = r.sampler},
					{texture = fg.band_texture,  sampler = r.sampler},
				}
				sdl.BindGPUFragmentSamplers(render_pass, 0, raw_data(bindings[:]), 2)

				first_index := r.ctx.font_quad_start[fi] * slug.INDICES_PER_QUAD
				index_count := qcount * slug.INDICES_PER_QUAD
				sdl.DrawGPUIndexedPrimitives(
					render_pass,
					index_count, 1, first_index, 0, 0,
				)
			}
		}
	}

	sdl.EndGPURenderPass(render_pass)
	r.first_flush = false

	// Re-initialize slug for the next flush pass
	slug.begin(&r.ctx)
}

// Submit the command buffer to the GPU for presentation.
// Call once after all flush() calls for the frame.
present_frame :: proc(r: ^Renderer) -> bool {
	return sdl.SubmitGPUCommandBuffer(r.cmd)
}

// --- Private helpers ---

// Upload the static quad index pattern (0,1,2, 2,3,0 repeated) for both
// the slug and rect index buffers. Called once during init.
@(private = "file")
upload_static_indices :: proc(r: ^Renderer) -> bool {
	// Generate index data for slug quads
	slug_index_count := slug.MAX_GLYPH_INDICES
	slug_data_size := u32(slug_index_count * size_of(u32))

	slug_xfer := sdl.CreateGPUTransferBuffer(r.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = slug_data_size,
	})
	if slug_xfer == nil do return false

	{
		ptr := cast([^]u32)sdl.MapGPUTransferBuffer(r.device, slug_xfer, false)
		if ptr == nil {
			sdl.ReleaseGPUTransferBuffer(r.device, slug_xfer)
			return false
		}
		for q in 0 ..< slug.MAX_GLYPH_QUADS {
			base := u32(q * slug.VERTICES_PER_QUAD)
			idx := q * slug.INDICES_PER_QUAD
			ptr[idx + 0] = base + 0
			ptr[idx + 1] = base + 1
			ptr[idx + 2] = base + 2
			ptr[idx + 3] = base + 2
			ptr[idx + 4] = base + 3
			ptr[idx + 5] = base + 0
		}
		sdl.UnmapGPUTransferBuffer(r.device, slug_xfer)
	}

	// Generate index data for rect quads
	rect_index_count := slug.MAX_RECTS * slug.INDICES_PER_QUAD
	rect_data_size := u32(rect_index_count * size_of(u32))

	rect_xfer := sdl.CreateGPUTransferBuffer(r.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = rect_data_size,
	})
	if rect_xfer == nil {
		sdl.ReleaseGPUTransferBuffer(r.device, slug_xfer)
		return false
	}

	{
		ptr := cast([^]u32)sdl.MapGPUTransferBuffer(r.device, rect_xfer, false)
		if ptr == nil {
			sdl.ReleaseGPUTransferBuffer(r.device, rect_xfer)
			sdl.ReleaseGPUTransferBuffer(r.device, slug_xfer)
			return false
		}
		for q in 0 ..< slug.MAX_RECTS {
			base := u32(q * slug.VERTICES_PER_QUAD)
			idx := q * slug.INDICES_PER_QUAD
			ptr[idx + 0] = base + 0
			ptr[idx + 1] = base + 1
			ptr[idx + 2] = base + 2
			ptr[idx + 3] = base + 2
			ptr[idx + 4] = base + 3
			ptr[idx + 5] = base + 0
		}
		sdl.UnmapGPUTransferBuffer(r.device, rect_xfer)
	}

	// Copy both index buffers in a single copy pass
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil {
		sdl.ReleaseGPUTransferBuffer(r.device, rect_xfer)
		sdl.ReleaseGPUTransferBuffer(r.device, slug_xfer)
		return false
	}

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		copy_pass,
		sdl.GPUTransferBufferLocation{transfer_buffer = slug_xfer},
		sdl.GPUBufferRegion{buffer = r.index_buffer, size = slug_data_size},
		false,
	)
	sdl.UploadToGPUBuffer(
		copy_pass,
		sdl.GPUTransferBufferLocation{transfer_buffer = rect_xfer},
		sdl.GPUBufferRegion{buffer = r.rect_ib, size = rect_data_size},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) {
		sdl.ReleaseGPUTransferBuffer(r.device, rect_xfer)
		sdl.ReleaseGPUTransferBuffer(r.device, slug_xfer)
		return false
	}

	// Wait for upload to complete before releasing transfer buffers
	_ = sdl.WaitForGPUIdle(r.device)
	sdl.ReleaseGPUTransferBuffer(r.device, rect_xfer)
	sdl.ReleaseGPUTransferBuffer(r.device, slug_xfer)

	return true
}

// Upload texture data to the GPU via a temporary transfer buffer.
@(private = "file")
upload_texture :: proc(
	r: ^Renderer,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	data: rawptr,
	data_size: int,
) -> ^sdl.GPUTexture {
	tex := sdl.CreateGPUTexture(r.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = format,
		usage                = {.SAMPLER},
		width                = width,
		height               = height,
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if tex == nil do return nil

	tex_xfer := sdl.CreateGPUTransferBuffer(r.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(data_size),
	})
	if tex_xfer == nil {
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}

	ptr := sdl.MapGPUTransferBuffer(r.device, tex_xfer, false)
	if ptr == nil {
		sdl.ReleaseGPUTransferBuffer(r.device, tex_xfer)
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}
	mem.copy(ptr, data, data_size)
	sdl.UnmapGPUTransferBuffer(r.device, tex_xfer)

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil {
		sdl.ReleaseGPUTransferBuffer(r.device, tex_xfer)
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		copy_pass,
		sdl.GPUTextureTransferInfo{
			transfer_buffer = tex_xfer,
			offset          = 0,
			pixels_per_row  = width,
			rows_per_layer  = height,
		},
		sdl.GPUTextureRegion{
			texture = tex,
			w       = width,
			h       = height,
			d       = 1,
		},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) {
		sdl.ReleaseGPUTransferBuffer(r.device, tex_xfer)
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}

	_ = sdl.WaitForGPUIdle(r.device)
	sdl.ReleaseGPUTransferBuffer(r.device, tex_xfer)

	return tex
}
