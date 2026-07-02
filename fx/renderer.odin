package fx

import "core:math/linalg"
import "core:mem"

import win "core:sys/windows"
import D3D11 "vendor:directx/d3d11"

Instance :: struct {
	dst_rect:   [4]f32, // LT, LR, BL, BR
	src_rect:   [4]f32,
	color_rect: [4]Color,
	radius:     f32,
	kind:       enum u32 {
		Rect,
		Texture,
		Text,
	},
}

Binding :: struct {
	sampler_kind: Sampler_Kind,
	depth_kind:   Depth_Kind,
	tex2d_srv:    ^D3D11.IShaderResourceView,
	scissor:      [4]i32,
}

Batch_Run :: struct {
	binding:    Binding,
	first, count: u32,
}

INSTANCED_MAX :: 1024 * 16
RUNS_MAX :: 1024 * 4

Batch :: struct {
	instanced: [dynamic; INSTANCED_MAX]Instance,
	runs:      [dynamic; RUNS_MAX]Batch_Run,
	binding:   Binding,
}

renderer_initialize :: proc() {
	// Instance buffer
	desc := D3D11.BUFFER_DESC {
		ByteWidth      = INSTANCED_MAX * size_of(Instance),
		Usage          = .DYNAMIC,
		BindFlags      = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}

	hr := d3d11_state.device->CreateBuffer(&desc, nil, &d3d11_state.instanced_buffer_gpu)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create draw instance buffer")
	}

	// Shader + uniforms
	d3d11_vshader_init(shader, "shader.hlsl")
	d3d11_pshader_init(shader, "shader.hlsl")
	d3d11_uniforms_init(type_of(uniforms))

	// Bind pipeline
	stride := cast(u32)size_of(Instance)
	offset := u32(0)
	d3d11_state.device_ctx->IASetVertexBuffers(0, 1, &d3d11_state.instanced_buffer_gpu, &stride, &offset,)
	d3d11_state.device_ctx->IASetInputLayout(d3d11_state.ilayout)
	d3d11_state.device_ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)

	d3d11_state.device_ctx->VSSetShader(d3d11_state.vshader, nil, 0)
	d3d11_state.device_ctx->VSSetConstantBuffers(0, 1, &d3d11_state.uniforms_buffer_gpu)

	d3d11_state.device_ctx->PSSetShader(d3d11_state.pshader, nil, 0)
	d3d11_state.device_ctx->PSSetConstantBuffers(0, 1, &d3d11_state.uniforms_buffer_gpu)

	d3d11_state.device_ctx->RSSetState(d3d11_state.rasterizer)
	d3d11_state.device_ctx->OMSetBlendState(d3d11_state.blend_state, nil, 0xffffffff)
}

clear_window :: proc(color: Color) {
	tmp_color := color_to_vec4(color)
	d3d11_state.device_ctx->ClearRenderTargetView(d3d11_state.swapchain.default_rtv, &tmp_color)
}

begin_frame :: proc() {
	logical_size := window_size()
	pixel_size := window_size_pixels()

	d3d11_state.batch.binding.scissor = {0, 0, cast(i32)pixel_size.x, cast(i32)pixel_size.y}

	if window.is_resized {
		d3d11_resize_swapchain(pixel_size)
	} else {
		d3d11_state.device_ctx->OMSetRenderTargets(1, &d3d11_state.swapchain.default_rtv, nil)
		viewport := D3D11.VIEWPORT {
			Width    = pixel_size.x,
			Height   = pixel_size.y,
			MaxDepth = 1,
		}
		d3d11_state.device_ctx->RSSetViewports(1, &viewport)
	}

	upload_uniforms(logical_size)
}

set_sampler :: proc(kind: Sampler_Kind) {
	d3d11_state.batch.binding.sampler_kind = kind
}
set_depth :: proc(kind: Depth_Kind) {
	d3d11_state.batch.binding.depth_kind = kind
}
set_scissor :: proc(rect: Rect) {
	scale := dpi_scale()
	d3d11_state.batch.binding.scissor = {
		cast(i32)(rect.x * scale),
		cast(i32)(rect.y * scale),
		cast(i32)((rect.x + rect.w) * scale),
		cast(i32)((rect.y + rect.h) * scale),
	}
}
reset_scissor :: proc() {
	ws := window_size()
	set_scissor({0, 0, ws.x, ws.y})
}

rect :: proc(r: Rect, color_rect: [4]Color, radius := f32(0)) {
	add_instance(
		Instance {
			dst_rect = {r.x, r.y, r.x + r.w, r.y + r.h},
			color_rect = color_rect,
			radius = radius,
			kind = .Rect,
		},
	)
}

rect_vec :: proc(pos, size: Vec2, color_rect: [4]Color, radius := f32(0)) {
	rect(Rect{pos.x, pos.y, size.x, size.y}, color_rect, radius)
}

circle :: proc(center: Vec2, radius: f32, color_rect: [4]Color) {
	top_left := center - radius
	rect_vec(top_left, radius * 2, color_rect, radius)
}

sprite_ex :: proc(
	tex: Texture,
	src_rect: Rect,
	dst_rect: Rect,
	tint_rect := cast([4]Color)WHITE,
	radius := f32(0),
) {
	d3d11_state.batch.binding.tex2d_srv = tex.srv

	tw := cast(f32)tex.size.x
	th := cast(f32)tex.size.y

	src_rect_arr := [4]f32 {
		src_rect.x / tw,
		src_rect.y / th,
		(src_rect.x + src_rect.w) / tw,
		(src_rect.y + src_rect.h) / th,
	}

	add_instance(
		Instance {
			src_rect = src_rect_arr,
			dst_rect = {dst_rect.x, dst_rect.y, dst_rect.x + dst_rect.w, dst_rect.y + dst_rect.h},
			color_rect = tint_rect,
			radius = radius,
			kind = .Texture,
		},
	)
}

sprite :: proc(tex: Texture, rect: Rect, tint_rect := cast([4]Color)WHITE, radius := f32(0)) {
	sprite_ex(tex, {0, 0, f32(tex.size.x), f32(tex.size.y)}, rect, tint_rect, radius)
}

text :: proc {
	text_vec,
	text_rect,
}

text_vec :: proc(font: Font, str: string, pos: Vec2, font_size: f32, color_rect: [4]Color) {
	if str == "" do return

	d3d11_state.batch.binding.tex2d_srv = font.atlas.srv

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := pos.x
	y := pos.y + (font.metrics.ascender * font_scale)

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y

	for char in str {
		if char == '\n' {
			x = pos.x
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		dst_rect := [4]f32 {
			x + (glyph.planeBounds.left * font_scale),
			y - (glyph.planeBounds.top * font_scale),
			x + (glyph.planeBounds.right * font_scale),
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src_rect := [4]f32 {
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance {
				dst_rect = dst_rect,
				src_rect = src_rect,
				color_rect = color_rect,
				kind = .Text,
			},
		)

		x += glyph.advance * font_scale
	}
}

text_rect :: proc(font: Font, str: string, bounds: Rect, font_size: f32, color: Color, center_x := false, center_y := false) {
	if str == "" do return

	d3d11_state.batch.binding.tex2d_srv = font.atlas.srv

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := bounds.x
	y := bounds.y + (font.metrics.ascender * font_scale)

	if center_x || center_y {
		size := text_size(font, str, font_size)
		if center_x {
			x = bounds.x + (bounds.w - size.x) * 0.5
		}
		if center_y {
			y = bounds.y + (bounds.h - line_h) * 0.5 + (font.metrics.ascender * font_scale)
		}
	}

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y
	color_rect := [4]Color{color, color, color, color}

	for char in str {
		if char == '\n' {
			x = bounds.x
			if center_x {
				size := text_size(font, str, font_size)
				x = bounds.x + (bounds.w - size.x) * 0.5
			}
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		dst_rect := [4]f32 {
			x + (glyph.planeBounds.left * font_scale),
			y - (glyph.planeBounds.top * font_scale),
			x + (glyph.planeBounds.right * font_scale),
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src_rect := [4]f32 {
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance {
				dst_rect = dst_rect,
				src_rect = src_rect,
				color_rect = color_rect,
				kind = .Text,
			},
		)

		x += glyph.advance * font_scale
	}
}

text_faded :: proc(font: Font, str: string, bounds: Rect, font_size: f32, color: Color, center_y := false) {
	if str == "" do return

	d3d11_state.batch.binding.tex2d_srv = font.atlas.srv

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := bounds.x
	y := bounds.y + (font.metrics.ascender * font_scale)

	if center_y {
		y = bounds.y + (bounds.h - line_h) * 0.5 + (font.metrics.ascender * font_scale)
	}

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y

	max_w := bounds.w
	fade_w := min(f32(30), max_w)
	fade_start := bounds.x + max_w - fade_w

	for char in str {
		if char == '\n' {
			x = bounds.x
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		left_x := x + (glyph.planeBounds.left * font_scale)
		right_x := x + (glyph.planeBounds.right * font_scale)

		if left_x > bounds.x + max_w {
			break
		}

		alpha_l := f32(1.0)
		if left_x > fade_start {
			alpha_l = 1.0 - clamp((left_x - fade_start) / fade_w, 0.0, 1.0)
		}

		alpha_r := f32(1.0)
		if right_x > fade_start {
			alpha_r = 1.0 - clamp((right_x - fade_start) / fade_w, 0.0, 1.0)
		}

		color_tl := color
		color_tl.a = u8(f32(color.a) * alpha_l)
		color_bl := color_tl

		color_tr := color
		color_tr.a = u8(f32(color.a) * alpha_r)
		color_br := color_tr

		color_rect := [4]Color{color_tl, color_tr, color_bl, color_br}

		dst_rect := [4]f32 {
			left_x,
			y - (glyph.planeBounds.top * font_scale),
			right_x,
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src_rect := [4]f32 {
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance {
				dst_rect = dst_rect,
				src_rect = src_rect,
				color_rect = color_rect,
				kind = .Text,
			},
		)

		x += glyph.advance * font_scale
	}
}

text_size :: proc(font: Font, text: string, font_size: f32) -> Vec2 {
	if text == "" {
		return {0, 0}
	}

	cursor_x := f32(0)
	max_x := f32(0)

	font_scale := font_size / font.metrics.emSize
	line_height := font.metrics.lineHeight * font_scale

	total_height := line_height

	for char in text {
		if char == '\n' {
			max_x = max(max_x, cursor_x)
			cursor_x = 0
			total_height += line_height
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		cursor_x += glyph.advance * font_scale
	}

	return {max(max_x, cursor_x), total_height}
}

add_instance :: proc(inst: Instance) {
	batch := &d3d11_state.batch
	if len(batch.instanced) + 1 > cap(batch.instanced) {
		if !flush_batch() {
			return
		}
	}

	needs_new_run := len(batch.runs) == 0
	if !needs_new_run {
		last_binding := batch.runs[len(batch.runs) - 1].binding
		needs_new_run = last_binding != batch.binding
	}
	if needs_new_run && len(batch.runs) + 1 > cap(batch.runs) {
		if !flush_batch() {
			return
		}
	}
	if needs_new_run {
		start_index := cast(u32)len(batch.instanced)
		append(&batch.runs, Batch_Run{binding = batch.binding, first = start_index})
	}

	append(&batch.instanced, inst)
	batch.runs[len(batch.runs) - 1].count += 1
}

flush_batch :: proc() -> bool {
	if len(d3d11_state.batch.instanced) == 0 {
		return true
	}

	{ 	// Map instances
		sub_rsrc: D3D11.MAPPED_SUBRESOURCE
		hr := d3d11_state.device_ctx->Map(
			d3d11_state.instanced_buffer_gpu,
			0,
			.WRITE_DISCARD,
			{},
			&sub_rsrc,
		)
		if win.FAILED(hr) {
			panic("[ERROR] Failed to map instanced buffer")
		}

		mem.copy(
			sub_rsrc.pData,
			raw_data(d3d11_state.batch.instanced[:]),
			len(d3d11_state.batch.instanced) * size_of(Instance),
		)
		d3d11_state.device_ctx->Unmap(d3d11_state.instanced_buffer_gpu, 0)
	}

	for &run in d3d11_state.batch.runs {
		d3d11_state.device_ctx->PSSetShaderResources(0, 1, &run.binding.tex2d_srv)
		d3d11_state.device_ctx->PSSetSamplers(0, 1, &d3d11_state.samplers[run.binding.sampler_kind],)
		d3d11_state.device_ctx->OMSetDepthStencilState(d3d11_state.depths[run.binding.depth_kind], 0)
		rect := D3D11.RECT {
			left   = run.binding.scissor[0],
			top    = run.binding.scissor[1],
			right  = run.binding.scissor[2],
			bottom = run.binding.scissor[3],
		}
		d3d11_state.device_ctx->RSSetScissorRects(1, &rect)
		d3d11_state.device_ctx->DrawInstanced(4, run.count, 0, run.first)
	}

	clear(&d3d11_state.batch.instanced)
	clear(&d3d11_state.batch.runs)

	return true
}

upload_uniforms :: proc(size: Vec2) {
	uniforms.proj_matrix = linalg.matrix_ortho3d_f32(0, size.x, size.y, 0, 0, 1, true)

	sub_rsrc: D3D11.MAPPED_SUBRESOURCE
	hr := d3d11_state.device_ctx->Map(
		d3d11_state.uniforms_buffer_gpu,
		0,
		.WRITE_DISCARD,
		{},
		&sub_rsrc,
	)

	if win.SUCCEEDED(hr) {
		mem.copy(sub_rsrc.pData, &uniforms, size_of(uniforms))
		d3d11_state.device_ctx->Unmap(d3d11_state.uniforms_buffer_gpu, 0)
	}
}

uniforms: struct #align (16) {
	proj_matrix: matrix[4, 4]f32,
}

vs_input_layout := []D3D11.INPUT_ELEMENT_DESC {
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
SamplerState sampler_ : register(s0);

struct vs_in {
    float4 dst_rect      : POS;
    float4 src_rect      : TEX;
    float4 color_rect[4] : COL;
    float radius         : RADIUS;
    uint kind            : KIND;
    uint vertex_id       : SV_VertexID;
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
    float4 local_color = input.color_rect[input.vertex_id];
    float2 local_uv = local_pos * 0.5 + 0.5;

    float2 half_size = (input.dst_rect.zw - input.dst_rect.xy) * 0.5;
    float2 center = input.dst_rect.xy + half_size;

    float2 sdf_pos = local_pos * half_size;
    float2 pixel_pos = local_pos * half_size + center;
    float2 tex_uv = lerp(input.src_rect.xy, input.src_rect.zw, local_uv);

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
        tex_color = tex.Sample(sampler_, input.tex_uv);
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

            uint tex_w, tex_h;
            tex.GetDimensions(tex_w, tex_h);

            float2 msdf_tex_size = float2((float)tex_w, (float)tex_h);
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
