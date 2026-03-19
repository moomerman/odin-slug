package slug_vulkan

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

import slug "../.."

// ===================================================
// Slug Vulkan Renderer — initialization, pipeline setup, and draw submission.
//
// Rendering pipeline per frame:
//   1. begin_frame()   — wait for GPU idle, call slug.begin()
//   2. (caller emits quads via slug.draw_text / slug.emit_glyph_quad on r.ctx)
//   3. end_frame()     — call slug.end()
//   4. draw_frame()    — copy vertices to GPU, record commands, submit, present
//
// Each font gets its own descriptor set (curve + band textures), so draw
// calls are batched per-font: one vkCmdDrawIndexed per active font slot.
// ===================================================

// --- Push constant layout (must match vertex shader) ---
Push_Constants :: struct {
	mvp:      matrix[4, 4]f32, // 64 bytes
	viewport: [2]f32, // 8 bytes
}

// --- Per-font GPU resources ---
Font_Instance :: struct {
	curve_texture:  GPU_Texture,
	band_texture:   GPU_Texture,
	descriptor_set: vk.DescriptorSet,
	loaded:         bool,
	name:           string,
}

// --- Renderer ---
Renderer :: struct {
	// Core slug context (CPU-side fonts, vertices, quad tracking)
	ctx:                   slug.Context,

	// Window
	window:                ^sdl.Window,

	// Core Vulkan state
	instance:              vk.Instance,
	debug_messenger:       vk.DebugUtilsMessengerEXT,
	surface:               vk.SurfaceKHR,
	physical_device:       vk.PhysicalDevice,
	device:                vk.Device,
	graphics_queue:        vk.Queue,
	present_queue:         vk.Queue,
	graphics_family:       u32,
	present_family:        u32,

	// Swapchain
	swapchain:             vk.SwapchainKHR,
	swapchain_images:      []vk.Image,
	swapchain_views:       []vk.ImageView,
	swapchain_format:      vk.SurfaceFormatKHR,
	swapchain_extent:      vk.Extent2D,

	// Render pass and framebuffers
	render_pass:           vk.RenderPass,
	framebuffers:          []vk.Framebuffer,

	// Pipeline
	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,

	// Descriptors
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_pool:       vk.DescriptorPool,

	// Vertex/index buffers
	vertex_buffer:         vk.Buffer,
	vertex_memory:         vk.DeviceMemory,
	vertex_mapped:         [^]slug.Vertex,
	index_buffer:          vk.Buffer,
	index_memory:          vk.DeviceMemory,

	// Command state
	command_pool:          vk.CommandPool,
	command_buffers:       []vk.CommandBuffer,

	// Sync
	image_available:       []vk.Semaphore,
	render_finished:       []vk.Semaphore,
	in_flight_fences:      []vk.Fence,
	current_frame:         u32,

	// Resize tracking
	framebuffer_resized:   bool,

	// Font instances (GPU resources per font slot)
	font_instances:        [slug.MAX_FONT_SLOTS]Font_Instance,

	// View transform
	zoom:                  f32,
	pan:                   [2]f32,
}

// --- Public API ---

init :: proc(r: ^Renderer, window: ^sdl.Window) -> bool {
	r.window = window

	// Load Vulkan via SDL3
	if !sdl.Vulkan_LoadLibrary(nil) {
		fmt.eprintln("SDL3: Failed to load Vulkan library:", sdl.GetError())
		return false
	}

	get_instance_proc := sdl.Vulkan_GetVkGetInstanceProcAddr()
	if get_instance_proc == nil {
		fmt.eprintln("SDL3: Failed to get vkGetInstanceProcAddr")
		return false
	}

	vk.load_proc_addresses_global(rawptr(get_instance_proc))

	if !create_instance(r) do return false
	vk.load_proc_addresses_instance(r.instance)

	when ENABLE_VALIDATION {
		setup_debug_messenger(r)
	}

	// Create surface via SDL3
	if !sdl.Vulkan_CreateSurface(window, r.instance, nil, &r.surface) {
		fmt.eprintln("SDL3: Failed to create Vulkan surface:", sdl.GetError())
		return false
	}

	if !pick_physical_device(r) do return false
	if !create_logical_device(r) do return false
	vk.load_proc_addresses_device(r.device)

	if !create_swapchain(r, window) do return false
	if !create_image_views(r) do return false
	if !create_command_pool(r) do return false
	if !create_render_pass(r) do return false
	if !create_framebuffers(r) do return false
	if !create_descriptor_set_layout(r) do return false
	if !create_descriptor_pool(r) do return false
	if !create_slug_pipeline(r) do return false
	if !create_command_buffers(r) do return false
	if !create_sync_objects(r) do return false
	if !create_vertex_index_buffers(r) do return false

	return true
}

destroy :: proc(r: ^Renderer) {
	if r.device != nil {
		vk.DeviceWaitIdle(r.device)
	}

	// Font instances
	for i in 0 ..< slug.MAX_FONT_SLOTS {
		fi := &r.font_instances[i]
		if fi.loaded {
			gpu_texture_destroy(r, &fi.curve_texture)
			gpu_texture_destroy(r, &fi.band_texture)
		}
	}

	// Vertex/index buffers
	if r.vertex_buffer != 0 do vk.DestroyBuffer(r.device, r.vertex_buffer, nil)
	if r.vertex_memory != 0 do vk.FreeMemory(r.device, r.vertex_memory, nil)
	if r.index_buffer != 0 do vk.DestroyBuffer(r.device, r.index_buffer, nil)
	if r.index_memory != 0 do vk.FreeMemory(r.device, r.index_memory, nil)

	// Descriptors
	if r.descriptor_pool != 0 do vk.DestroyDescriptorPool(r.device, r.descriptor_pool, nil)
	if r.descriptor_set_layout != 0 do vk.DestroyDescriptorSetLayout(r.device, r.descriptor_set_layout, nil)

	// Pipeline
	if r.pipeline != 0 do vk.DestroyPipeline(r.device, r.pipeline, nil)
	if r.pipeline_layout != 0 do vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil)

	// Command pool
	if r.command_pool != 0 do vk.DestroyCommandPool(r.device, r.command_pool, nil)

	// Sync objects
	for sem in r.image_available {
		if sem != 0 do vk.DestroySemaphore(r.device, sem, nil)
	}
	delete(r.image_available)
	for sem in r.render_finished {
		if sem != 0 do vk.DestroySemaphore(r.device, sem, nil)
	}
	delete(r.render_finished)
	for fence in r.in_flight_fences {
		if fence != 0 do vk.DestroyFence(r.device, fence, nil)
	}
	delete(r.in_flight_fences)

	// Framebuffers + swapchain
	for fb in r.framebuffers {
		if fb != 0 do vk.DestroyFramebuffer(r.device, fb, nil)
	}
	delete(r.framebuffers)
	delete(r.command_buffers)
	for view in r.swapchain_views {
		if view != 0 do vk.DestroyImageView(r.device, view, nil)
	}
	delete(r.swapchain_views)
	delete(r.swapchain_images)
	if r.swapchain != 0 do vk.DestroySwapchainKHR(r.device, r.swapchain, nil)

	if r.render_pass != 0 do vk.DestroyRenderPass(r.device, r.render_pass, nil)
	if r.device != nil do vk.DestroyDevice(r.device, nil)

	when ENABLE_VALIDATION {
		if r.debug_messenger != 0 {
			vk.DestroyDebugUtilsMessengerEXT(r.instance, r.debug_messenger, nil)
		}
	}

	if r.surface != 0 do vk.DestroySurfaceKHR(r.instance, r.surface, nil)
	if r.instance != nil do vk.DestroyInstance(r.instance, nil)

	// Destroy CPU-side font data
	slug.destroy(&r.ctx)
}

load_font :: proc(r: ^Renderer, slot: int, path: string, name: string = "") -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS {
		fmt.eprintln("Invalid font slot:", slot)
		return false
	}

	font, font_ok := slug.font_load(path)
	if !font_ok {
		fmt.eprintln("Failed to load font:", path)
		return false
	}
	slug.register_font(&r.ctx, slot, font)
	slug.font_load_ascii(&r.ctx.fonts[slot])

	pack := slug.font_process(&r.ctx.fonts[slot])
	defer slug.pack_result_destroy(&pack)

	return upload_font_textures(r, slot, &pack, name)
}

// Upload pre-packed font textures to the GPU and create the descriptor set.
// Use this when you need the manual pipeline (e.g., loading SVG icons into
// a font before processing). For simple cases, use load_font() instead.
upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result, name: string = "") -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS {
		fmt.eprintln("Invalid font slot:", slot)
		return false
	}

	fi := &r.font_instances[slot]

	// Upload curve texture (R16G16B16A16_SFLOAT)
	curve_data_size := len(pack.curve_data) * size_of([4]u16)
	curve_tex, curve_ok := gpu_texture_create(
		r,
		pack.curve_width,
		pack.curve_height,
		.R16G16B16A16_SFLOAT,
		raw_data(pack.curve_data),
		curve_data_size,
	)
	if !curve_ok do return false
	fi.curve_texture = curve_tex

	// Upload band texture (R16G16_UINT)
	band_data_size := len(pack.band_data) * size_of([2]u16)
	band_tex, band_ok := gpu_texture_create(
		r,
		pack.band_width,
		pack.band_height,
		.R16G16_UINT,
		raw_data(pack.band_data),
		band_data_size,
	)
	if !band_ok {
		gpu_texture_destroy(r, &fi.curve_texture)
		return false
	}
	fi.band_texture = band_tex

	// Allocate descriptor set from the pool
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.descriptor_set_layout,
	}

	result := vk.AllocateDescriptorSets(r.device, &alloc_info, &fi.descriptor_set)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate descriptor set for font slot:", slot)
		gpu_texture_destroy(r, &fi.band_texture)
		gpu_texture_destroy(r, &fi.curve_texture)
		return false
	}

	// Write descriptor set
	curve_image_info := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = fi.curve_texture.view,
		sampler     = fi.curve_texture.sampler,
	}
	band_image_info := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = fi.band_texture.view,
		sampler     = fi.band_texture.sampler,
	}
	writes := [2]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = fi.descriptor_set,
			dstBinding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo = &curve_image_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = fi.descriptor_set,
			dstBinding = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo = &band_image_info,
		},
	}
	vk.UpdateDescriptorSets(r.device, len(writes), &writes[0], 0, nil)

	fi.loaded = true
	fi.name = name
	fmt.printf("Font slot %d loaded: %s\n", slot, name)
	return true
}

begin_frame :: proc(r: ^Renderer) {
	// Wait for all in-flight frames before overwriting shared vertex buffer
	if r.device != nil && r.in_flight_fences != nil {
		vk.WaitForFences(
			r.device,
			u32(len(r.in_flight_fences)),
			raw_data(r.in_flight_fences),
			true,
			max(u64),
		)
	}

	slug.begin(&r.ctx)
}

end_frame :: proc(r: ^Renderer) {
	slug.end(&r.ctx)
}

use_font :: proc(r: ^Renderer, slot: int) {
	slug.use_font(&r.ctx, slot)
}

draw_frame :: proc(r: ^Renderer) -> bool {
	// Copy CPU vertices to the persistently-mapped GPU buffer
	vert_count := slug.vertex_count(&r.ctx)
	if vert_count > 0 {
		mem.copy(r.vertex_mapped, &r.ctx.vertices[0], int(vert_count) * size_of(slug.Vertex))
	}

	frame := r.current_frame

	// Acquire next swapchain image
	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		r.device,
		r.swapchain,
		max(u64),
		r.image_available[frame],
		0,
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		if !recreate_swapchain(r) do return false
		return true
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.eprintln("Failed to acquire swapchain image:", acquire_result)
		return false
	}

	vk.ResetFences(r.device, 1, &r.in_flight_fences[frame])

	cmd := r.command_buffers[image_index]
	vk.ResetCommandBuffer(cmd, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	// Begin render pass
	clear_color := vk.ClearValue{}
	clear_color.color.float32 = {0.05, 0.05, 0.08, 1.0}

	rp_begin := vk.RenderPassBeginInfo {
		sType           = .RENDER_PASS_BEGIN_INFO,
		renderPass      = r.render_pass,
		framebuffer     = r.framebuffers[image_index],
		renderArea      = {{0, 0}, r.swapchain_extent},
		clearValueCount = 1,
		pClearValues    = &clear_color,
	}

	vk.CmdBeginRenderPass(cmd, &rp_begin, .INLINE)

	// Set viewport and scissor
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(r.swapchain_extent.width),
		height   = f32(r.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = r.swapchain_extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	if r.ctx.quad_count > 0 {
		vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipeline)

		w := f32(r.swapchain_extent.width)
		h := f32(r.swapchain_extent.height)

		proj := linalg.matrix_ortho3d_f32(0, w, 0, h, -1, 1)

		zoom := r.zoom if r.zoom > 0 else 1.0
		cx := w * 0.5
		cy := h * 0.5
		view :=
			linalg.matrix4_translate_f32({cx + r.pan.x, cy + r.pan.y, 0}) *
			linalg.matrix4_scale_f32({zoom, zoom, 1}) *
			linalg.matrix4_translate_f32({-cx, -cy, 0})

		pc := Push_Constants {
			mvp      = proj * view,
			viewport = {w, h},
		}

		vk.CmdPushConstants(cmd, r.pipeline_layout, {.VERTEX}, 0, size_of(Push_Constants), &pc)

		// Bind vertex and index buffers
		vb_offset := vk.DeviceSize(0)
		vk.CmdBindVertexBuffers(cmd, 0, 1, &r.vertex_buffer, &vb_offset)
		vk.CmdBindIndexBuffer(cmd, r.index_buffer, 0, .UINT32)

		// Issue per-font draw calls
		for fi in 0 ..< slug.MAX_FONT_SLOTS {
			qcount := r.ctx.font_quad_count[fi]
			if qcount == 0 do continue
			if !r.font_instances[fi].loaded do continue

			ds := r.font_instances[fi].descriptor_set
			if ds == 0 do continue

			vk.CmdBindDescriptorSets(cmd, .GRAPHICS, r.pipeline_layout, 0, 1, &ds, 0, nil)

			first_index := r.ctx.font_quad_start[fi] * slug.INDICES_PER_QUAD
			index_count := qcount * slug.INDICES_PER_QUAD
			vk.CmdDrawIndexed(cmd, index_count, 1, first_index, 0, 0)
		}
	}

	vk.CmdEndRenderPass(cmd)
	vk.EndCommandBuffer(cmd)

	// Submit
	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &r.image_available[frame],
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &r.command_buffers[image_index],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &r.render_finished[frame],
	}

	submit_result := vk.QueueSubmit(r.graphics_queue, 1, &submit_info, r.in_flight_fences[frame])
	if submit_result != .SUCCESS {
		fmt.eprintln("Failed to submit draw command:", submit_result)
		return false
	}

	// Present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.render_finished[frame],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain,
		pImageIndices      = &image_index,
	}

	present_result := vk.QueuePresentKHR(r.present_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   r.framebuffer_resized {
		if !recreate_swapchain(r) do return false
	} else if present_result != .SUCCESS {
		fmt.eprintln("Failed to present swapchain image:", present_result)
		return false
	}

	r.current_frame = (frame + 1) % u32(len(r.swapchain_images))

	return true
}

// --- Private Vulkan setup procs ---

@(private = "file")
create_instance :: proc(r: ^Renderer) -> bool {
	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "odin-slug",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "Slug",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}

	ext_count: sdl.Uint32
	sdl_exts := sdl.Vulkan_GetInstanceExtensions(&ext_count)

	extensions: [dynamic]cstring
	defer delete(extensions)

	if sdl_exts != nil {
		for i in 0 ..< ext_count {
			append(&extensions, sdl_exts[i])
		}
	}

	when ENABLE_VALIDATION {
		append(&extensions, "VK_EXT_debug_utils")
	}

	validation_layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}

	when ENABLE_VALIDATION {
		create_info.enabledLayerCount = len(validation_layers)
		create_info.ppEnabledLayerNames = &validation_layers[0]
	}

	result := vk.CreateInstance(&create_info, nil, &r.instance)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create Vulkan instance:", result)
		return false
	}

	return true
}

when ENABLE_VALIDATION {
	@(private = "file")
	setup_debug_messenger :: proc(r: ^Renderer) {
		create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.WARNING, .ERROR},
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = debug_callback,
		}
		vk.CreateDebugUtilsMessengerEXT(r.instance, &create_info, nil, &r.debug_messenger)
	}
}

@(private = "file")
pick_physical_device :: proc(r: ^Renderer) -> bool {
	device_count: u32
	vk.EnumeratePhysicalDevices(r.instance, &device_count, nil)
	if device_count == 0 {
		fmt.eprintln("No Vulkan-capable GPU found")
		return false
	}

	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(r.instance, &device_count, raw_data(devices))

	for device in devices {
		gfx_family, gfx_found := find_queue_family(device, {.GRAPHICS})
		pres_family, pres_found := find_present_family(r, device)

		if !gfx_found || !pres_found do continue

		ext_count: u32
		vk.EnumerateDeviceExtensionProperties(device, nil, &ext_count, nil)
		exts := make([]vk.ExtensionProperties, ext_count)
		defer delete(exts)
		vk.EnumerateDeviceExtensionProperties(device, nil, &ext_count, raw_data(exts))

		has_swapchain := false
		for &ext in exts {
			name := cstring(raw_data(&ext.extensionName))
			if name == "VK_KHR_swapchain" {
				has_swapchain = true
				break
			}
		}
		if !has_swapchain do continue

		r.physical_device = device
		r.graphics_family = gfx_family
		r.present_family = pres_family
		return true
	}

	fmt.eprintln("No suitable GPU found")
	return false
}

@(private = "file")
find_queue_family :: proc(device: vk.PhysicalDevice, required: vk.QueueFlags) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	families := make([]vk.QueueFamilyProperties, count)
	defer delete(families)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if required <= family.queueFlags {
			return u32(i), true
		}
	}
	return 0, false
}

@(private = "file")
find_present_family :: proc(r: ^Renderer, device: vk.PhysicalDevice) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	for i in 0 ..< count {
		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, i, r.surface, &supported)
		if supported do return i, true
	}
	return 0, false
}

@(private = "file")
create_logical_device :: proc(r: ^Renderer) -> bool {
	unique_families: [2]u32
	family_count: u32 = 1
	unique_families[0] = r.graphics_family
	if r.present_family != r.graphics_family {
		unique_families[1] = r.present_family
		family_count = 2
	}

	queue_priority: f32 = 1.0
	queue_create_infos: [2]vk.DeviceQueueCreateInfo
	for i in 0 ..< family_count {
		queue_create_infos[i] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = unique_families[i],
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
	}

	device_extensions := [?]cstring{"VK_KHR_swapchain"}
	features := vk.PhysicalDeviceFeatures{}

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = family_count,
		pQueueCreateInfos       = &queue_create_infos[0],
		enabledExtensionCount   = len(device_extensions),
		ppEnabledExtensionNames = &device_extensions[0],
		pEnabledFeatures        = &features,
	}

	result := vk.CreateDevice(r.physical_device, &create_info, nil, &r.device)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create logical device:", result)
		return false
	}

	vk.GetDeviceQueue(r.device, r.graphics_family, 0, &r.graphics_queue)
	vk.GetDeviceQueue(r.device, r.present_family, 0, &r.present_queue)

	return true
}

@(private = "file")
create_swapchain :: proc(r: ^Renderer, window: ^sdl.Window) -> bool {
	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical_device, r.surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.physical_device, r.surface, &format_count, nil)
	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		r.physical_device,
		r.surface,
		&format_count,
		raw_data(formats),
	)

	chosen_format := formats[0]
	for sf in formats {
		if sf.format == .B8G8R8A8_SRGB && sf.colorSpace == .SRGB_NONLINEAR {
			chosen_format = sf
			break
		}
	}
	r.swapchain_format = chosen_format

	chosen_mode := vk.PresentModeKHR.FIFO

	extent: vk.Extent2D
	if capabilities.currentExtent.width != max(u32) {
		extent = capabilities.currentExtent
	} else {
		w, h: i32
		sdl.GetWindowSizeInPixels(window, &w, &h)
		extent = vk.Extent2D {
			width  = clamp(
				u32(w),
				capabilities.minImageExtent.width,
				capabilities.maxImageExtent.width,
			),
			height = clamp(
				u32(h),
				capabilities.minImageExtent.height,
				capabilities.maxImageExtent.height,
			),
		}
	}
	r.swapchain_extent = extent

	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	sc_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = r.surface,
		minImageCount    = image_count,
		imageFormat      = chosen_format.format,
		imageColorSpace  = chosen_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = chosen_mode,
		clipped          = true,
	}

	queue_families := [?]u32{r.graphics_family, r.present_family}
	if r.graphics_family != r.present_family {
		sc_create_info.imageSharingMode = .CONCURRENT
		sc_create_info.queueFamilyIndexCount = 2
		sc_create_info.pQueueFamilyIndices = &queue_families[0]
	} else {
		sc_create_info.imageSharingMode = .EXCLUSIVE
	}

	result := vk.CreateSwapchainKHR(r.device, &sc_create_info, nil, &r.swapchain)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create swapchain:", result)
		return false
	}

	sc_count: u32
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &sc_count, nil)
	r.swapchain_images = make([]vk.Image, sc_count)
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &sc_count, raw_data(r.swapchain_images))

	return true
}

@(private = "file")
create_image_views :: proc(r: ^Renderer) -> bool {
	r.swapchain_views = make([]vk.ImageView, len(r.swapchain_images))

	for img, i in r.swapchain_images {
		iv_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = img,
			viewType = .D2,
			format = r.swapchain_format.format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		result := vk.CreateImageView(r.device, &iv_create_info, nil, &r.swapchain_views[i])
		if result != .SUCCESS {
			fmt.eprintln("Failed to create image view:", result)
			return false
		}
	}

	return true
}

@(private = "file")
create_command_pool :: proc(r: ^Renderer) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_family,
	}

	result := vk.CreateCommandPool(r.device, &pool_info, nil, &r.command_pool)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create command pool:", result)
		return false
	}

	return true
}

@(private = "file")
create_render_pass :: proc(r: ^Renderer) -> bool {
	color_attachment := vk.AttachmentDescription {
		format         = r.swapchain_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}

	color_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_ref,
	}

	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}

	rp_create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}

	result := vk.CreateRenderPass(r.device, &rp_create_info, nil, &r.render_pass)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create render pass:", result)
		return false
	}

	return true
}

@(private = "file")
create_framebuffers :: proc(r: ^Renderer) -> bool {
	r.framebuffers = make([]vk.Framebuffer, len(r.swapchain_views))

	for view, i in r.swapchain_views {
		attachments := [1]vk.ImageView{view}

		fb_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = r.render_pass,
			attachmentCount = 1,
			pAttachments    = &attachments[0],
			width           = r.swapchain_extent.width,
			height          = r.swapchain_extent.height,
			layers          = 1,
		}

		result := vk.CreateFramebuffer(r.device, &fb_info, nil, &r.framebuffers[i])
		if result != .SUCCESS {
			fmt.eprintln("Failed to create framebuffer:", result)
			return false
		}
	}

	return true
}

@(private = "file")
create_descriptor_set_layout :: proc(r: ^Renderer) -> bool {
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}

	result := vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &r.descriptor_set_layout)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create descriptor set layout:", result)
		return false
	}

	return true
}

@(private = "file")
create_descriptor_pool :: proc(r: ^Renderer) -> bool {
	pool_sizes := [1]vk.DescriptorPoolSize {
		{
			type            = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 2 * slug.MAX_FONT_SLOTS, // 2 textures per font
		},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = &pool_sizes[0],
		maxSets       = slug.MAX_FONT_SLOTS,
	}

	result := vk.CreateDescriptorPool(r.device, &pool_info, nil, &r.descriptor_pool)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create descriptor pool:", result)
		return false
	}

	return true
}

@(private = "file")
create_slug_pipeline :: proc(r: ^Renderer) -> bool {
	vert_code, vert_err := os.read_entire_file("slug/shaders/slug_vert.spv", context.allocator)
	if vert_err != nil {
		fmt.eprintln(
			"Failed to read slug vertex shader (expected slug/shaders/slug_vert.spv):",
			vert_err,
		)
		return false
	}
	defer delete(vert_code)

	frag_code, frag_err := os.read_entire_file("slug/shaders/slug_frag.spv", context.allocator)
	if frag_err != nil {
		fmt.eprintln(
			"Failed to read slug fragment shader (expected slug/shaders/slug_frag.spv):",
			frag_err,
		)
		return false
	}
	defer delete(frag_code)

	vert_module, vert_ok := create_shader_module(r, vert_code)
	if !vert_ok do return false
	defer vk.DestroyShaderModule(r.device, vert_module, nil)

	frag_module, frag_ok := create_shader_module(r, frag_code)
	if !frag_ok do return false
	defer vk.DestroyShaderModule(r.device, frag_module, nil)

	shader_stages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert_module,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag_module,
			pName = "main",
		},
	}

	binding_desc := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(slug.Vertex),
		inputRate = .VERTEX,
	}

	attrib_descs := [5]vk.VertexInputAttributeDescription {
		{
			binding = 0,
			location = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(slug.Vertex, pos)),
		},
		{
			binding = 0,
			location = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(slug.Vertex, tex)),
		},
		{
			binding = 0,
			location = 2,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(slug.Vertex, jac)),
		},
		{
			binding = 0,
			location = 3,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(slug.Vertex, bnd)),
		},
		{
			binding = 0,
			location = 4,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(slug.Vertex, col)),
		},
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding_desc,
		vertexAttributeDescriptionCount = len(attrib_descs),
		pVertexAttributeDescriptions    = &attrib_descs[0],
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1.0,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(Push_Constants),
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &r.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}

	result := vk.CreatePipelineLayout(r.device, &layout_info, nil, &r.pipeline_layout)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create pipeline layout:", result)
		return false
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shader_stages),
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = r.pipeline_layout,
		renderPass          = r.render_pass,
		subpass             = 0,
	}

	result = vk.CreateGraphicsPipelines(r.device, 0, 1, &pipeline_info, nil, &r.pipeline)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create Slug graphics pipeline:", result)
		return false
	}

	return true
}

@(private = "file")
create_command_buffers :: proc(r: ^Renderer) -> bool {
	r.command_buffers = make([]vk.CommandBuffer, len(r.swapchain_images))

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(len(r.command_buffers)),
	}

	result := vk.AllocateCommandBuffers(r.device, &alloc_info, raw_data(r.command_buffers))
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate command buffers:", result)
		return false
	}

	return true
}

@(private = "file")
create_sync_objects :: proc(r: ^Renderer) -> bool {
	n := len(r.swapchain_images)
	r.image_available = make([]vk.Semaphore, n)
	r.render_finished = make([]vk.Semaphore, n)
	r.in_flight_fences = make([]vk.Fence, n)

	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for i in 0 ..< n {
		if vk.CreateSemaphore(r.device, &sem_info, nil, &r.image_available[i]) != .SUCCESS do return false
		if vk.CreateSemaphore(r.device, &sem_info, nil, &r.render_finished[i]) != .SUCCESS do return false
		if vk.CreateFence(r.device, &fence_info, nil, &r.in_flight_fences[i]) != .SUCCESS do return false
	}

	return true
}

@(private = "file")
create_vertex_index_buffers :: proc(r: ^Renderer) -> bool {
	// Vertex buffer: persistently mapped HOST_VISIBLE
	vb_size := vk.DeviceSize(slug.MAX_GLYPH_VERTICES * size_of(slug.Vertex))
	vb, vm, vb_ok := create_buffer(r, vb_size, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	if !vb_ok do return false
	r.vertex_buffer = vb
	r.vertex_memory = vm

	mapped: rawptr
	if vk.MapMemory(r.device, vm, 0, vb_size, {}, &mapped) != .SUCCESS {
		fmt.eprintln("Failed to map vertex buffer")
		return false
	}
	r.vertex_mapped = cast([^]slug.Vertex)mapped

	// Index buffer: pre-generated quad indices, uploaded once
	indices := generate_quad_indices(slug.MAX_GLYPH_QUADS)
	defer delete(indices)

	ib_size := vk.DeviceSize(len(indices) * size_of(u32))

	staging_buf, staging_mem, staging_ok := create_buffer(
		r,
		ib_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if !staging_ok do return false
	defer vk.DestroyBuffer(r.device, staging_buf, nil)
	defer vk.FreeMemory(r.device, staging_mem, nil)

	staging_mapped: rawptr
	vk.MapMemory(r.device, staging_mem, 0, ib_size, {}, &staging_mapped)
	mem.copy(staging_mapped, raw_data(indices), int(ib_size))
	vk.UnmapMemory(r.device, staging_mem)

	ib, im, ib_ok := create_buffer(r, ib_size, {.INDEX_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL})
	if !ib_ok do return false
	r.index_buffer = ib
	r.index_memory = im

	// Copy staging -> device
	cmd := begin_one_shot_commands(r)
	copy_region := vk.BufferCopy {
		size = ib_size,
	}
	vk.CmdCopyBuffer(cmd, staging_buf, ib, 1, &copy_region)
	end_one_shot_commands(r, cmd)

	return true
}

@(private = "file")
cleanup_swapchain :: proc(r: ^Renderer) {
	for fb in r.framebuffers {
		if fb != 0 do vk.DestroyFramebuffer(r.device, fb, nil)
	}
	delete(r.framebuffers)

	for view in r.swapchain_views {
		if view != 0 do vk.DestroyImageView(r.device, view, nil)
	}
	delete(r.swapchain_views)

	delete(r.swapchain_images)

	if r.swapchain != 0 do vk.DestroySwapchainKHR(r.device, r.swapchain, nil)
}

recreate_swapchain :: proc(r: ^Renderer) -> bool {
	w, h: i32
	sdl.GetWindowSizeInPixels(r.window, &w, &h)
	for w == 0 || h == 0 {
		sdl.GetWindowSizeInPixels(r.window, &w, &h)
		_ = sdl.WaitEvent(nil)
	}

	vk.DeviceWaitIdle(r.device)

	if r.command_buffers != nil {
		vk.FreeCommandBuffers(
			r.device,
			r.command_pool,
			u32(len(r.command_buffers)),
			raw_data(r.command_buffers),
		)
		delete(r.command_buffers)
	}

	cleanup_swapchain(r)

	if !create_swapchain(r, r.window) {
		fmt.eprintln("recreate_swapchain: failed to create swapchain")
		return false
	}
	if !create_image_views(r) {
		fmt.eprintln("recreate_swapchain: failed to create image views")
		return false
	}
	if !create_framebuffers(r) {
		fmt.eprintln("recreate_swapchain: failed to create framebuffers")
		return false
	}
	if !create_command_buffers(r) {
		fmt.eprintln("recreate_swapchain: failed to create command buffers")
		return false
	}

	r.current_frame = 0
	r.framebuffer_resized = false

	return true
}
