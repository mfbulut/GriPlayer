package fx

import win "core:sys/windows"

import D3D11 "vendor:directx/d3d11"
import D3D_COMPILER "vendor:directx/d3d_compiler"
import DXGI "vendor:directx/dxgi"

Sampler_Kind :: enum {
	BilinearClamp,
	PointClamp,
}

Depth_Kind :: enum {
	None,
	MaskAll_FuncLess,
}

Swapchain :: struct {
	swapchain1:      ^DXGI.ISwapChain1,
	waitable_handle: win.HANDLE,
	default_rtv:     ^D3D11.IRenderTargetView,
}

d3d11_state: struct {
	device:               ^D3D11.IDevice,
	device_ctx:           ^D3D11.IDeviceContext,
	dxgi_factory2:        ^DXGI.IFactory2,
	rasterizer:           ^D3D11.IRasterizerState,
	blend_state:          ^D3D11.IBlendState,
	samplers:             [Sampler_Kind]^D3D11.ISamplerState,
	depths:               [Depth_Kind]^D3D11.IDepthStencilState,
	swapchain:            Swapchain,

	// Renderer
	instanced_buffer_gpu: ^D3D11.IBuffer,
	uniforms_buffer_gpu:  ^D3D11.IBuffer,
	vshader:              ^D3D11.IVertexShader,
	ilayout:              ^D3D11.IInputLayout,
	pshader:              ^D3D11.IPixelShader,
	batch:                Batch,
}

d3d11_resize_swapchain :: proc(size: Vec2) {
	d3d11_state.device_ctx->OMSetRenderTargets(0, nil, nil)
	if d3d11_state.swapchain.default_rtv != nil {
		d3d11_state.swapchain.default_rtv->Release()
		d3d11_state.swapchain.default_rtv = nil
	}

	hr := d3d11_state.swapchain.swapchain1->ResizeBuffers(
		2,0,0,
		.R8G8B8A8_UNORM,
		{.FRAME_LATENCY_WAITABLE_OBJECT},
	)
	if win.FAILED(hr) {
		panic("[ERROR] DXGI ResizeBuffers failed")
	}

	rt: ^D3D11.ITexture2D
	d3d11_state.swapchain.swapchain1->GetBuffer(0, D3D11.ITexture2D_UUID, cast(^rawptr)&rt)
	d3d11_state.device->CreateRenderTargetView(rt, nil, &d3d11_state.swapchain.default_rtv)
	rt->Release()

	d3d11_state.device_ctx->OMSetRenderTargets(1, &d3d11_state.swapchain.default_rtv, nil)

	// Viewport
	viewport := D3D11.VIEWPORT {
		Width    = size.x,
		Height   = size.y,
		MaxDepth = 1,
	}
	d3d11_state.device_ctx->RSSetViewports(1, &viewport)
}

d3d11_initialize :: proc() {
	{
		features := [?]D3D11.FEATURE_LEVEL{._11_0}
		hr := D3D11.CreateDevice(
			nil,
			.HARDWARE,
			nil,
			nil,
			&features[0],
			len(features),
			D3D11.SDK_VERSION,
			&d3d11_state.device,
			nil,
			&d3d11_state.device_ctx,
		)

		if win.FAILED(hr) {
			panic("[ERROR] Failed to create D3D11 device")
		}
	}

	{
		dxgi_device: ^DXGI.IDevice
		dxgi_adapter: ^DXGI.IAdapter

		d3d11_state.device->QueryInterface(DXGI.IDevice_UUID, cast(^rawptr)&dxgi_device)
		dxgi_device->GetAdapter(&dxgi_adapter)
		dxgi_adapter->GetParent(DXGI.IFactory2_UUID, cast(^rawptr)&d3d11_state.dxgi_factory2)

		dxgi_device->Release()
		dxgi_adapter->Release()
	}

	{ 	// Rasterizer
		desc := D3D11.RASTERIZER_DESC {
			FillMode      = .SOLID,
			CullMode      = .NONE,
			ScissorEnable = true,
		}
		d3d11_state.device->CreateRasterizerState(&desc, &d3d11_state.rasterizer)
	}

	{ 	// Blend Alpha
		desc: D3D11.BLEND_DESC
		desc.RenderTarget[0].BlendEnable = true
		desc.RenderTarget[0].SrcBlend = .SRC_ALPHA
		desc.RenderTarget[0].SrcBlendAlpha = .ONE
		desc.RenderTarget[0].DestBlend = .INV_SRC_ALPHA
		desc.RenderTarget[0].DestBlendAlpha = .ZERO
		desc.RenderTarget[0].BlendOp = .ADD
		desc.RenderTarget[0].BlendOpAlpha = .ADD
		desc.RenderTarget[0].RenderTargetWriteMask = cast(u8)D3D11.COLOR_WRITE_ENABLE_ALL

		d3d11_state.device->CreateBlendState(&desc, &d3d11_state.blend_state)
	}

	{ 	// Samplers
		desc := D3D11.SAMPLER_DESC {
			Filter         = .MIN_MAG_MIP_POINT,
			AddressU       = .CLAMP,
			AddressV       = .CLAMP,
			AddressW       = .CLAMP,
			ComparisonFunc = .NEVER,
			MinLOD         = 0.0,
			MaxLOD         = 1000,
		}
		d3d11_state.device->CreateSamplerState(&desc, &d3d11_state.samplers[.PointClamp])

		desc.Filter = .MIN_MAG_MIP_LINEAR
		d3d11_state.device->CreateSamplerState(&desc, &d3d11_state.samplers[.BilinearClamp])
	}

	{ 	// Depth Stencil
		desc := D3D11.DEPTH_STENCIL_DESC {
			DepthWriteMask = .ALL,
			DepthFunc      = .LESS,
		}
		d3d11_state.device->CreateDepthStencilState(&desc, &d3d11_state.depths[.None])
		desc.DepthEnable = true
		d3d11_state.device->CreateDepthStencilState(&desc, &d3d11_state.depths[.MaskAll_FuncLess])
	}

	{ 	// First Run
		d3d11_state.device_ctx->PSSetSamplers(0, 1, &d3d11_state.samplers[.BilinearClamp])
		d3d11_state.device_ctx->RSSetState(d3d11_state.rasterizer)
		d3d11_state.device_ctx->OMSetDepthStencilState(d3d11_state.depths[.None], 0)
		d3d11_state.device_ctx->OMSetBlendState(d3d11_state.blend_state, nil, 0xffffffff)
	}

	{ 	// Swapchain
		desc := DXGI.SWAP_CHAIN_DESC1 {
			Format = .R8G8B8A8_UNORM,
			SampleDesc = {Count = 1},
			BufferUsage = {.RENDER_TARGET_OUTPUT},
			BufferCount = 2,
			Scaling = .NONE,
			SwapEffect = .FLIP_DISCARD,
			Flags = {.FRAME_LATENCY_WAITABLE_OBJECT},
		}

		hr := d3d11_state.dxgi_factory2->CreateSwapChainForHwnd(
			d3d11_state.device,
			window.hwnd,
			&desc,
			nil,
			nil,
			&d3d11_state.swapchain.swapchain1,
		)
		if win.FAILED(hr) {
			panic("[ERROR] DXGI swapchain creation failed")
		}

		d3d11_state.dxgi_factory2->MakeWindowAssociation(window.hwnd, {.NO_ALT_ENTER})
	}

	{ 	// Waitable Obj
		swapchain2: ^DXGI.ISwapChain2
		hr := d3d11_state.swapchain.swapchain1->QueryInterface(
			DXGI.ISwapChain2_UUID,
			cast(^rawptr)&swapchain2,
		)
		if win.FAILED(hr) {
			panic("[WARNING] Failed to get ISwapChain2 for waitable object")
		}

		swapchain2->SetMaximumFrameLatency(1)
		d3d11_state.swapchain.waitable_handle = swapchain2->GetFrameLatencyWaitableObject()
		swapchain2->Release()
	}

	{
		rt: ^D3D11.ITexture2D
		d3d11_state.swapchain.swapchain1->GetBuffer(0, D3D11.ITexture2D_UUID, cast(^rawptr)&rt)
		d3d11_state.device->CreateRenderTargetView(rt, nil, &d3d11_state.swapchain.default_rtv)
		rt->Release()
	}
}

d3d11_vshader_init :: proc(src: string, dbg_name: cstring) {
	vshader_blob: ^D3D11.IBlob
	vshader_error: ^D3D11.IBlob

	hr := D3D_COMPILER.Compile(
		raw_data(src),
		len(src),
		dbg_name,
		nil,
		nil,
		"vs_main",
		"vs_5_0",
		0,
		0,
		&vshader_blob,
		&vshader_error,
	)
	defer if vshader_blob != nil {
		vshader_blob->Release()
	}

	if win.FAILED(hr) {
		ptr := cast([^]byte)vshader_error->GetBufferPointer()
		len := vshader_error->GetBufferSize()
		panic(string(ptr[:len]))
	} else {
		d3d11_state.device->CreateVertexShader(
			vshader_blob->GetBufferPointer(),
			vshader_blob->GetBufferSize(),
			nil,
			&d3d11_state.vshader,
		)
	}

	// Input Layout
	hr = d3d11_state.device->CreateInputLayout(
		raw_data(vs_input_layout),
		u32(len(vs_input_layout)),
		vshader_blob->GetBufferPointer(),
		vshader_blob->GetBufferSize(),
		&d3d11_state.ilayout,
	)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create D3D11 input layout")
	}
}

d3d11_pshader_init :: proc(src: string, dbg_name: cstring) {
	pshader_blob: ^D3D11.IBlob
	pshader_error: ^D3D11.IBlob

	hr := D3D_COMPILER.Compile(
		raw_data(src),
		len(src),
		dbg_name,
		nil,
		nil,
		"ps_main",
		"ps_5_0",
		0,
		0,
		&pshader_blob,
		&pshader_error,
	)
	defer if pshader_blob != nil {
		pshader_blob->Release()
	}

	if win.FAILED(hr) {
		ptr := cast([^]byte)pshader_error->GetBufferPointer()
		len := pshader_error->GetBufferSize()
		panic(string(ptr[:len]))
	} else {
		d3d11_state.device->CreatePixelShader(
			pshader_blob->GetBufferPointer(),
			pshader_blob->GetBufferSize(),
			nil,
			&d3d11_state.pshader,
		)
	}
}

d3d11_uniforms_init :: proc($T: typeid) {
	desc := D3D11.BUFFER_DESC {
		ByteWidth      = size_of(T),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}

	hr := d3d11_state.device->CreateBuffer(&desc, nil, &d3d11_state.uniforms_buffer_gpu)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create uniform buffer")
	}
}
