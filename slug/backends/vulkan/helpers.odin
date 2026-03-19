package slug_vulkan

import "base:runtime"
import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"

import slug "../.."

// ===================================================
// Vulkan helper functions — buffer, texture, pipeline utilities
// ===================================================

ENABLE_VALIDATION :: #config(ENABLE_VALIDATION, true)

// Vulkan GPU texture handle
GPU_Texture :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView,
	sampler: vk.Sampler,
	width:   u32,
	height:  u32,
}

// --- Memory type selection ---

find_memory_type :: proc(
	r: ^Renderer,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> (
	u32,
	bool,
) {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(r.physical_device, &mem_properties)

	for i in 0 ..< mem_properties.memoryTypeCount {
		type_bit := u32(1) << i
		has_type := (type_filter & type_bit) != 0
		has_props := properties <= mem_properties.memoryTypes[i].propertyFlags
		if has_type && has_props {
			return i, true
		}
	}

	return 0, false
}

// --- Buffer creation ---

create_buffer :: proc(
	r: ^Renderer,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	ok: bool,
) {
	buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	result := vk.CreateBuffer(r.device, &buf_info, nil, &buffer)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create buffer:", result)
		return {}, {}, false
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(r.device, buffer, &mem_requirements)

	mem_type, mem_type_ok := find_memory_type(r, mem_requirements.memoryTypeBits, properties)
	if !mem_type_ok {
		fmt.eprintln("Failed to find suitable memory type for buffer")
		vk.DestroyBuffer(r.device, buffer, nil)
		return {}, {}, false
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = mem_type,
	}

	result = vk.AllocateMemory(r.device, &alloc_info, nil, &memory)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate buffer memory:", result)
		vk.DestroyBuffer(r.device, buffer, nil)
		return {}, {}, false
	}

	result = vk.BindBufferMemory(r.device, buffer, memory, 0)
	if result != .SUCCESS {
		fmt.eprintln("Failed to bind buffer memory:", result)
		vk.FreeMemory(r.device, memory, nil)
		vk.DestroyBuffer(r.device, buffer, nil)
		return {}, {}, false
	}
	return buffer, memory, true
}

// --- One-shot command buffer helpers ---

begin_one_shot_commands :: proc(r: ^Renderer) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	cmd: vk.CommandBuffer
	result := vk.AllocateCommandBuffers(r.device, &alloc_info, &cmd)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate one-shot command buffer:", result)
		return {}
	}

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	result = vk.BeginCommandBuffer(cmd, &begin_info)
	if result != .SUCCESS {
		fmt.eprintln("Failed to begin one-shot command buffer:", result)
		return {}
	}
	return cmd
}

end_one_shot_commands :: proc(r: ^Renderer, cmd: vk.CommandBuffer) {
	vk.EndCommandBuffer(cmd)

	cmd_buf := cmd
	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd_buf,
	}
	vk.QueueSubmit(r.graphics_queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(r.graphics_queue)

	vk.FreeCommandBuffers(r.device, r.command_pool, 1, &cmd_buf)
}

// --- Image layout transitions ---

transition_image_layout :: proc(
	r: ^Renderer,
	image: vk.Image,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
) {
	cmd := begin_one_shot_commands(r)

	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	src_stage, dst_stage: vk.PipelineStageFlags

	if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
		barrier.srcAccessMask = {}
		barrier.dstAccessMask = {.TRANSFER_WRITE}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.TRANSFER}
	} else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstAccessMask = {.SHADER_READ}
		src_stage = {.TRANSFER}
		dst_stage = {.FRAGMENT_SHADER}
	}

	vk.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)

	end_one_shot_commands(r, cmd)
}

// --- GPU texture creation ---

gpu_texture_create :: proc(
	r: ^Renderer,
	width, height: u32,
	format: vk.Format,
	data: rawptr,
	data_size: int,
) -> (
	tex: GPU_Texture,
	ok: bool,
) {
	tex.width = width
	tex.height = height
	image_size := vk.DeviceSize(data_size)

	// Create staging buffer
	staging_buf, staging_mem, staging_ok := create_buffer(
		r,
		image_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if !staging_ok do return {}, false
	defer vk.DestroyBuffer(r.device, staging_buf, nil)
	defer vk.FreeMemory(r.device, staging_mem, nil)

	// Copy data to staging
	mapped: rawptr
	map_result := vk.MapMemory(r.device, staging_mem, 0, image_size, {}, &mapped)
	if map_result != .SUCCESS {
		fmt.eprintln("Failed to map staging memory:", map_result)
		return {}, false
	}
	mem.copy(mapped, data, data_size)
	vk.UnmapMemory(r.device, staging_mem)

	// Create the Vulkan image
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		format        = format,
		tiling        = .OPTIMAL,
		initialLayout = .UNDEFINED,
		usage         = {.TRANSFER_DST, .SAMPLED},
		sharingMode   = .EXCLUSIVE,
		samples       = {._1},
	}

	result := vk.CreateImage(r.device, &image_info, nil, &tex.image)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create image:", result)
		return {}, false
	}

	// Allocate and bind image memory
	mem_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, tex.image, &mem_requirements)

	mem_type, mem_type_ok := find_memory_type(r, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL})
	if !mem_type_ok {
		fmt.eprintln("Failed to find memory type for image")
		vk.DestroyImage(r.device, tex.image, nil)
		return {}, false
	}

	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = mem_type,
	}

	result = vk.AllocateMemory(r.device, &alloc, nil, &tex.memory)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate image memory:", result)
		vk.DestroyImage(r.device, tex.image, nil)
		return {}, false
	}

	result = vk.BindImageMemory(r.device, tex.image, tex.memory, 0)
	if result != .SUCCESS {
		fmt.eprintln("Failed to bind image memory:", result)
		vk.FreeMemory(r.device, tex.memory, nil)
		vk.DestroyImage(r.device, tex.image, nil)
		return {}, false
	}

	// Transition, copy, transition
	transition_image_layout(r, tex.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

	// Copy buffer to image
	{
		cmd := begin_one_shot_commands(r)
		region := vk.BufferImageCopy {
			imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
			imageExtent = {width, height, 1},
		}
		vk.CmdCopyBufferToImage(cmd, staging_buf, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)
		end_one_shot_commands(r, cmd)
	}

	transition_image_layout(r, tex.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

	// Create image view
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = format,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	result = vk.CreateImageView(r.device, &view_info, nil, &tex.view)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create image view:", result)
		gpu_texture_destroy(r, &tex)
		return {}, false
	}

	// Create sampler
	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		mipmapMode   = .NEAREST,
		maxLod       = 0,
	}

	result = vk.CreateSampler(r.device, &sampler_info, nil, &tex.sampler)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create sampler:", result)
		gpu_texture_destroy(r, &tex)
		return {}, false
	}

	return tex, true
}

gpu_texture_destroy :: proc(r: ^Renderer, tex: ^GPU_Texture) {
	if tex.sampler != 0 do vk.DestroySampler(r.device, tex.sampler, nil)
	if tex.view != 0 do vk.DestroyImageView(r.device, tex.view, nil)
	if tex.image != 0 do vk.DestroyImage(r.device, tex.image, nil)
	if tex.memory != 0 do vk.FreeMemory(r.device, tex.memory, nil)
	tex^ = {}
}

// --- Shader module creation ---

create_shader_module :: proc(r: ^Renderer, code: []u8) -> (vk.ShaderModule, bool) {
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}

	mod: vk.ShaderModule
	result := vk.CreateShaderModule(r.device, &create_info, nil, &mod)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create shader module:", result)
		return {}, false
	}

	return mod, true
}

// --- Validation layer debug callback ---

when ENABLE_VALIDATION {
	debug_callback :: proc "system" (
		severity: vk.DebugUtilsMessageSeverityFlagsEXT,
		types: vk.DebugUtilsMessageTypeFlagsEXT,
		callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
		user_data: rawptr,
	) -> b32 {
		context = #force_inline runtime_default_context()
		if .ERROR in severity {
			fmt.eprintln("VK ERROR:", callback_data.pMessage)
		} else {
			fmt.eprintln("VK WARN:", callback_data.pMessage)
		}
		return false
	}

	@(private = "file")
	runtime_default_context :: #force_inline proc "contextless" () -> runtime.Context {
		return runtime.default_context()
	}
}

// --- Index buffer generation ---

generate_quad_indices :: proc(max_quads: int, allocator := context.allocator) -> []u32 {
	indices := make([]u32, max_quads * slug.INDICES_PER_QUAD, allocator)
	for i in 0 ..< max_quads {
		base_vertex := u32(i * slug.VERTICES_PER_QUAD)
		base_index := i * slug.INDICES_PER_QUAD
		indices[base_index + 0] = base_vertex + 0
		indices[base_index + 1] = base_vertex + 1
		indices[base_index + 2] = base_vertex + 2
		indices[base_index + 3] = base_vertex + 2
		indices[base_index + 4] = base_vertex + 3
		indices[base_index + 5] = base_vertex + 0
	}
	return indices
}
