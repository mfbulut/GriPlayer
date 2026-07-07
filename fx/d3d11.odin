package fx

import win "core:sys/windows"

import D3D11 "vendor:directx/d3d11"
import DXGI "vendor:directx/dxgi"

import "core:mem"
import "core:math/linalg"

Sampler_Kind :: enum {
	PointClamp,
	BilinearClamp,
	AnisotropicClamp,
}

Swapchain :: struct {
	swapchain1:      ^DXGI.ISwapChain1,
	waitable_handle: win.HANDLE,
	default_rtv:     ^D3D11.IRenderTargetView,
}

state: struct {
	device:           ^D3D11.IDevice,
	device_ctx:       ^D3D11.IDeviceContext,
	rasterizer:       ^D3D11.IRasterizerState,
	blend_state:      ^D3D11.IBlendState,
	samplers:         [Sampler_Kind]^D3D11.ISamplerState,
	swapchain:        Swapchain,

	// Renderer
	instanced_buffer: ^D3D11.IBuffer,
	uniforms_buffer:  ^D3D11.IBuffer,
	default_shader:   Shader,
	batch:            Batch,
}

d3d11_resize_swapchain :: proc() {
	state.device_ctx->OMSetRenderTargets(0, nil, nil)
	if state.swapchain.default_rtv != nil {
		state.swapchain.default_rtv->Release()
		state.swapchain.default_rtv = nil
	}

	state.swapchain.swapchain1->ResizeBuffers(
		2,0,0,
		.R8G8B8A8_UNORM,
		{.FRAME_LATENCY_WAITABLE_OBJECT},
	)

	rt: ^D3D11.ITexture2D
	state.swapchain.swapchain1->GetBuffer(0, D3D11.ITexture2D_UUID, cast(^rawptr)&rt)
	state.device->CreateRenderTargetView(rt, nil, &state.swapchain.default_rtv)
	rt->Release()

	state.device_ctx->OMSetRenderTargets(1, &state.swapchain.default_rtv, nil)
}

d3d11_initialize :: proc() {
	{
		features := [?]D3D11.FEATURE_LEVEL{._11_0}
		D3D11.CreateDevice(nil, .HARDWARE, nil, nil, &features[0], len(features), D3D11.SDK_VERSION, &state.device, nil, &state.device_ctx)
	}

	{
		dxgi_device: ^DXGI.IDevice
		dxgi_adapter: ^DXGI.IAdapter

		state.device->QueryInterface(DXGI.IDevice_UUID, cast(^rawptr)&dxgi_device)
		dxgi_device->GetAdapter(&dxgi_adapter)

		dxgi_device->Release()
		dxgi_adapter->Release()
	}


	{ 	// Rasterizer
		desc := D3D11.RASTERIZER_DESC {
			FillMode      = .SOLID,
			CullMode      = .NONE,
			ScissorEnable = true,
		}
		state.device->CreateRasterizerState(&desc, &state.rasterizer)
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
		state.device->CreateBlendState(&desc, &state.blend_state)
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

		state.device->CreateSamplerState(&desc, &state.samplers[.PointClamp])

		desc.Filter = .MIN_MAG_MIP_LINEAR
		state.device->CreateSamplerState(&desc, &state.samplers[.BilinearClamp])

		desc.Filter = .ANISOTROPIC
		desc.MaxAnisotropy = 8
		desc.MipLODBias = -0.5
		state.device->CreateSamplerState(&desc, &state.samplers[.AnisotropicClamp])
	}

	{ 	// First Run
		state.device_ctx->PSSetSamplers(0, 1, &state.samplers[.AnisotropicClamp])
		state.device_ctx->RSSetState(state.rasterizer)
		state.device_ctx->OMSetBlendState(state.blend_state, nil, 0xffffffff)
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

		dxgi_device: ^DXGI.IDevice
		dxgi_adapter: ^DXGI.IAdapter
		state.device->QueryInterface(DXGI.IDevice_UUID, cast(^rawptr)&dxgi_device)
		dxgi_device->GetAdapter(&dxgi_adapter)

		dxgi_factory2: ^DXGI.IFactory2
		dxgi_adapter->GetParent(DXGI.IFactory2_UUID, cast(^rawptr)&dxgi_factory2)
		dxgi_device->Release()
		dxgi_adapter->Release()

		dxgi_factory2->CreateSwapChainForHwnd(
			state.device,
			window.hwnd,
			&desc,
			nil,
			nil,
			&state.swapchain.swapchain1,
		)

		dxgi_factory2->MakeWindowAssociation(window.hwnd, {.NO_ALT_ENTER})
	}

	{ 	// Waitable Obj
		swapchain2: ^DXGI.ISwapChain2
		state.swapchain.swapchain1->QueryInterface(
			DXGI.ISwapChain2_UUID,
			cast(^rawptr)&swapchain2,
		)

		swapchain2->SetMaximumFrameLatency(1)
		state.swapchain.waitable_handle = swapchain2->GetFrameLatencyWaitableObject()
		swapchain2->Release()
	}

	{
		rt: ^D3D11.ITexture2D
		state.swapchain.swapchain1->GetBuffer(0, D3D11.ITexture2D_UUID, cast(^rawptr)&rt)
		state.device->CreateRenderTargetView(rt, nil, &state.swapchain.default_rtv)
		rt->Release()
	}
	{
		// Instance buffer
		desc := D3D11.BUFFER_DESC {
			ByteWidth      = INSTANCED_MAX * size_of(Instance),
			Usage          = .DYNAMIC,
			BindFlags      = {.VERTEX_BUFFER},
			CPUAccessFlags = {.WRITE},
		}

		state.device->CreateBuffer(&desc, nil, &state.instanced_buffer)

		state.default_shader = load_shader(shader, "shader.hlsl")
	}

	{
		// Uniform Buffer
		desc := D3D11.BUFFER_DESC {
			ByteWidth      = size_of(uniforms),
			Usage          = .DYNAMIC,
			BindFlags      = {.CONSTANT_BUFFER},
			CPUAccessFlags = {.WRITE},
		}

		state.device->CreateBuffer(&desc, nil, &state.uniforms_buffer)
		upload_uniforms()
	}

	{
		// Bind pipeline
		stride := cast(u32)size_of(Instance)
		offset := u32(0)
		state.device_ctx->IASetVertexBuffers(0, 1, &state.instanced_buffer, &stride, &offset,)
		state.device_ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)

		state.device_ctx->VSSetConstantBuffers(0, 1, &state.uniforms_buffer)

		state.device_ctx->PSSetConstantBuffers(0, 1, &state.uniforms_buffer)

		state.device_ctx->RSSetState(state.rasterizer)
		state.device_ctx->OMSetBlendState(state.blend_state, nil, 0xffffffff)
	}
}

Instance :: struct {
	// LT, LR, BL, BR
	dest: Rect,
	src: Rect,
	color: [4]Color,
	radius: f32,
	kind: enum u32 {
		Rect,
		Texture,
		Text,
	},
}

Binding :: struct {
	texture: ^D3D11.IShaderResourceView,
	sampler_kind: Sampler_Kind,
	scissor: [4]i32,
}

Batch_Run :: struct {
	binding: Binding,
	first: u32,
	count: u32,
}

INSTANCED_MAX :: 1024 * 16
RUNS_MAX :: 1024 * 4

Batch :: struct {
	instanced: [dynamic; INSTANCED_MAX]Instance,
	runs:      [dynamic; RUNS_MAX]Batch_Run,
	binding:   Binding,
}

begin_frame :: proc() {
	state.batch.binding.scissor = {0, 0, window.size.x, window.size.y}
	set_shader(state.default_shader)

	if window.is_resized {
		d3d11_resize_swapchain()
		upload_uniforms()
		window.is_resized = false
	} else {
		state.device_ctx->OMSetRenderTargets(1, &state.swapchain.default_rtv, nil)
	}

	viewport := D3D11.VIEWPORT {
		Width    = f32(window.size.x),
		Height   = f32(window.size.y),
		MaxDepth = 1,
	}
	state.device_ctx->RSSetViewports(1, &viewport)
}

flush_batch :: proc() -> bool {
	if len(state.batch.instanced) == 0 {
		return true
	}

	{
		sub_rsrc: D3D11.MAPPED_SUBRESOURCE
		state.device_ctx->Map(
			state.instanced_buffer,
			0,
			.WRITE_DISCARD,
			{},
			&sub_rsrc,
		)

		mem.copy(
			sub_rsrc.pData,
			raw_data(state.batch.instanced[:]),
			len(state.batch.instanced) * size_of(Instance),
		)
		state.device_ctx->Unmap(state.instanced_buffer, 0)
	}

	for &run in state.batch.runs {
		state.device_ctx->PSSetShaderResources(0, 1, &run.binding.texture)
		state.device_ctx->PSSetSamplers(0, 1, &state.samplers[run.binding.sampler_kind],)
		rect := D3D11.RECT {
			left   = run.binding.scissor[0],
			top    = run.binding.scissor[1],
			right  = run.binding.scissor[2],
			bottom = run.binding.scissor[3],
		}
		state.device_ctx->RSSetScissorRects(1, &rect)
		state.device_ctx->DrawInstanced(4, run.count, 0, run.first)
	}

	clear(&state.batch.instanced)
	clear(&state.batch.runs)

	return true
}

present :: proc(sync := u32(1)) {
	flush_batch()
	state.swapchain.swapchain1->Present(sync, nil)
}

upload_uniforms :: proc() {
	size := window_size()
	uniforms.proj_matrix = linalg.matrix_ortho3d_f32(0, size.x, size.y, 0, 0, 1, true)

	sub_rsrc: D3D11.MAPPED_SUBRESOURCE
	state.device_ctx->Map(
		state.uniforms_buffer,
		0,
		.WRITE_DISCARD,
		{},
		&sub_rsrc,
	)

	mem.copy(sub_rsrc.pData, &uniforms, size_of(uniforms))
	state.device_ctx->Unmap(state.uniforms_buffer, 0)
}

uniforms: struct #align (16) {
	proj_matrix: matrix[4, 4]f32,
}

input_layout := []D3D11.INPUT_ELEMENT_DESC {
	{"POS", 0, .R32G32B32A32_FLOAT, 0, 0, .INSTANCE_DATA, 1},
	{"TEX", 0, .R32G32B32A32_FLOAT, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
	{"COL", 0, .R8G8B8A8_UNORM, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
	{"COL", 1, .R8G8B8A8_UNORM, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
	{"COL", 2, .R8G8B8A8_UNORM, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
	{"COL", 3, .R8G8B8A8_UNORM, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
	{"RADIUS", 0, .R32_FLOAT, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
	{"KIND", 0, .R32_UINT, 0, D3D11.APPEND_ALIGNED_ELEMENT, .INSTANCE_DATA, 1},
}

shader := `
cbuffer Globals : register(b0) {
    float4x4 proj_matrix;
}

Texture2D tex : register(t0);
SamplerState tex_sampler : register(s0);

struct vs_in {
    float4 dest     : POS;
    float4 src      : TEX;
    float4 color[4] : COL;
    float radius    : RADIUS;
    uint kind       : KIND;
    uint vertex_id  : SV_VertexID;
};

struct vs_out {
    float4 sv_pos    : SV_POSITION;
    float4 color     : COL;
    float2 tex_uv    : TEXCOORD0;
    float2 sdf_pos   : TEXCOORD1;
    float2 half_size : TEXCOORD2;
    float radius     : RADIUS;
    nointerpolation uint kind : KIND;
};

vs_out vs_main(vs_in input) {
    static const float2 corners[] = {
        { -1, -1 }, // TL
        { +1, -1 }, // TR
        { -1, +1 }, // BL
        { +1, +1 }, // BR
    };

    float2 local_pos = corners[input.vertex_id];
    float4 local_color = input.color[input.vertex_id];
    float2 local_uv = local_pos * 0.5 + 0.5;

    float2 half_size = (input.dest.zw - input.dest.xy) * 0.5;
    float2 center = input.dest.xy + half_size;

    float2 sdf_pos = local_pos * half_size;
    float2 pixel_pos = local_pos * half_size + center;
    float2 tex_uv = lerp(input.src.xy, input.src.zw, local_uv);

    vs_out output;
    output.sv_pos = mul(proj_matrix, float4(pixel_pos, 0.0f, 1.0f));
    output.color = local_color;
    output.tex_uv = tex_uv;
    output.sdf_pos = sdf_pos;
    output.half_size = half_size;
    output.radius = input.radius;
    output.kind = input.kind;

    return output;
}

#define TEXT_THICKNESS 0.6
#define MSDF_PXRANGE   8.0
#define MSDF_TEXSIZE   548.0

#define KIND_RECT  0
#define KIND_TEX2D 1
#define KIND_MSDF  2

float rect_sdf(float2 pos, float2 half_size, float r) {
    float2 q = abs(pos) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float msdf_median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

float some_noise(float2 n) {
    float f = 0.06711056 * n.x + 0.00583715 * n.y;
    return frac(52.9829189 * frac(f));
}

float4 ps_main(vs_out input) : SV_TARGET {
    float alpha = 1.0f;
    float4 tex_color = float4(1, 1, 1, 1);

    if (input.kind == KIND_TEX2D || input.kind == KIND_MSDF) {
        tex_color = tex.Sample(tex_sampler, input.tex_uv);
    }

    switch (input.kind) {
        case KIND_TEX2D:
        case KIND_RECT:
        {
            if (input.radius > 0) {
                float safe_radius = min(input.radius, min(input.half_size.x, input.half_size.y));

                float dist = rect_sdf(input.sdf_pos, input.half_size, safe_radius);

                float aa = fwidth(dist);

                float feather = aa * 0.5;
                alpha = 1.0 - smoothstep(-feather, feather, dist);
            }
        }
        break;

        case KIND_MSDF:
        {
            float sd = msdf_median(tex_color.r, tex_color.g, tex_color.b) - 0.5;

            float2 msdf_tex_size = float2(MSDF_TEXSIZE, MSDF_TEXSIZE);
            float2 unit_range = float2(MSDF_PXRANGE, MSDF_PXRANGE) / msdf_tex_size;

            float2 screen_tex_size = float2(1.0, 1.0) / fwidth(input.tex_uv);
            float screen_px_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);

            float screen_px_dist = screen_px_range * sd;
            float opacity = clamp(screen_px_dist + TEXT_THICKNESS, 0.0, 1.0);

            tex_color = float4(1.0, 1.0, 1.0, opacity);
        }
        break;
    }

    float4 out_color = input.color * tex_color;
    out_color.a *= alpha;

    float noise = some_noise(input.sv_pos.xy);
    noise = (noise - 0.5) / 255.0;
    out_color.rgb += noise;

    return out_color;
}`
