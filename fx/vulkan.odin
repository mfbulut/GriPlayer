package fx

import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:sys/windows"
import "base:runtime"
import vk "vendor:vulkan"
import stbi "vendor:stb/image"

MAX_TEXTURES :: 1024
MAX_INSTANCES :: 1024 * 16

vks: struct {
	instance: vk.Instance,
	physical_device: vk.PhysicalDevice,
	device: vk.Device,
	graphics_queue: vk.Queue,

	surface: vk.SurfaceKHR,
	swapchain: struct {
		swapchain: vk.SwapchainKHR,
		images: [2]vk.Image,
		image_views: [2]vk.ImageView,
		render_finished_semaphores: [2]vk.Semaphore,
	},

	command_pool: vk.CommandPool,
	command_buffer: vk.CommandBuffer,

	image_available_semaphore: vk.Semaphore,
	in_flight_fence: vk.Fence,

	pipeline_layout: vk.PipelineLayout,
	shaders: [2]vk.ShaderEXT,
	sampler: vk.Sampler,

	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set: vk.DescriptorSet,
	instance_buffer_mapped: rawptr,
	clear_color: [4]f32,
}

Texture_Data :: struct {
	index: int,
	size: [2]int,
	image: vk.Image,
	view: vk.ImageView,
	memory: vk.DeviceMemory,
	layout: vk.ImageLayout,
	used: bool,
}

Texture :: ^Texture_Data
textures: [MAX_TEXTURES]Texture_Data

check_vk :: proc(result: vk.Result) {
	if result != .SUCCESS {
		fmt.eprintf("Vulkan Error: %v\n", result)
		panic("Vulkan Error")
	}
}

vk_init :: proc() {
	{	// Load vulkan-1.dll
		lib := dynlib.load_library("vulkan-1.dll") or_else panic("Failed to load vulkan-1.dll")
		vkGetInstanceProcAddr := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
		vk.load_proc_addresses(vkGetInstanceProcAddr)
	}

	{	// Create Instance
		app_info := vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "GriPlayer",
			apiVersion = vk.API_VERSION_1_3,
		}

		when ODIN_DEBUG {
			layer_count := u32(1)
			val_layer := cstring("VK_LAYER_KHRONOS_validation")
			layer_names := &val_layer

			extensions := [?]cstring {
				vk.KHR_SURFACE_EXTENSION_NAME,
				vk.KHR_WIN32_SURFACE_EXTENSION_NAME,
				vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
			}
		} else {
			layer_count: u32
			layer_names: ^cstring
			extensions := [?]cstring {
				vk.KHR_SURFACE_EXTENSION_NAME,
				vk.KHR_WIN32_SURFACE_EXTENSION_NAME,
			}
		}

		create_info := vk.InstanceCreateInfo {
			sType = .INSTANCE_CREATE_INFO,
			pApplicationInfo = &app_info,
			enabledExtensionCount =  u32(len(extensions)),
			ppEnabledExtensionNames = &extensions[0],
			enabledLayerCount = layer_count,
			ppEnabledLayerNames = layer_names,
		}

		when ODIN_DEBUG {
			debug_callback :: proc "system" (
				messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
				messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
				pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
				pUserData: rawptr,
			) -> b32 {
				context = runtime.default_context()
				fmt.eprintf("Vulkan Validation: %s\n", pCallbackData.pMessage)
				return false
			}

			debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
				sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
				messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
				messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
				pfnUserCallback = debug_callback,
			}
			create_info.pNext = &debug_info
		}

		vk.CreateInstance(&create_info, nil, &vks.instance)
		vk.load_proc_addresses(vks.instance)

		when ODIN_DEBUG {
			debug_messenger: vk.DebugUtilsMessengerEXT
			vk.CreateDebugUtilsMessengerEXT(vks.instance, &debug_info, nil, &debug_messenger)
		}
	}

	{	// Create Surface
		surface_create_info := vk.Win32SurfaceCreateInfoKHR {
			sType = .WIN32_SURFACE_CREATE_INFO_KHR,
			hinstance = cast(windows.HINSTANCE)windows.GetModuleHandleW(nil),
			hwnd = window.hwnd,
		}
		vk.CreateWin32SurfaceKHR(vks.instance, &surface_create_info, nil, &vks.surface)
	}

	{	// Pick Physical Device
		device_count: u32
		vk.EnumeratePhysicalDevices(vks.instance, &device_count, nil)
		devices := make([]vk.PhysicalDevice, device_count)
		defer delete(devices)
		vk.EnumeratePhysicalDevices(vks.instance, &device_count, &devices[0])

		vks.physical_device = devices[0]
		for d in devices {
			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(d, &props)
			if props.deviceType == .DISCRETE_GPU {
				vks.physical_device = d
				break
			}
		}
	}

	{	// Create Logical Device
		queue_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(vks.physical_device, &queue_count, nil)
		queue_families := make([]vk.QueueFamilyProperties, queue_count)
		defer delete(queue_families)
		vk.GetPhysicalDeviceQueueFamilyProperties(vks.physical_device, &queue_count, &queue_families[0])
		queue_family_index: u32
		for queue_family, i in queue_families {
			if .GRAPHICS in queue_family.queueFlags {
				queue_family_index = u32(i)
				break
			}
		}	

		queue_priority := f32(1.0)
		queue_create_info := vk.DeviceQueueCreateInfo {
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_family_index,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		}

		shader_object_features := vk.PhysicalDeviceShaderObjectFeaturesEXT {
			sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
			shaderObject = true,
		}

		features_13 := vk.PhysicalDeviceVulkan13Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			pNext = &shader_object_features,
			dynamicRendering = true,
			synchronization2 = true,
		}

		features_12 := vk.PhysicalDeviceVulkan12Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			pNext = &features_13,
			descriptorIndexing = true,
			descriptorBindingPartiallyBound = true,
			descriptorBindingSampledImageUpdateAfterBind = true,
			runtimeDescriptorArray = true,
			shaderSampledImageArrayNonUniformIndexing = true,
		}

		device_extensions := [?]cstring {
			vk.KHR_SWAPCHAIN_EXTENSION_NAME,
			vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
		}

		device_create_info := vk.DeviceCreateInfo {
			sType = .DEVICE_CREATE_INFO,
			pNext = &features_12,
			queueCreateInfoCount = 1,
			pQueueCreateInfos = &queue_create_info,
			enabledExtensionCount = len(device_extensions),
			ppEnabledExtensionNames = &device_extensions[0],
		}

		vk.CreateDevice(vks.physical_device, &device_create_info, nil, &vks.device)
		vk.load_proc_addresses(vks.device)
		vk.GetDeviceQueue(vks.device, queue_family_index, 0, &vks.graphics_queue)

		pool_info := vk.CommandPoolCreateInfo {
			sType = .COMMAND_POOL_CREATE_INFO,
			flags = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = queue_family_index,
		}
		vk.CreateCommandPool(vks.device, &pool_info, nil, &vks.command_pool)
	}

	{	// Sync objects
		semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
		fence_info := vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = {.SIGNALED} }

		alloc_info := vk.CommandBufferAllocateInfo {
			sType = .COMMAND_BUFFER_ALLOCATE_INFO,
			level = .PRIMARY,
			commandPool = vks.command_pool,
			commandBufferCount = 1,
		}
		vk.AllocateCommandBuffers(vks.device, &alloc_info, &vks.command_buffer)
		vk.CreateSemaphore(vks.device, &semaphore_info, nil, &vks.image_available_semaphore)
		vk.CreateFence(vks.device, &fence_info, nil, &vks.in_flight_fence)
	}

	{	// Sampler
		
		sampler_info := vk.SamplerCreateInfo {
			sType = .SAMPLER_CREATE_INFO,
			magFilter = .LINEAR,
			minFilter = .LINEAR,
			addressModeU = .CLAMP_TO_EDGE,
			addressModeV = .CLAMP_TO_EDGE,
			addressModeW = .CLAMP_TO_EDGE,
			maxLod = vk.LOD_CLAMP_NONE,
		}
		vk.CreateSampler(vks.device, &sampler_info, nil, &vks.sampler)
	}

	{	// Bindless Descriptor Setup
		
		binding_flags := [?]vk.DescriptorBindingFlags {
			{.UPDATE_AFTER_BIND, .PARTIALLY_BOUND},
			{},
		}
		layout_binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
			bindingCount = 2,
			pBindingFlags = &binding_flags[0],
		}
		bindings := [?]vk.DescriptorSetLayoutBinding {
			{
				binding = 0,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				descriptorCount = MAX_TEXTURES,
				stageFlags = {.FRAGMENT},
			},
			{
				binding = 1,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				stageFlags = {.VERTEX},
			},
		}
		layout_info := vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			pNext = &layout_binding_flags,
			flags = {.UPDATE_AFTER_BIND_POOL},
			bindingCount = 2,
			pBindings = &bindings[0],
		}
		check_vk(vk.CreateDescriptorSetLayout(vks.device, &layout_info, nil, &vks.descriptor_set_layout))

		pool_sizes := [?]vk.DescriptorPoolSize {
			{ type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_TEXTURES },
			{ type = .STORAGE_BUFFER, descriptorCount = 1 },
		}
		desc_pool_info := vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			flags = {.UPDATE_AFTER_BIND},
			maxSets = 1,
			poolSizeCount = 2,
			pPoolSizes = &pool_sizes[0],
		}
		descriptor_pool: vk.DescriptorPool
		check_vk(vk.CreateDescriptorPool(vks.device, &desc_pool_info, nil, &descriptor_pool))

		alloc_set_info := vk.DescriptorSetAllocateInfo {
			sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts = &vks.descriptor_set_layout,
		}
		check_vk(vk.AllocateDescriptorSets(vks.device, &alloc_set_info, &vks.descriptor_set))
	}

	{	// Instance Buffer
		buffer, memory := create_buffer(
			vk.DeviceSize(MAX_INSTANCES * size_of(Instance)),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk.MapMemory(vks.device, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &vks.instance_buffer_mapped)

		// Bind SSBO to descriptor set
		buffer_info := vk.DescriptorBufferInfo {
			buffer = buffer,
			range = vk.DeviceSize(vk.WHOLE_SIZE),
		}

		write_desc := vk.WriteDescriptorSet {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = vks.descriptor_set,
			dstBinding = 1,
			dstArrayElement = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo = &buffer_info,
		}

		vk.UpdateDescriptorSets(vks.device, 1, &write_desc, 0, nil)
	}

	{	// Create Pipeline
		vert_spv := #load("shader/shader.vert.spv", []u32)
		frag_spv := #load("shader/shader.frag.spv", []u32)

		push_constant_range := vk.PushConstantRange {
			stageFlags = {.VERTEX},
			size = size_of([2]f32),
		}

		pipeline_layout_info := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = 1,
			pSetLayouts = &vks.descriptor_set_layout,
			pushConstantRangeCount = 1,
			pPushConstantRanges = &push_constant_range,
		}

		check_vk(vk.CreatePipelineLayout(vks.device, &pipeline_layout_info, nil, &vks.pipeline_layout))

		shader_infos := [?]vk.ShaderCreateInfoEXT{
			{
				sType = .SHADER_CREATE_INFO_EXT,
				stage = {.VERTEX},
				nextStage = {.FRAGMENT},
				codeType = .SPIRV,
				codeSize = len(vert_spv) * 4,
				pCode = raw_data(vert_spv),
				pName = "main",
				setLayoutCount = 1,
				pSetLayouts = &vks.descriptor_set_layout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &push_constant_range,
			},
			{
				sType = .SHADER_CREATE_INFO_EXT,
				stage = {.FRAGMENT},
				nextStage = {},
				codeType = .SPIRV,
				codeSize = len(frag_spv) * 4,
				pCode = raw_data(frag_spv),
				pName = "main",
				setLayoutCount = 1,
				pSetLayouts = &vks.descriptor_set_layout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &push_constant_range,
			}
		}

		check_vk(vk.CreateShadersEXT(vks.device, 2, &shader_infos[0], nil, &vks.shaders[0]))
	}

	vk_recreate_swapchain()
}

vk_recreate_swapchain :: proc() {
	vk.DeviceWaitIdle(vks.device)

	if vks.swapchain.swapchain != 0 {
		for view in vks.swapchain.image_views {
			if view != 0 do vk.DestroyImageView(vks.device, view, nil)
		}
		for semaphore in vks.swapchain.render_finished_semaphores {
			if semaphore != 0 do vk.DestroySemaphore(vks.device, semaphore, nil)
		}
	}

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vks.physical_device, vks.surface, &capabilities)

	create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = vks.surface,
		minImageCount = max(capabilities.minImageCount, 2),
		imageFormat = .B8G8R8A8_UNORM,
		imageColorSpace = .SRGB_NONLINEAR,
		imageExtent = {window.size.x, window.size.y},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform = capabilities.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		clipped = true,
		oldSwapchain = vks.swapchain.swapchain,
	}

	new_swapchain: vk.SwapchainKHR
	vk.CreateSwapchainKHR(vks.device, &create_info, nil, &new_swapchain)

	if vks.swapchain.swapchain != 0 {
		vk.DestroySwapchainKHR(vks.device, vks.swapchain.swapchain, nil)
	}
	vks.swapchain.swapchain = new_swapchain

	image_count: u32 = 2
	vk.GetSwapchainImagesKHR(vks.device, vks.swapchain.swapchain, &image_count, &vks.swapchain.images[0])

	semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for i in 0..<image_count {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = vks.swapchain.images[i],
			viewType = .D2,
			format = .B8G8R8A8_UNORM,
			subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
		}
		vk.CreateImageView(vks.device, &view_info, nil, &vks.swapchain.image_views[i])
		vk.CreateSemaphore(vks.device, &semaphore_info, nil, &vks.swapchain.render_finished_semaphores[i])
	}
}

vk_render :: proc() {
	vk.WaitForFences(vks.device, 1, &vks.in_flight_fence, true, max(u64))

	image_index: u32
	res := vk.AcquireNextImageKHR(
		vks.device, vks.swapchain.swapchain, max(u64),
		vks.image_available_semaphore,
		0, &image_index,
	)

	if res == .ERROR_OUT_OF_DATE_KHR {
		return
	}

	vk.ResetFences(vks.device, 1, &vks.in_flight_fence)

	cmd := vks.command_buffer
	vk.ResetCommandBuffer(cmd, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	image_barrier(
		cmd, vks.swapchain.images[image_index],
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE}, {.COLOR_ATTACHMENT_OUTPUT},
		{}, {.COLOR_ATTACHMENT_WRITE},
	)

	color_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = vks.swapchain.image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue { color = { float32 = vks.clear_color } },
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = { extent = {window.size.x, window.size.y} },
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	stages := [?]vk.ShaderStageFlags{{.VERTEX}, {.FRAGMENT}}
	vk.CmdBindShadersEXT(cmd, 2, &stages[0], &vks.shaders[0])

	viewport := vk.Viewport {
		width = f32(window.size.x),
		height = f32(window.size.y),
		minDepth = 0.0, maxDepth = 1.0,
	}
	vk.CmdSetViewportWithCount(cmd, 1, &viewport)

	vk.CmdSetVertexInputEXT(cmd, 0, nil, 0, nil)
	vk.CmdSetPrimitiveTopology(cmd, .TRIANGLE_STRIP)
	vk.CmdSetPrimitiveRestartEnable(cmd, false)
	vk.CmdSetRasterizerDiscardEnable(cmd, false)
	vk.CmdSetPolygonModeEXT(cmd, .FILL)
	vk.CmdSetCullMode(cmd, {})
	vk.CmdSetFrontFace(cmd, .CLOCKWISE)
	vk.CmdSetDepthTestEnable(cmd, false)
	vk.CmdSetDepthWriteEnable(cmd, false)
	vk.CmdSetDepthBiasEnable(cmd, false)
	vk.CmdSetStencilTestEnable(cmd, false)
	vk.CmdSetRasterizationSamplesEXT(cmd, {._1})
	vk.CmdSetAlphaToCoverageEnableEXT(cmd, false)

	sample_mask := [?]vk.SampleMask{0xffffffff}
	vk.CmdSetSampleMaskEXT(cmd, {._1}, &sample_mask[0])

	color_blend_enable := [?]b32{true}
	vk.CmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enable[0])

	color_blend_eq := [?]vk.ColorBlendEquationEXT{{
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp = .ADD,
	}}
	vk.CmdSetColorBlendEquationEXT(cmd, 0, 1, &color_blend_eq[0])

	color_write_mask := [?]vk.ColorComponentFlags{{.R, .G, .B, .A}}
	vk.CmdSetColorWriteMaskEXT(cmd, 0, 1, &color_write_mask[0])

	screen_size := window_size()
	vk.CmdPushConstants(cmd, vks.pipeline_layout, {.VERTEX}, 0, size_of(screen_size), &screen_size)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, vks.pipeline_layout, 0, 1, &vks.descriptor_set, 0, nil)

	if len(instances) > 0 {
		if u32(len(instances)) > MAX_INSTANCES {
			panic("Instance buffer overflow")
		}

		dst := cast(rawptr)(uintptr(vks.instance_buffer_mapped))
		mem.copy(dst, raw_data(instances[:]), len(instances) * size_of(Instance))

		for b in batches {
			if b.count == 0 do continue
			rect := vk.Rect2D {
				offset = {b.scissor[0], b.scissor[1]},
				extent = {u32(b.scissor[2]), u32(b.scissor[3])},
			}

			vk.CmdSetScissorWithCount(cmd, 1, &rect)
			vk.CmdDraw(cmd, 4, b.count, 0, b.offset)
		}
	}

	vk.CmdEndRendering(cmd)

	image_barrier(
		cmd, vks.swapchain.images[image_index],
		.COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT}, {.ALL_COMMANDS},
		{.COLOR_ATTACHMENT_WRITE}, {},
	)
	vk.EndCommandBuffer(cmd)

	render_finished_semaphore := &vks.swapchain.render_finished_semaphores[image_index]
	cmd_info := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	wait_info := vk.SemaphoreSubmitInfo {
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = vks.image_available_semaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal_info := vk.SemaphoreSubmitInfo {
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = render_finished_semaphore^,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount = 1,
		pWaitSemaphoreInfos = &wait_info,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos = &signal_info,
	}
	vk.QueueSubmit2(vks.graphics_queue, 1, &submit_info, vks.in_flight_fence)

	present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = render_finished_semaphore,
		swapchainCount = 1,
		pSwapchains = &vks.swapchain.swapchain,
		pImageIndices = &image_index,
	}

	vk.QueuePresentKHR(vks.graphics_queue, &present_info)

	clear(&instances)
	clear(&batches)
}

find_memory_type :: proc(type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(vks.physical_device, &mem_properties)
	for i in 0..<mem_properties.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return i
		}
	}
	panic("Failed to find suitable memory type!")
}

create_buffer :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) -> (buffer: vk.Buffer, buffer_memory: vk.DeviceMemory) {
	buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
		sharingMode = .EXCLUSIVE,
	}
	vk.CreateBuffer(vks.device, &buffer_info, nil, &buffer)

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(vks.device, buffer, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, properties),
	}

	vk.AllocateMemory(vks.device, &alloc_info, nil, &buffer_memory)
	vk.BindBufferMemory(vks.device, buffer, buffer_memory, 0)
	return
}

image_barrier :: proc(
	cmd: vk.CommandBuffer, image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	dep_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

texture_load :: proc(data: []u8) -> Texture {
	w, h, channels: i32
	pixels := cast([^]Color)stbi.load_from_memory(raw_data(data), cast(i32)len(data), &w, &h, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil do return nil

	tex := texture_create(int(w), int(h))
	texture_update(tex, pixels[:w*h], 0, 0, int(w), int(h))

	return tex
}

texture_create :: proc(w, h: int) -> Texture {
	index := -1
	for &tex, i in textures {
		if !tex.used {
			index = i
			tex.used = true
			break
		}
	}

	if index == -1 do panic("Too many textures")

	tex := &textures[index]

	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		extent = { u32(w), u32(h), 1 },
		mipLevels = 1,
		arrayLayers = 1,
		format = .R8G8B8A8_UNORM,
		tiling = .OPTIMAL,
		initialLayout = .UNDEFINED,
		usage = {.TRANSFER_DST, .SAMPLED},
		samples = {._1},
		sharingMode = .EXCLUSIVE,
	}

	check_vk(vk.CreateImage(vks.device, &image_info, nil, &tex.image))

	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vks.device, tex.image, &mem_reqs)

	alloc_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = mem_reqs.size,
		memoryTypeIndex = find_memory_type(mem_reqs.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	check_vk(vk.AllocateMemory(vks.device, &alloc_info, nil, &tex.memory))
	vk.BindImageMemory(vks.device, tex.image, tex.memory, 0)

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = .R8G8B8A8_UNORM,
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	check_vk(vk.CreateImageView(vks.device, &view_info, nil, &tex.view))

	// Update descriptor set
	image_info_desc := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView = tex.view,
		sampler = vks.sampler,
	}
	write_desc := vk.WriteDescriptorSet {
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = vks.descriptor_set,
		dstBinding = 0,
		dstArrayElement = u32(index),
		descriptorType = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		pImageInfo = &image_info_desc,
	}
	vk.UpdateDescriptorSets(vks.device, 1, &write_desc, 0, nil)

	tex.index = index
	tex.size = {w, h}
	return tex
}

texture_update :: proc(tex: Texture, pixels: []Color, x, y, w, h: int) {
	if tex == nil || tex.index < 0 || tex.index >= MAX_TEXTURES do return

	size := vk.DeviceSize(w * h * 4)
	buffer, buffer_memory := create_buffer(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})

	data: rawptr
	vk.MapMemory(vks.device, buffer_memory, 0, size, {}, &data)
	mem.copy(data, raw_data(pixels), int(size))
	vk.UnmapMemory(vks.device, buffer_memory)

	alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = vks.command_pool,
		commandBufferCount = 1,
	}

	cmd: vk.CommandBuffer
	vk.AllocateCommandBuffers(vks.device, &alloc_info, &cmd)

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	image_barrier(
		cmd, tex.image,
		tex.layout, .TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE}, {.TRANSFER},
		{}, {.TRANSFER_WRITE},
	)

	region := vk.BufferImageCopy {
		imageSubresource = { aspectMask = {.COLOR}, layerCount = 1 },
		imageOffset = { i32(x), i32(y), 0 },
		imageExtent = { u32(w), u32(h), 1 },
	}
	vk.CmdCopyBufferToImage(cmd, buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

	image_barrier(
		cmd, tex.image,
		.TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER}, {.FRAGMENT_SHADER},
		{.TRANSFER_WRITE}, {.SHADER_READ},
	)

	vk.EndCommandBuffer(cmd)

	cmd_info := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &cmd_info,
	}
	vk.QueueSubmit2(vks.graphics_queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(vks.graphics_queue)

	vk.FreeCommandBuffers(vks.device, vks.command_pool, 1, &cmd)

	vk.DestroyBuffer(vks.device, buffer, nil)
	vk.FreeMemory(vks.device, buffer_memory, nil)

	tex.layout = .SHADER_READ_ONLY_OPTIMAL
}

texture_free :: proc(tex_ptr: ^Texture) {
	if tex_ptr == nil || tex_ptr^ == nil do return
	tex := tex_ptr^
	
	vk.DeviceWaitIdle(vks.device)
	if tex.used {
		vk.DestroyImageView(vks.device, tex.view, nil)
		vk.DestroyImage(vks.device, tex.image, nil)
		vk.FreeMemory(vks.device, tex.memory, nil)
		tex^ = {}
	}
	
	tex_ptr^ = nil
}
