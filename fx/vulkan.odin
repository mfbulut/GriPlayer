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
	physical_device: vk.PhysicalDevice,
	device: vk.Device,
	graphics_queue: vk.Queue,

	surface: vk.SurfaceKHR,
	swapchain: vk.SwapchainKHR,
	swapchain_format: vk.Format,
	swapchain_extent: vk.Extent2D,
	swapchain_images: []vk.Image,
	swapchain_image_views: []vk.ImageView,

	command_pool: vk.CommandPool,
	command_buffer: vk.CommandBuffer,
	image_available_semaphore: vk.Semaphore,
	render_finished_semaphores: []vk.Semaphore,
	in_flight_fence: vk.Fence,

	pipeline_layout: vk.PipelineLayout,
	vert_shader: vk.ShaderEXT,
	frag_shader: vk.ShaderEXT,

	descriptor_set: vk.DescriptorSet,
	instance_buffer_mapped: rawptr,
	
	clear_color: [4]f32,
	sampler: vk.Sampler,
	instance_count: u32,
	image_index: u32,
}

textures: [MAX_TEXTURES]struct {
	image: vk.Image,
	view: vk.ImageView,
	memory: vk.DeviceMemory,
	used: bool,
}

textures_to_free: [dynamic]int

check_vk :: proc(result: vk.Result) {
	if result != .SUCCESS {
		fmt.eprintf("Vulkan Error: %v\n", result)
		panic("Vulkan Error")
	}
}

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

vk_init :: proc() {
	lib, ok := dynlib.load_library("vulkan-1.dll")
	if !ok {
		panic("Failed to load vulkan-1.dll")
	}

	vkGetInstanceProcAddr := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	vk.load_proc_addresses(vkGetInstanceProcAddr)

	// Create Instance
	app_info := vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		pApplicationName = "GriPlayer",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName = "No Engine",
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_3,
	}

	extensions := [?]cstring {
		vk.KHR_SURFACE_EXTENSION_NAME,
		vk.KHR_WIN32_SURFACE_EXTENSION_NAME,
		vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
	}

	layer_count: u32
	layer_names: ^cstring
	when ODIN_DEBUG {
		layer_count = 1
		val_layer: cstring = "VK_LAYER_KHRONOS_validation"
		layer_names = &val_layer
	}

	create_info := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = &extensions[0],
		enabledLayerCount = layer_count,
		ppEnabledLayerNames = layer_names,
	}

	when ODIN_DEBUG {
		debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = debug_callback,
		}
		create_info.pNext = &debug_info
	}

	instance: vk.Instance
	check_vk(vk.CreateInstance(&create_info, nil, &instance))
	vk.load_proc_addresses_instance(instance)
	
	when ODIN_DEBUG {
		debug_messenger: vk.DebugUtilsMessengerEXT
		vk.CreateDebugUtilsMessengerEXT(instance, &debug_info, nil, &debug_messenger)
	}

	// Create Surface
	surface_create_info := vk.Win32SurfaceCreateInfoKHR {
		sType = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = cast(windows.HINSTANCE)windows.GetModuleHandleW(nil),
		hwnd = window.hwnd,
	}
	check_vk(vk.CreateWin32SurfaceKHR(instance, &surface_create_info, nil, &vks.surface))

	// Pick Physical Device
	device_count: u32
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)
	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(instance, &device_count, &devices[0])
	vks.physical_device = devices[0]

	// Find Queue Family
	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(vks.physical_device, &queue_count, nil)
	queue_families := make([]vk.QueueFamilyProperties, queue_count)
	defer delete(queue_families)
	vk.GetPhysicalDeviceQueueFamilyProperties(vks.physical_device, &queue_count, &queue_families[0])

	graphics_family: u32
	for i in 0..<queue_count {
		if .GRAPHICS in queue_families[i].queueFlags {
			graphics_family = i
			break
		}
	}

	// Create Logical Device
	queue_priority := f32(1.0)
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = graphics_family,
		queueCount = 1,
		pQueuePriorities = &queue_priority,
	}

	device_extensions := [?]cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
	}

	features := vk.PhysicalDeviceFeatures {
		samplerAnisotropy = true,
	}

	features_13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}

	features_shader_obj := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext = &features_13,
		shaderObject = true,
	}

	features_12 := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &features_shader_obj,
		descriptorIndexing = true,
		descriptorBindingPartiallyBound = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
		runtimeDescriptorArray = true,
		shaderSampledImageArrayNonUniformIndexing = true,
	}

	device_create_info := vk.DeviceCreateInfo {
		sType = .DEVICE_CREATE_INFO,
		pNext = &features_12,
		queueCreateInfoCount = 1,
		pQueueCreateInfos = &queue_create_info,
		enabledExtensionCount = len(device_extensions),
		ppEnabledExtensionNames = &device_extensions[0],
		pEnabledFeatures = &features,
	}

	check_vk(vk.CreateDevice(vks.physical_device, &device_create_info, nil, &vks.device))
	vk.load_proc_addresses_device(vks.device)

	vk.GetDeviceQueue(vks.device, graphics_family, 0, &vks.graphics_queue)

	// Command Pool
	pool_info := vk.CommandPoolCreateInfo {
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = graphics_family,
	}
	check_vk(vk.CreateCommandPool(vks.device, &pool_info, nil, &vks.command_pool))

	// Sync objects
	semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	fence_info := vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = {.SIGNALED} }

	alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = vks.command_pool,
		level = .PRIMARY,
		commandBufferCount = 1,
	}
	check_vk(vk.AllocateCommandBuffers(vks.device, &alloc_info, &vks.command_buffer))
	check_vk(vk.CreateSemaphore(vks.device, &semaphore_info, nil, &vks.image_available_semaphore))
	check_vk(vk.CreateFence(vks.device, &fence_info, nil, &vks.in_flight_fence))

	// Instance Buffer
	instance_buffer: vk.Buffer
	instance_buffer_memory: vk.DeviceMemory
	create_buffer(
		vk.DeviceSize(MAX_INSTANCES * size_of(Instance)),
		{.STORAGE_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
		&instance_buffer,
		&instance_buffer_memory,
	)
	vk.MapMemory(vks.device, instance_buffer_memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &vks.instance_buffer_mapped)

	// Sampler
	sampler_info := vk.SamplerCreateInfo {
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .LINEAR,
		minFilter = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		anisotropyEnable = true,
		maxAnisotropy = 16,
		maxLod = vk.LOD_CLAMP_NONE,
	}
	vk.CreateSampler(vks.device, &sampler_info, nil, &vks.sampler)

	// Bindless Descriptor Setup
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
	binding_flags := [?]vk.DescriptorBindingFlags {
		{.UPDATE_AFTER_BIND, .PARTIALLY_BOUND},
		{},
	}
	layout_binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount = 2,
		pBindingFlags = &binding_flags[0],
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext = &layout_binding_flags,
		flags = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = 2,
		pBindings = &bindings[0],
	}
	descriptor_set_layout: vk.DescriptorSetLayout
	check_vk(vk.CreateDescriptorSetLayout(vks.device, &layout_info, nil, &descriptor_set_layout))

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
		pSetLayouts = &descriptor_set_layout,
	}
	check_vk(vk.AllocateDescriptorSets(vks.device, &alloc_set_info, &vks.descriptor_set))

	// Bind SSBO to descriptor set
	buffer_info := vk.DescriptorBufferInfo {
		buffer = instance_buffer,
		offset = 0,
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

	init_pipeline(descriptor_set_layout)
}

init_pipeline :: proc(desc_layout: vk.DescriptorSetLayout) {
	desc_layout := desc_layout
	vert_spv_raw := #load("shader/shader.vert.spv")
	frag_spv_raw := #load("shader/shader.frag.spv")
	vert_spv := make([]u8, len(vert_spv_raw))
	frag_spv := make([]u8, len(frag_spv_raw))
	defer { delete(vert_spv); delete(frag_spv) }
	mem.copy(raw_data(vert_spv), raw_data(vert_spv_raw), len(vert_spv_raw))
	mem.copy(raw_data(frag_spv), raw_data(frag_spv_raw), len(frag_spv_raw))

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset = 0,
		size = size_of([2]f32),
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_constant_range,
	}
	check_vk(vk.CreatePipelineLayout(vks.device, &pipeline_layout_info, nil, &vks.pipeline_layout))

	vert_create_info := vk.ShaderCreateInfoEXT {
		sType = .SHADER_CREATE_INFO_EXT,
		flags = {.LINK_STAGE},
		stage = {.VERTEX},
		nextStage = {.FRAGMENT},
		codeType = .SPIRV,
		codeSize = len(vert_spv),
		pCode = raw_data(vert_spv),
		pName = "main",
		setLayoutCount = 1,
		pSetLayouts = &desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_constant_range,
	}

	frag_create_info := vk.ShaderCreateInfoEXT {
		sType = .SHADER_CREATE_INFO_EXT,
		flags = {.LINK_STAGE},
		stage = {.FRAGMENT},
		codeType = .SPIRV,
		codeSize = len(frag_spv),
		pCode = raw_data(frag_spv),
		pName = "main",
		setLayoutCount = 1,
		pSetLayouts = &desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_constant_range,
	}

	create_infos := [?]vk.ShaderCreateInfoEXT{vert_create_info, frag_create_info}
	shaders: [2]vk.ShaderEXT
	
	check_vk(vk.CreateShadersEXT(vks.device, 2, &create_infos[0], nil, &shaders[0]))
	
	vks.vert_shader = shaders[0]
	vks.frag_shader = shaders[1]
}

vk_recreate_swapchain :: proc(w, h: u32) {
	vk.DeviceWaitIdle(vks.device)

	if vks.swapchain != 0 {
		for view in vks.swapchain_image_views {
			vk.DestroyImageView(vks.device, view, nil)
		}
		for semaphore in vks.render_finished_semaphores {
			vk.DestroySemaphore(vks.device, semaphore, nil)
		}
		delete(vks.swapchain_images)
		delete(vks.swapchain_image_views)
		delete(vks.render_finished_semaphores)
	}

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vks.physical_device, vks.surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(vks.physical_device, vks.surface, &format_count, nil)
	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(vks.physical_device, vks.surface, &format_count, &formats[0])

	vks.swapchain_format = formats[0].format
	vks.swapchain_extent = {w, h}

	create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = vks.surface,
		minImageCount = max(capabilities.minImageCount, 2),
		imageFormat = vks.swapchain_format,
		imageColorSpace = formats[0].colorSpace,
		imageExtent = vks.swapchain_extent,
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform = capabilities.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		clipped = true,
		oldSwapchain = vks.swapchain,
	}

	new_swapchain: vk.SwapchainKHR
	check_vk(vk.CreateSwapchainKHR(vks.device, &create_info, nil, &new_swapchain))
	if vks.swapchain != 0 {
		vk.DestroySwapchainKHR(vks.device, vks.swapchain, nil)
	}
	vks.swapchain = new_swapchain

	image_count: u32
	vk.GetSwapchainImagesKHR(vks.device, vks.swapchain, &image_count, nil)
	vks.swapchain_images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(vks.device, vks.swapchain, &image_count, &vks.swapchain_images[0])

	vks.swapchain_image_views = make([]vk.ImageView, image_count)
	vks.render_finished_semaphores = make([]vk.Semaphore, image_count)
	semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for i in 0..<image_count {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = vks.swapchain_images[i],
			viewType = .D2,
			format = vks.swapchain_format,
			subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
		}
		vk.CreateImageView(vks.device, &view_info, nil, &vks.swapchain_image_views[i])
		check_vk(vk.CreateSemaphore(vks.device, &semaphore_info, nil, &vks.render_finished_semaphores[i]))
	}
}

vk_begin_frame :: proc() -> bool {
	vk.WaitForFences(vks.device, 1, &vks.in_flight_fence, true, max(u64))

	res := vk.AcquireNextImageKHR(
		vks.device, vks.swapchain, max(u64),
		vks.image_available_semaphore,
		0, &vks.image_index,
	)
	if res == .ERROR_OUT_OF_DATE_KHR {
		return false
	}

	vk.ResetFences(vks.device, 1, &vks.in_flight_fence)

	cmd := vks.command_buffer
	vk.ResetCommandBuffer(cmd, {})
	vks.instance_count = 0

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.TOP_OF_PIPE},
		srcAccessMask = {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .COLOR_ATTACHMENT_OPTIMAL,
		image = vks.swapchain_images[vks.image_index],
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	dep_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	color_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = vks.swapchain_image_views[vks.image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue { color = { float32 = vks.clear_color } },
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = { extent = vks.swapchain_extent },
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	stages := [?]vk.ShaderStageFlags{{.VERTEX}, {.FRAGMENT}}
	shaders := [?]vk.ShaderEXT{vks.vert_shader, vks.frag_shader}
	vk.CmdBindShadersEXT(cmd, 2, &stages[0], &shaders[0])

	vk.CmdSetVertexInputEXT(cmd, 0, nil, 0, nil)
	vk.CmdSetRasterizerDiscardEnable(cmd, false)
	vk.CmdSetPolygonModeEXT(cmd, .FILL)
	vk.CmdSetCullMode(cmd, {})
	vk.CmdSetFrontFace(cmd, .CLOCKWISE)
	vk.CmdSetPrimitiveTopology(cmd, .TRIANGLE_STRIP)
	vk.CmdSetPrimitiveRestartEnable(cmd, false)
	vk.CmdSetDepthTestEnable(cmd, false)
	vk.CmdSetDepthWriteEnable(cmd, false)
	vk.CmdSetDepthBoundsTestEnable(cmd, false)
	vk.CmdSetDepthBiasEnable(cmd, false)
	vk.CmdSetStencilTestEnable(cmd, false)
	vk.CmdSetRasterizationSamplesEXT(cmd, {._1})
	sample_mask: vk.SampleMask = 0xFFFFFFFF
	vk.CmdSetSampleMaskEXT(cmd, {._1}, &sample_mask)
	vk.CmdSetAlphaToCoverageEnableEXT(cmd, false)
	
	blend_enable: b32 = true
	vk.CmdSetColorBlendEnableEXT(cmd, 0, 1, &blend_enable)
	
	blend_eq := vk.ColorBlendEquationEXT {
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp = .ADD,
	}
	vk.CmdSetColorBlendEquationEXT(cmd, 0, 1, &blend_eq)
	
	color_mask := vk.ColorComponentFlags{.R, .G, .B, .A}
	vk.CmdSetColorWriteMaskEXT(cmd, 0, 1, &color_mask)

	viewport := vk.Viewport {
		width = f32(vks.swapchain_extent.width),
		height = f32(vks.swapchain_extent.height),
		minDepth = 0.0, maxDepth = 1.0,
	}
	vk.CmdSetViewportWithCount(cmd, 1, &viewport)

	screen_size := [2]f32 {
		f32(vks.swapchain_extent.width),
		f32(vks.swapchain_extent.height),
	}
	vk.CmdPushConstants(cmd, vks.pipeline_layout, {.VERTEX}, 0, size_of(screen_size), &screen_size)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, vks.pipeline_layout, 0, 1, &vks.descriptor_set, 0, nil)

	return true
}

vk_draw_instances :: proc(instances: []Instance, scissor: [4]i32) {
	if len(instances) == 0 do return

	if vks.instance_count + u32(len(instances)) > MAX_INSTANCES {
		panic("Instance buffer overflow")
	}

	offset := uintptr(vks.instance_count) * size_of(Instance)
	dst := cast(rawptr)(uintptr(vks.instance_buffer_mapped) + offset)
	mem.copy(dst, raw_data(instances), len(instances) * size_of(Instance))

	cmd := vks.command_buffer

	rect := vk.Rect2D {
		offset = {scissor[0], scissor[1]},
		extent = {u32(scissor[2]), u32(scissor[3])},
	}

	vk.CmdSetScissorWithCount(cmd, 1, &rect)
	vk.CmdDraw(cmd, 4, u32(len(instances)), 0, vks.instance_count)

	vks.instance_count += u32(len(instances))
}

vk_end_frame :: proc() {
	cmd := vks.command_buffer
	vk.CmdEndRendering(cmd)

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask = {.BOTTOM_OF_PIPE},
		dstAccessMask = {},
		oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		image = vks.swapchain_images[vks.image_index],
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	dep_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dep_info)
	vk.EndCommandBuffer(cmd)

	render_finished_semaphore := &vks.render_finished_semaphores[vks.image_index]
	submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &vks.image_available_semaphore,
		pWaitDstStageMask = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
		commandBufferCount = 1,
		pCommandBuffers = &cmd,
		signalSemaphoreCount = 1,
		pSignalSemaphores = render_finished_semaphore,
	}
	vk.QueueSubmit(vks.graphics_queue, 1, &submit_info, vks.in_flight_fence)

	present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = render_finished_semaphore,
		swapchainCount = 1,
		pSwapchains = &vks.swapchain,
		pImageIndices = &vks.image_index,
	}
	vk.QueuePresentKHR(vks.graphics_queue, &present_info)
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

create_buffer :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: ^vk.Buffer, buffer_memory: ^vk.DeviceMemory) {
	buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
		sharingMode = .EXCLUSIVE,
	}
	check_vk(vk.CreateBuffer(vks.device, &buffer_info, nil, buffer))

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(vks.device, buffer^, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, properties),
	}

	check_vk(vk.AllocateMemory(vks.device, &alloc_info, nil, buffer_memory))
	vk.BindBufferMemory(vks.device, buffer^, buffer_memory^, 0)
}

texture_load :: proc(data: []u8, mipmaps: bool = false) -> Texture {
	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), cast(i32)len(data), &w, &h, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil do return {}

	return texture_load_raw((cast([^]Color)pixels)[:w*h], int(w), int(h), mipmaps)
}

texture_load_raw :: proc(pixels: []Color, w, h: int, mipmaps: bool = false) -> Texture {
	size := vk.DeviceSize(w * h * 4)

	staging_buffer: vk.Buffer
	staging_buffer_memory: vk.DeviceMemory
	create_buffer(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging_buffer, &staging_buffer_memory)

	data: rawptr
	vk.MapMemory(vks.device, staging_buffer_memory, 0, size, {}, &data)
	mem.copy(data, raw_data(pixels), int(size))
	vk.UnmapMemory(vks.device, staging_buffer_memory)

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

	// Find free index
	idx := -1
	for i in 0..<MAX_TEXTURES {
		if !textures[i].used {
			idx = i
			textures[i].used = true
			break
		}
	}
	if idx == -1 do panic("Too many textures")

	tex := &textures[idx]
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

	// Execute copy
	alloc_cmd_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = vks.command_pool,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk.AllocateCommandBuffers(vks.device, &alloc_cmd_info, &cmd)

	begin_info := vk.CommandBufferBeginInfo { sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT} }
	vk.BeginCommandBuffer(cmd, &begin_info)

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.TOP_OF_PIPE},
		srcAccessMask = {},
		dstStageMask = {.TRANSFER},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = tex.image,
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	dep_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	region := vk.BufferImageCopy {
		imageSubresource = { aspectMask = {.COLOR}, layerCount = 1 },
		imageExtent = { u32(w), u32(h), 1 },
	}
	vk.CmdCopyBufferToImage(cmd, staging_buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

	barrier.oldLayout = .TRANSFER_DST_OPTIMAL
	barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
	barrier.srcStageMask = {.TRANSFER}
	barrier.srcAccessMask = {.TRANSFER_WRITE}
	barrier.dstStageMask = {.FRAGMENT_SHADER}
	barrier.dstAccessMask = {.SHADER_READ}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	vk.EndCommandBuffer(cmd)

	submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &cmd,
	}
	vk.QueueSubmit(vks.graphics_queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(vks.graphics_queue)

	vk.FreeCommandBuffers(vks.device, vks.command_pool, 1, &cmd)
	vk.DestroyBuffer(vks.device, staging_buffer, nil)
	vk.FreeMemory(vks.device, staging_buffer_memory, nil)

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = .R8G8B8A8_UNORM,
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	vk.CreateImageView(vks.device, &view_info, nil, &tex.view)

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
		dstArrayElement = u32(idx),
		descriptorType = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		pImageInfo = &image_info_desc,
	}
	vk.UpdateDescriptorSets(vks.device, 1, &write_desc, 0, nil)

	return Texture{ index = int(idx), size = {w, h} }
}

texture_update_raw :: proc(tex: Texture, pixels: []Color, x, y, w, h: int) {
	if tex.index < 0 || tex.index >= MAX_TEXTURES do return
	internal_tex := &textures[tex.index]

	size := vk.DeviceSize(w * h * 4)

	staging_buffer: vk.Buffer
	staging_buffer_memory: vk.DeviceMemory
	create_buffer(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging_buffer, &staging_buffer_memory)

	data: rawptr
	vk.MapMemory(vks.device, staging_buffer_memory, 0, size, {}, &data)
	mem.copy(data, raw_data(pixels), int(size))
	vk.UnmapMemory(vks.device, staging_buffer_memory)

	alloc_cmd_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = vks.command_pool,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk.AllocateCommandBuffers(vks.device, &alloc_cmd_info, &cmd)

	begin_info := vk.CommandBufferBeginInfo { sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT} }
	vk.BeginCommandBuffer(cmd, &begin_info)

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.TOP_OF_PIPE},
		srcAccessMask = {},
		dstStageMask = {.TRANSFER},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .SHADER_READ_ONLY_OPTIMAL,
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = internal_tex.image,
		subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
	}
	dep_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	region := vk.BufferImageCopy {
		imageSubresource = { aspectMask = {.COLOR}, layerCount = 1 },
		imageOffset = { i32(x), i32(y), 0 },
		imageExtent = { u32(w), u32(h), 1 },
	}
	vk.CmdCopyBufferToImage(cmd, staging_buffer, internal_tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

	barrier.oldLayout = .TRANSFER_DST_OPTIMAL
	barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
	barrier.srcStageMask = {.TRANSFER}
	barrier.srcAccessMask = {.TRANSFER_WRITE}
	barrier.dstStageMask = {.FRAGMENT_SHADER}
	barrier.dstAccessMask = {.SHADER_READ}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	vk.EndCommandBuffer(cmd)

	submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &cmd,
	}
	vk.QueueSubmit(vks.graphics_queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(vks.graphics_queue)

	vk.FreeCommandBuffers(vks.device, vks.command_pool, 1, &cmd)
	vk.DestroyBuffer(vks.device, staging_buffer, nil)
	vk.FreeMemory(vks.device, staging_buffer_memory, nil)
}

texture_free :: proc(tex: ^Texture) {
	if tex.index < 0 || tex.index >= MAX_TEXTURES do return
	append(&textures_to_free, tex.index)
	tex.index = -1
}

texture_release_deferred :: proc() {
	if len(textures_to_free) == 0 do return
	vk.DeviceWaitIdle(vks.device)
	
	for idx in textures_to_free {
		if !textures[idx].used do continue
		vk.DestroyImageView(vks.device, textures[idx].view, nil)
		vk.DestroyImage(vks.device, textures[idx].image, nil)
		vk.FreeMemory(vks.device, textures[idx].memory, nil)
		textures[idx].used = false
	}
	
	clear(&textures_to_free)
}
