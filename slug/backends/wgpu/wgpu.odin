package slug_wgpu

// ===================================================
// WebGPU backend for odin-slug
//
// Renders GPU-evaluated Bezier text using the Slug algorithm.
// Wraps a slug.Context and manages wgpu shader, pipeline, buffers,
// and per-font textures.
//
// Usage:
//   1. Create a Renderer, call init()
//   2. Load fonts with load_font() or load_font_mem()
//   3. Per frame:
//        slug.begin(slug_wgpu.ctx(r))
//        slug.draw_text(...)
//        slug.end(slug_wgpu.ctx(r))
//        flush(r, pass, width, height)
// ===================================================

import "core:math/linalg"
import "vendor:wgpu"

import slug "../../"

// --- Per-font GPU resources ---

Font_GPU :: struct {
	curve_texture: wgpu.Texture,
	curve_view:    wgpu.TextureView,
	band_texture:  wgpu.Texture,
	band_view:     wgpu.TextureView,
	bind_group:    wgpu.BindGroup,
	loaded:        bool,
}

// --- Uniform buffer layout (must match WGSL struct) ---

Uniforms :: struct {
	mvp:      matrix[4, 4]f32,
	viewport: [2]f32,
	_pad0:    f32,
	_pad1:    f32,
}

// --- Renderer state ---

Renderer :: struct {
	slug_ctx:          slug.Context,

	// Core wgpu objects (borrowed from engine)
	device:            wgpu.Device,
	queue:             wgpu.Queue,

	// Pipeline
	shader_module:     wgpu.ShaderModule,
	pipeline_layout:   wgpu.PipelineLayout,
	pipeline:          wgpu.RenderPipeline,
	bind_group_layout: wgpu.BindGroupLayout,

	// Buffers
	vertex_buffer:     wgpu.Buffer,
	index_buffer:      wgpu.Buffer,
	uniform_buffer:    wgpu.Buffer,

	// Per-font textures (used when NOT in shared atlas mode)
	font_gpu:          [slug.MAX_FONT_SLOTS]Font_GPU,

	// Shared atlas textures (used when slug_ctx.shared_atlas is true)
	shared_gpu:        Font_GPU,

	// Surface format for pipeline creation
	surface_format:    wgpu.TextureFormat,
}

// Access the slug context for draw calls.
ctx :: proc(r: ^Renderer) -> ^slug.Context {
	return &r.slug_ctx
}

// Vertex layout constants
VERTEX_SIZE :: size_of(slug.Vertex) // 80 bytes (5x vec4)
ATTRIB_COUNT :: 5

// ===================================================
// Initialization
// ===================================================

init :: proc(
	r: ^Renderer,
	device: wgpu.Device,
	queue: wgpu.Queue,
	surface_format: wgpu.TextureFormat,
) {
	r.device = device
	r.queue = queue
	r.surface_format = surface_format

	// Create shader module
	r.shader_module = wgpu.DeviceCreateShaderModule(
		device,
		&{
			nextInChain = &wgpu.ShaderSourceWGSL {
				sType = .ShaderSourceWGSL,
				code = #load("slug.wgsl"),
			},
		},
	)

	// Create bind group layout:
	//   binding 0: uniform buffer (mvp + viewport)
	//   binding 1: curve texture (float, texture_2d<f32>)
	//   binding 2: band texture (uint, texture_2d<u32>)
	r.bind_group_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{
			entryCount = 3,
			entries = raw_data(
				[]wgpu.BindGroupLayoutEntry {
					{
						binding = 0,
						visibility = {.Vertex, .Fragment},
						buffer = {type = .Uniform, minBindingSize = size_of(Uniforms)},
					},
					{
						binding = 1,
						visibility = {.Fragment},
						texture = {
							sampleType = .UnfilterableFloat,
							viewDimension = ._2D,
							multisampled = false,
						},
					},
					{
						binding = 2,
						visibility = {.Fragment},
						texture = {sampleType = .Uint, viewDimension = ._2D, multisampled = false},
					},
				},
			),
		},
	)

	// Create pipeline layout
	r.pipeline_layout = wgpu.DeviceCreatePipelineLayout(
		device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &r.bind_group_layout},
	)

	// Create render pipeline — 5 vertex attributes, 80-byte stride
	r.pipeline = wgpu.DeviceCreateRenderPipeline(
		device,
		&{
			layout = r.pipeline_layout,
			vertex = {
				module      = r.shader_module,
				entryPoint  = "vs_main",
				bufferCount = 1,
				buffers     = &wgpu.VertexBufferLayout {
					arrayStride    = VERTEX_SIZE,
					stepMode       = .Vertex,
					attributeCount = ATTRIB_COUNT,
					attributes     = raw_data(
						[]wgpu.VertexAttribute {
							{format = .Float32x4, offset = 0, shaderLocation = 0}, // pos
							{format = .Float32x4, offset = 16, shaderLocation = 1}, // tex
							{format = .Float32x4, offset = 32, shaderLocation = 2}, // jac
							{format = .Float32x4, offset = 48, shaderLocation = 3}, // bnd
							{format = .Float32x4, offset = 64, shaderLocation = 4}, // col
						},
					),
				},
			},
			fragment = &{
				module = r.shader_module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = surface_format,
					blend = &{
						alpha = {
							srcFactor = .SrcAlpha,
							dstFactor = .OneMinusSrcAlpha,
							operation = .Add,
						},
						color = {
							srcFactor = .SrcAlpha,
							dstFactor = .OneMinusSrcAlpha,
							operation = .Add,
						},
					},
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList, cullMode = .None},
			multisample = {count = 1, mask = 0xFFFFFFFF},
		},
	)

	// Create vertex buffer (dynamic, re-uploaded each frame)
	r.vertex_buffer = wgpu.DeviceCreateBuffer(
		device,
		&{
			label = "Slug Vertex Buffer",
			usage = {.Vertex, .CopyDst},
			size = slug.MAX_GLYPH_VERTICES * VERTEX_SIZE,
		},
	)

	// Create index buffer with pre-generated quad indices (0,1,2, 2,3,0)
	indices: [slug.MAX_GLYPH_INDICES]u32
	for q in 0 ..< slug.MAX_GLYPH_QUADS {
		base := u32(q) * 4
		off := q * 6
		indices[off + 0] = base + 0
		indices[off + 1] = base + 1
		indices[off + 2] = base + 2
		indices[off + 3] = base + 2
		indices[off + 4] = base + 3
		indices[off + 5] = base + 0
	}

	r.index_buffer = wgpu.DeviceCreateBuffer(
		device,
		&{
			label = "Slug Index Buffer",
			usage = {.Index, .CopyDst},
			size = slug.MAX_GLYPH_INDICES * size_of(u32),
		},
	)
	wgpu.QueueWriteBuffer(r.queue, r.index_buffer, 0, &indices, size_of(indices))

	// Create uniform buffer
	r.uniform_buffer = wgpu.DeviceCreateBuffer(
		device,
		&{label = "Slug Uniform Buffer", usage = {.Uniform, .CopyDst}, size = size_of(Uniforms)},
	)
}

// ===================================================
// Font loading
// ===================================================

// Load a font from in-memory data into a slot.
// For desktop, read the file yourself and pass the bytes.
load_font_mem :: proc(r: ^Renderer, slot: int, data: []u8) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	font := slug.font_load_mem(data) or_return

	slug.register_font(&r.slug_ctx, slot, font)

	loaded := slug.font_load_ascii(&r.slug_ctx.fonts[slot])
	if loaded == 0 do return false

	pack := slug.font_process(&r.slug_ctx.fonts[slot])
	defer slug.pack_result_destroy(&pack)

	return upload_font_textures(r, slot, &pack)
}

// Load multiple fonts from in-memory data into a shared atlas.
load_fonts_shared_mem :: proc(r: ^Renderer, datas: [][]u8) -> bool {
	if len(datas) > slug.MAX_FONT_SLOTS do return false

	for data, slot in datas {
		font := slug.font_load_mem(data) or_return

		slug.register_font(&r.slug_ctx, slot, font)
		loaded := slug.font_load_ascii(&r.slug_ctx.fonts[slot])
		if loaded == 0 do return false
	}

	pack := slug.fonts_process_shared(&r.slug_ctx)
	defer slug.pack_result_destroy(&pack)

	return upload_shared_textures(r, &pack)
}

// ===================================================
// Texture upload
// ===================================================

upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	fg := &r.font_gpu[slot]
	create_gpu_textures(r, fg, pack)
	return true
}

upload_shared_textures :: proc(r: ^Renderer, pack: ^slug.Texture_Pack_Result) -> bool {
	create_gpu_textures(r, &r.shared_gpu, pack)
	return true
}

@(private = "file")
create_gpu_textures :: proc(r: ^Renderer, fg: ^Font_GPU, pack: ^slug.Texture_Pack_Result) {
	// Curve texture: RGBA16Float
	fg.curve_texture = wgpu.DeviceCreateTexture(
		r.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {pack.curve_width, pack.curve_height, 1},
			format = .RGBA16Float,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)

	wgpu.QueueWriteTexture(
		r.queue,
		&{texture = fg.curve_texture},
		raw_data(pack.curve_data[:]),
		uint(len(pack.curve_data) * size_of([4]u16)),
		&{bytesPerRow = pack.curve_width * 8, rowsPerImage = pack.curve_height},
		&{pack.curve_width, pack.curve_height, 1},
	)

	fg.curve_view = wgpu.TextureCreateView(fg.curve_texture, nil)

	// Band texture: RG16Uint
	fg.band_texture = wgpu.DeviceCreateTexture(
		r.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {pack.band_width, pack.band_height, 1},
			format = .RG16Uint,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)

	wgpu.QueueWriteTexture(
		r.queue,
		&{texture = fg.band_texture},
		raw_data(pack.band_data[:]),
		uint(len(pack.band_data) * size_of([2]u16)),
		&{bytesPerRow = pack.band_width * 4, rowsPerImage = pack.band_height},
		&{pack.band_width, pack.band_height, 1},
	)

	fg.band_view = wgpu.TextureCreateView(fg.band_texture, nil)

	// Create bind group
	fg.bind_group = wgpu.DeviceCreateBindGroup(
		r.device,
		&{
			layout = r.bind_group_layout,
			entryCount = 3,
			entries = raw_data(
				[]wgpu.BindGroupEntry {
					{binding = 0, buffer = r.uniform_buffer, size = size_of(Uniforms)},
					{binding = 1, textureView = fg.curve_view},
					{binding = 2, textureView = fg.band_view},
				},
			),
		},
	)

	fg.loaded = true
}

// ===================================================
// Flush — upload vertices and draw into the provided render pass
// ===================================================

flush :: proc(r: ^Renderer, pass: wgpu.RenderPassEncoder, width, height: u32) {
	quad_count := r.slug_ctx.quad_count
	if quad_count == 0 do return

	vert_count := slug.vertex_count(&r.slug_ctx)
	w := f32(width)
	h := f32(height)

	// Orthographic projection: origin top-left, Y-down
	proj := linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)

	uniforms := Uniforms {
		mvp      = proj,
		viewport = {w, h},
	}
	wgpu.QueueWriteBuffer(r.queue, r.uniform_buffer, 0, &uniforms, size_of(Uniforms))

	// Upload vertex data
	vert_bytes := uint(vert_count) * VERTEX_SIZE
	wgpu.QueueWriteBuffer(r.queue, r.vertex_buffer, 0, &r.slug_ctx.vertices[0], vert_bytes)

	// Set pipeline and buffers
	wgpu.RenderPassEncoderSetPipeline(pass, r.pipeline)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, r.vertex_buffer, 0, u64(vert_bytes))
	wgpu.RenderPassEncoderSetIndexBuffer(
		pass,
		r.index_buffer,
		.Uint32,
		0,
		slug.MAX_GLYPH_INDICES * size_of(u32),
	)

	if r.slug_ctx.shared_atlas && r.shared_gpu.loaded {
		// Shared atlas: one bind + one draw call for all quads
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, r.shared_gpu.bind_group)
		index_count := quad_count * slug.INDICES_PER_QUAD
		wgpu.RenderPassEncoderDrawIndexed(pass, index_count, 1, 0, 0, 0)
	} else {
		// Per-font batched draw calls
		for fi in 0 ..< slug.MAX_FONT_SLOTS {
			qcount := r.slug_ctx.font_quad_count[fi]
			if qcount == 0 do continue

			fg := &r.font_gpu[fi]
			if !fg.loaded do continue

			wgpu.RenderPassEncoderSetBindGroup(pass, 0, fg.bind_group)

			first_index := r.slug_ctx.font_quad_start[fi] * slug.INDICES_PER_QUAD
			index_count := qcount * slug.INDICES_PER_QUAD
			wgpu.RenderPassEncoderDrawIndexed(pass, index_count, 1, first_index, 0, 0)
		}
	}
}

// ===================================================
// Unload / Destroy
// ===================================================

unload_font :: proc(r: ^Renderer, slot: int) {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return

	fg := &r.font_gpu[slot]
	if fg.loaded {
		release_font_gpu(fg)
	}
	slug.unload_font(&r.slug_ctx, slot)
}

destroy :: proc(r: ^Renderer) {
	// Release shared atlas
	if r.shared_gpu.loaded {
		release_font_gpu(&r.shared_gpu)
	}

	// Release per-font textures
	for fi in 0 ..< slug.MAX_FONT_SLOTS {
		fg := &r.font_gpu[fi]
		if fg.loaded {
			release_font_gpu(fg)
		}
	}

	// Release buffers
	if r.index_buffer != nil do wgpu.BufferRelease(r.index_buffer)
	if r.vertex_buffer != nil do wgpu.BufferRelease(r.vertex_buffer)
	if r.uniform_buffer != nil do wgpu.BufferRelease(r.uniform_buffer)

	// Release pipeline objects
	if r.pipeline != nil do wgpu.RenderPipelineRelease(r.pipeline)
	if r.pipeline_layout != nil do wgpu.PipelineLayoutRelease(r.pipeline_layout)
	if r.bind_group_layout != nil do wgpu.BindGroupLayoutRelease(r.bind_group_layout)
	if r.shader_module != nil do wgpu.ShaderModuleRelease(r.shader_module)

	// Destroy slug context (frees fonts and glyph data)
	slug.destroy(&r.slug_ctx)

	r^ = {}
}

@(private = "file")
release_font_gpu :: proc(fg: ^Font_GPU) {
	if fg.bind_group != nil do wgpu.BindGroupRelease(fg.bind_group)
	if fg.curve_view != nil do wgpu.TextureViewRelease(fg.curve_view)
	if fg.curve_texture != nil do wgpu.TextureRelease(fg.curve_texture)
	if fg.band_view != nil do wgpu.TextureViewRelease(fg.band_view)
	if fg.band_texture != nil do wgpu.TextureRelease(fg.band_texture)
	fg^ = {}
}
