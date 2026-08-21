package fx

import "base:runtime"
import "core:os"

import "core:mem"
import "core:dynlib"
import vk "vendor:vulkan"
import stbi "vendor:stb/image"

MAX_TEXTURES :: 1024
MAX_INSTANCES :: 16 * mem.Megabyte / size_of(Instance)
MAX_CURVES :: 16 * mem.Megabyte / 12
MAX_STRIPES :: 64 * 1024

swapchain: struct {
	swapchain: vk.SwapchainKHR,
	images: []vk.Image,
	image_views: []vk.ImageView,
	present_semaphores: []vk.Semaphore,
}

vks: struct {
	instance: vk.Instance,
	gpu: vk.PhysicalDevice,
	device: vk.Device,
	queue: vk.Queue,
	surface: vk.SurfaceKHR,

	command_pool: vk.CommandPool,
	command_buffer: vk.CommandBuffer,
	acquire_semaphore: vk.Semaphore,
	in_flight_fence: vk.Fence,

	sampler: vk.Sampler,
	pipeline: vk.Pipeline,
	pipeline_layout: vk.PipelineLayout,

	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set: vk.DescriptorSet,
	instance_buffer_mapped: rawptr,
	curve_buffer_mapped: rawptr,
	clear_color: [4]f32,

	stripe_buffer_mapped: rawptr,
}

Texture :: struct {
	index: int,
	size: [2]int,
}

textures: #soa[MAX_TEXTURES]struct {
	image: vk.Image,
	view: vk.ImageView,
	memory: vk.DeviceMemory,
	layout: vk.ImageLayout,
	mip_levels: u32,
	used: bool,
}

vk_init :: proc() {
	{	// Load Vulkan library
		lib: dynlib.Library
		when ODIN_OS == .Windows {
			lib = dynlib.load_library("vulkan-1.dll") or_else panic("Failed to load Vulkan library")
		} else {
			lib = dynlib.load_library("libvulkan.so.1") or_else panic("Failed to load Vulkan library")
		}
		vkGetInstanceProcAddr := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
		vk.load_proc_addresses(vkGetInstanceProcAddr)
	}

	{	// Create Instance
		when ODIN_DEBUG {
			layer_count := u32(1)
			val_layer := cstring("VK_LAYER_KHRONOS_validation")
			layer_names := &val_layer
		} else {
			layer_count: u32
			layer_names: ^cstring
		}

		extensions: [dynamic]cstring
		append(&extensions, vk.KHR_SURFACE_EXTENSION_NAME)
		when ODIN_OS == .Windows {
			append(&extensions, vk.KHR_WIN32_SURFACE_EXTENSION_NAME)
		} else {
			append(&extensions, vk.KHR_XLIB_SURFACE_EXTENSION_NAME)
		}
		when ODIN_DEBUG {
			append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		}

		app_info := vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "Font Renderer",
			apiVersion = vk.API_VERSION_1_3,
		}

		create_info := vk.InstanceCreateInfo {
			sType = .INSTANCE_CREATE_INFO,
			pApplicationInfo = &app_info,
			enabledExtensionCount =  u32(len(extensions)),
			ppEnabledExtensionNames = raw_data(extensions[:]),
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
				when ODIN_DEBUG {
					os.write_string(os.stderr, "Vulkan Validation: ")
					if pCallbackData != nil && pCallbackData.pMessage != nil {
						os.write_string(os.stderr, string(pCallbackData.pMessage))
					}
					os.write_string(os.stderr, "\n")
				}
				return false
			}

			debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
				sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
				messageSeverity = {.WARNING, .ERROR},
				messageType = {.VALIDATION, .PERFORMANCE},
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
		when ODIN_OS == .Windows {
			surface_create_info := vk.Win32SurfaceCreateInfoKHR {
				sType = .WIN32_SURFACE_CREATE_INFO_KHR,
				hinstance = window.hInstance,
				hwnd = window.hwnd,
			}
			vk.CreateWin32SurfaceKHR(vks.instance, &surface_create_info, nil, &vks.surface)
		} else {
			surface_create_info := vk.XlibSurfaceCreateInfoKHR {
				sType = .XLIB_SURFACE_CREATE_INFO_KHR,
				dpy = window.display,
				window = window.win,
			}
			vk.CreateXlibSurfaceKHR(vks.instance, &surface_create_info, nil, &vks.surface)
		}
	}

	{	// Pick Physical Device
		device_count: u32
		vk.EnumeratePhysicalDevices(vks.instance, &device_count, nil)
		devices := make([]vk.PhysicalDevice, device_count)
		defer delete(devices)
		vk.EnumeratePhysicalDevices(vks.instance, &device_count, &devices[0])

		vks.gpu = devices[0]
		for d in devices {
			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(d, &props)
			if props.deviceType == .DISCRETE_GPU {
				vks.gpu = d
				break
			}
		}
	}

	{	// Create Logical Device
		queue_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(vks.gpu, &queue_count, nil)
		queue_families := make([]vk.QueueFamilyProperties, queue_count)
		defer delete(queue_families)
		vk.GetPhysicalDeviceQueueFamilyProperties(vks.gpu, &queue_count, &queue_families[0])

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

		features_13 := vk.PhysicalDeviceVulkan13Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			dynamicRendering = true,
			synchronization2 = true,
		}

		features_16bit := vk.PhysicalDevice16BitStorageFeatures {
			sType = .PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES,
			pNext = &features_13,
			storageBuffer16BitAccess = true,
		}

		features_12 := vk.PhysicalDeviceVulkan12Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			pNext = &features_16bit,
			descriptorIndexing = true,
			descriptorBindingPartiallyBound = true,
			descriptorBindingSampledImageUpdateAfterBind = true,
			runtimeDescriptorArray = true,
			shaderSampledImageArrayNonUniformIndexing = true,
			shaderFloat16 = true,
		}

		device_extensions := [?]cstring {
			vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		}

		device_create_info := vk.DeviceCreateInfo {
			sType = .DEVICE_CREATE_INFO,
			pNext = &features_12,
			queueCreateInfoCount = 1,
			pQueueCreateInfos = &queue_create_info,
			enabledExtensionCount = len(device_extensions),
			ppEnabledExtensionNames = &device_extensions[0],
		}

		vk.CreateDevice(vks.gpu, &device_create_info, nil, &vks.device)
		vk.load_proc_addresses(vks.device)
		vk.GetDeviceQueue(vks.device, queue_family_index, 0, &vks.queue)

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
		vk.CreateSemaphore(vks.device, &semaphore_info, nil, &vks.acquire_semaphore)
		vk.CreateFence(vks.device, &fence_info, nil, &vks.in_flight_fence)

	}

	{	// Sampler

		sampler_info := vk.SamplerCreateInfo {
			sType = .SAMPLER_CREATE_INFO,
			magFilter = .LINEAR,
			minFilter = .LINEAR,
			mipmapMode = .LINEAR,
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
			{},
			{},
		}
		layout_binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
			bindingCount = 4,
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
			{
				binding = 2,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				stageFlags = {.FRAGMENT},
			},
			{
				binding = 3,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				stageFlags = {.FRAGMENT},
			},
		}
		layout_info := vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			pNext = &layout_binding_flags,
			flags = {.UPDATE_AFTER_BIND_POOL},
			bindingCount = 4,
			pBindings = &bindings[0],
		}
		vk.CreateDescriptorSetLayout(vks.device, &layout_info, nil, &vks.descriptor_set_layout)

		pool_sizes := [?]vk.DescriptorPoolSize {
			{ type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_TEXTURES },
			{ type = .STORAGE_BUFFER, descriptorCount = 3 },
		}
		desc_pool_info := vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			flags = {.UPDATE_AFTER_BIND},
			maxSets = 1,
			poolSizeCount = 2,
			pPoolSizes = &pool_sizes[0],
		}
		descriptor_pool: vk.DescriptorPool
		vk.CreateDescriptorPool(vks.device, &desc_pool_info, nil, &descriptor_pool)

		alloc_set_info := vk.DescriptorSetAllocateInfo {
			sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts = &vks.descriptor_set_layout,
		}
		vk.AllocateDescriptorSets(vks.device, &alloc_set_info, &vks.descriptor_set)
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

	{	// Curve Buffer for Scanline Sweeper
		buffer, memory := create_buffer(
			vk.DeviceSize(MAX_CURVES * 12),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk.MapMemory(vks.device, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &vks.curve_buffer_mapped)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = buffer,
			range = vk.DeviceSize(vk.WHOLE_SIZE),
		}

		write_desc := vk.WriteDescriptorSet {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = vks.descriptor_set,
			dstBinding = 2,
			dstArrayElement = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo = &buffer_info,
		}

		vk.UpdateDescriptorSets(vks.device, 1, &write_desc, 0, nil)
	}

	{	// Stripe Buffer for Scanline Sweeper
		buffer, memory := create_buffer(
			vk.DeviceSize(MAX_STRIPES * 8),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk.MapMemory(vks.device, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &vks.stripe_buffer_mapped)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = buffer,
			range = vk.DeviceSize(vk.WHOLE_SIZE),
		}

		write_desc := vk.WriteDescriptorSet {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = vks.descriptor_set,
			dstBinding = 3,
			dstArrayElement = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo = &buffer_info,
		}

		vk.UpdateDescriptorSets(vks.device, 1, &write_desc, 0, nil)
	}

	{	// Create Pipeline
		vert_spv := #load("../assets/shaders/shader.vert.spv", []u32)
		frag_spv := #load("../assets/shaders/shader.frag.spv", []u32)

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

		vk.CreatePipelineLayout(vks.device, &pipeline_layout_info, nil, &vks.pipeline_layout)

		vert_module_info := vk.ShaderModuleCreateInfo {
			sType = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(vert_spv) * 4,
			pCode = raw_data(vert_spv),
		}
		vert_module: vk.ShaderModule
		vk.CreateShaderModule(vks.device, &vert_module_info, nil, &vert_module)
		defer vk.DestroyShaderModule(vks.device, vert_module, nil)

		frag_module_info := vk.ShaderModuleCreateInfo {
			sType = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(frag_spv) * 4,
			pCode = raw_data(frag_spv),
		}
		frag_module: vk.ShaderModule
		vk.CreateShaderModule(vks.device, &frag_module_info, nil, &frag_module)
		defer vk.DestroyShaderModule(vks.device, frag_module, nil)

		stages := [?]vk.PipelineShaderStageCreateInfo {
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

		vertex_input := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		}

		input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_STRIP,
		}

		viewport_state := vk.PipelineViewportStateCreateInfo {
			sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount = 1,
		}

		rasterization := vk.PipelineRasterizationStateCreateInfo {
			sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			cullMode = {},
			frontFace = .CLOCKWISE,
			lineWidth = 1.0,
		}

		multisample := vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		}

		color_blend_attachment := vk.PipelineColorBlendAttachmentState {
			blendEnable = true,
			srcColorBlendFactor = .SRC_ALPHA,
			dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
			alphaBlendOp = .ADD,
			colorWriteMask = {.R, .G, .B, .A},
		}

		color_blend := vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments = &color_blend_attachment,
		}

		dynamic_states := [?]vk.DynamicState { .VIEWPORT, .SCISSOR }
		dynamic_state := vk.PipelineDynamicStateCreateInfo {
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(dynamic_states),
			pDynamicStates = &dynamic_states[0],
		}

		color_format := vk.Format.B8G8R8A8_UNORM
		rendering_info := vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &color_format,
		}

		pipeline_info := vk.GraphicsPipelineCreateInfo {
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			pNext = &rendering_info,
			stageCount = 2,
			pStages = &stages[0],
			pVertexInputState = &vertex_input,
			pInputAssemblyState = &input_assembly,
			pViewportState = &viewport_state,
			pRasterizationState = &rasterization,
			pMultisampleState = &multisample,
			pColorBlendState = &color_blend,
			pDynamicState = &dynamic_state,
			layout = vks.pipeline_layout,
		}

		vk.CreateGraphicsPipelines(vks.device, 0, 1, &pipeline_info, nil, &vks.pipeline)
	}

	vk_recreate_swapchain()
}

vk_recreate_swapchain :: proc() {
	vk.DeviceWaitIdle(vks.device)

	if swapchain.swapchain != 0 {
		for view in swapchain.image_views {
			vk.DestroyImageView(vks.device, view, nil)
		}
		for semaphore in swapchain.present_semaphores {
			vk.DestroySemaphore(vks.device, semaphore, nil)
		}
		delete(swapchain.images)
		delete(swapchain.image_views)
		delete(swapchain.present_semaphores)
	}

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vks.gpu, vks.surface, &capabilities)
	extent := vk.Extent2D{u32(window.size.x), u32(window.size.y)}

	create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = vks.surface,
		minImageCount = capabilities.minImageCount,
		imageFormat = .B8G8R8A8_UNORM,
		imageColorSpace = .SRGB_NONLINEAR,
		imageExtent = extent,
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform = {.IDENTITY},
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		clipped = true,
		oldSwapchain = swapchain.swapchain,
	}

	new_swapchain: vk.SwapchainKHR
	vk.CreateSwapchainKHR(vks.device, &create_info, nil, &new_swapchain)

	if swapchain.swapchain != 0 {
		vk.DestroySwapchainKHR(vks.device, swapchain.swapchain, nil)
	}

	swapchain.swapchain = new_swapchain

	image_count: u32
	vk.GetSwapchainImagesKHR(vks.device, swapchain.swapchain, &image_count, nil)

	swapchain.images = make([]vk.Image, image_count)
	swapchain.image_views = make([]vk.ImageView, image_count)
	swapchain.present_semaphores = make([]vk.Semaphore, image_count)

	vk.GetSwapchainImagesKHR(vks.device, swapchain.swapchain, &image_count, raw_data(swapchain.images))

	semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for i in 0..<image_count {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = swapchain.images[i],
			viewType = .D2,
			format = .B8G8R8A8_UNORM,
			subresourceRange = { aspectMask = {.COLOR}, levelCount = 1, layerCount = 1 },
		}
		vk.CreateImageView(vks.device, &view_info, nil, &swapchain.image_views[i])
		vk.CreateSemaphore(vks.device, &semaphore_info, nil, &swapchain.present_semaphores[i])
	}
}

vk_render :: proc() {
	vk.WaitForFences(vks.device, 1, &vks.in_flight_fence, true, max(u64))

	image_index: u32
	res := vk.AcquireNextImageKHR(
		vks.device, swapchain.swapchain, max(u64),
		vks.acquire_semaphore,
		0, &image_index,
	)

	if res == .ERROR_OUT_OF_DATE_KHR {
		vk_recreate_swapchain()
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
		cmd, swapchain.images[image_index],
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE}, {.COLOR_ATTACHMENT_OUTPUT},
		{}, {.COLOR_ATTACHMENT_WRITE},
	)

	color_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = swapchain.image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue { color = { float32 = vks.clear_color } },
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = { extent = {u32(window.size.x), u32(window.size.y)} },
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	vk.CmdBindPipeline(cmd, .GRAPHICS, vks.pipeline)

	viewport := vk.Viewport {
		x = 0, y = 0,
		width = f32(window.size.x),
		height = f32(window.size.y),
		minDepth = 0.0, maxDepth = 1.0,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	screen_size := window_size()
	vk.CmdPushConstants(cmd, vks.pipeline_layout, {.VERTEX}, 0, size_of(screen_size), &screen_size)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, vks.pipeline_layout, 0, 1, &vks.descriptor_set, 0, nil)

	if len(instances) > 0 {
		mem.copy(vks.instance_buffer_mapped, raw_data(instances[:]), len(instances) * size_of(Instance))

		scissor := vk.Rect2D {
			offset = {0, 0},
			extent = {u32(window.size.x), u32(window.size.y)},
		}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		vk.CmdDraw(cmd, 4, u32(len(instances)), 0, 0)
	}

	vk.CmdEndRendering(cmd)

	image_barrier(
		cmd, swapchain.images[image_index],
		.COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_WRITE}, {},
	)
	vk.EndCommandBuffer(cmd)

	render_finished_semaphore := &swapchain.present_semaphores[image_index]
	cmd_info := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	wait_info := vk.SemaphoreSubmitInfo {
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = vks.acquire_semaphore,
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
	vk.QueueSubmit2(vks.queue, 1, &submit_info, vks.in_flight_fence)

	present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = render_finished_semaphore,
		swapchainCount = 1,
		pSwapchains = &swapchain.swapchain,
		pImageIndices = &image_index,
	}

	present_res := vk.QueuePresentKHR(vks.queue, &present_info)
	if present_res == .ERROR_OUT_OF_DATE_KHR || present_res == .SUBOPTIMAL_KHR || res == .SUBOPTIMAL_KHR {
		vk_recreate_swapchain()
	}
}

find_memory_type :: proc(type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(vks.gpu, &mem_properties)
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
	base_mip_level := u32(0),
	level_count := u32(1),
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
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = base_mip_level,
			levelCount = level_count,
			layerCount = 1,
		},
	}
	dep_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

texture_load :: proc(data: []u8, mipmaps := false) -> Texture {
	w, h, channels: i32
	pixels := cast([^]Color)stbi.load_from_memory(raw_data(data), cast(i32)len(data), &w, &h, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil do return {}

	tex := texture_create(int(w), int(h), mipmaps)
	texture_upload(tex, pixels[:w*h], 0, 0, int(w), int(h))

	return tex
}

texture_create :: proc(w, h: int, mipmaps := false) -> Texture {
	index := 0
	for i in 1..<MAX_TEXTURES {
		if !textures.used[i] {
			index = i
			textures.used[i] = true
			break
		}
	}

	if index == 0 {
		panic("Texture Pool Is Full")
	}

	tex_data := &textures[index]
	mip_levels := u32(1)
	if mipmaps {
		mip_size := max(w, h)
		for mip_size > 1 {
			mip_size /= 2
			mip_levels += 1
		}
	}

	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		extent = { u32(w), u32(h), 1 },
		mipLevels = mip_levels,
		arrayLayers = 1,
		format = .R8G8B8A8_UNORM,
		tiling = .OPTIMAL,
		initialLayout = .UNDEFINED,
		usage = {.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		samples = {._1},
		sharingMode = .EXCLUSIVE,
	}

	vk.CreateImage(vks.device, &image_info, nil, &tex_data.image)

	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vks.device, tex_data.image, &mem_reqs)

	alloc_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = mem_reqs.size,
		memoryTypeIndex = find_memory_type(mem_reqs.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk.AllocateMemory(vks.device, &alloc_info, nil, &tex_data.memory)
	vk.BindImageMemory(vks.device, tex_data.image, tex_data.memory, 0)

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex_data.image,
		viewType = .D2,
		format = .R8G8B8A8_UNORM,
		subresourceRange = { aspectMask = {.COLOR}, levelCount = mip_levels, layerCount = 1 },
	}
	vk.CreateImageView(vks.device, &view_info, nil, &tex_data.view)

	// Update descriptor set
	image_info_desc := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView = tex_data.view,
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

	tex_data.mip_levels = mip_levels
	return Texture{index = index, size = {w, h}}
}

texture_upload :: proc(tex: Texture, pixels: []Color, x, y, w, h: int) {
	if tex.index <= 0 || tex.index >= MAX_TEXTURES do return
	tex_data := &textures[tex.index]
	if !tex_data.used do return
	has_mipmaps := tex_data.mip_levels > 1
	assert(!has_mipmaps || (x == 0 && y == 0 && w == tex.size.x && h == tex.size.y))

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
		cmd, tex_data.image,
		tex_data.layout, .TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE}, {.TRANSFER},
		{}, {.TRANSFER_WRITE},
		level_count = has_mipmaps ? tex_data.mip_levels : 1,
	)

	region := vk.BufferImageCopy {
		imageSubresource = { aspectMask = {.COLOR}, layerCount = 1 },
		imageOffset = { i32(x), i32(y), 0 },
		imageExtent = { u32(w), u32(h), 1 },
	}
	vk.CmdCopyBufferToImage(cmd, buffer, tex_data.image, .TRANSFER_DST_OPTIMAL, 1, &region)

	if has_mipmaps {
		mip_width := i32(tex.size.x)
		mip_height := i32(tex.size.y)

		for mip_level := u32(1); mip_level < tex_data.mip_levels; mip_level += 1 {
			image_barrier(
				cmd, tex_data.image,
				.TRANSFER_DST_OPTIMAL, .TRANSFER_SRC_OPTIMAL,
				{.TRANSFER}, {.TRANSFER},
				{.TRANSFER_WRITE}, {.TRANSFER_READ},
				base_mip_level = mip_level - 1,
			)

			next_width := max(mip_width / 2, 1)
			next_height := max(mip_height / 2, 1)
			blit := vk.ImageBlit {
				srcSubresource = {
					aspectMask = {.COLOR},
					mipLevel = mip_level - 1,
					layerCount = 1,
				},
				srcOffsets = {
					{0, 0, 0},
					{mip_width, mip_height, 1},
				},
				dstSubresource = {
					aspectMask = {.COLOR},
					mipLevel = mip_level,
					layerCount = 1,
				},
				dstOffsets = {
					{0, 0, 0},
					{next_width, next_height, 1},
				},
			}
			vk.CmdBlitImage(
				cmd,
				tex_data.image, .TRANSFER_SRC_OPTIMAL,
				tex_data.image, .TRANSFER_DST_OPTIMAL,
				1, &blit, .LINEAR,
			)

			mip_width = next_width
			mip_height = next_height
		}

		image_barrier(
			cmd, tex_data.image,
			.TRANSFER_SRC_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER}, {.FRAGMENT_SHADER},
			{.TRANSFER_READ}, {.SHADER_READ},
			level_count = tex_data.mip_levels - 1,
		)
		image_barrier(
			cmd, tex_data.image,
			.TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER}, {.FRAGMENT_SHADER},
			{.TRANSFER_WRITE}, {.SHADER_READ},
			base_mip_level = tex_data.mip_levels - 1,
		)
	} else {
		image_barrier(
			cmd, tex_data.image,
			.TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER}, {.FRAGMENT_SHADER},
			{.TRANSFER_WRITE}, {.SHADER_READ},
		)
	}

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
	vk.QueueSubmit2(vks.queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(vks.queue)

	vk.FreeCommandBuffers(vks.device, vks.command_pool, 1, &cmd)

	vk.DestroyBuffer(vks.device, buffer, nil)
	vk.FreeMemory(vks.device, buffer_memory, nil)

	tex_data.layout = .SHADER_READ_ONLY_OPTIMAL
}

texture_destroy :: proc(tex: ^Texture) {
	if tex.index == 0 do return
	tex_data := &textures[tex.index]

	vk.DeviceWaitIdle(vks.device)
	if tex_data.used {
		vk.DestroyImageView(vks.device, tex_data.view, nil)
		vk.DestroyImage(vks.device, tex_data.image, nil)
		vk.FreeMemory(vks.device, tex_data.memory, nil)
		tex_data^ = {}
	}

	tex^ = {}
}