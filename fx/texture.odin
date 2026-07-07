package fx

import win "core:sys/windows"
import D3D11 "vendor:directx/d3d11"
import "vendor:stb/image"

Texture :: struct {
	srv:  ^D3D11.IShaderResourceView,
	size: [2]int,
}

texture_load_raw :: proc(bytes: []byte, width: int, height: int, mipmaps := true) -> Texture {
	tex := Texture {
		size = {width, height}
	}

	d3d_tex: ^D3D11.ITexture2D

	tex_desc := D3D11.TEXTURE2D_DESC {
		Width = u32(width),
		Height = u32(height),
		MipLevels = mipmaps ? 0 : 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1, Quality = 0},
		Usage = mipmaps ? .DEFAULT : .IMMUTABLE,
		BindFlags = mipmaps ? {.SHADER_RESOURCE, .RENDER_TARGET} : {.SHADER_RESOURCE},
		CPUAccessFlags = {},
		MiscFlags = mipmaps ? {.GENERATE_MIPS} : {},
	}

	init_data := D3D11.SUBRESOURCE_DATA {
		pSysMem          = raw_data(bytes),
		SysMemPitch      = u32(width * 4),
		SysMemSlicePitch = 0,
	}
	p_init_data := mipmaps ? nil : &init_data

	hr := state.device->CreateTexture2D(&tex_desc, p_init_data, &d3d_tex)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create D3D11 Texture2D")
	}

	if mipmaps {
		state.device_ctx->UpdateSubresource(
			cast(^D3D11.IResource)d3d_tex,
			0,
			nil,
			raw_data(bytes),
			u32(width * 4),
			0,
		)
	}

	srv_desc := D3D11.SHADER_RESOURCE_VIEW_DESC {
		Format = .R8G8B8A8_UNORM,
		ViewDimension = .TEXTURE2D,
		Texture2D = {MipLevels = mipmaps ? 0xFFFFFFFF : 1},
	}

	hr = state.device->CreateShaderResourceView(d3d_tex, &srv_desc, &tex.srv)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create D3D11 Shader Resource View")
	}

	if mipmaps {
		state.device_ctx->GenerateMips(tex.srv)
	}

	if d3d_tex != nil {
		d3d_tex->Release()
	}

	return tex
}

texture_load :: proc(bytes: []byte, mipmaps := true) -> Texture {
	if len(bytes) == 0 do return {}

	w, h, channels: i32
	pixels := image.load_from_memory(raw_data(bytes), cast(i32)len(bytes), &w, &h, &channels, 4)

	if pixels == nil {
		return {}
	}
	defer image.image_free(pixels)

	return texture_load_raw(pixels[:w * h * 4], cast(int)w, cast(int)h, mipmaps)
}

texture_free :: proc(tex: ^Texture) {
	if tex.srv != nil {
		tex.srv->Release()
	}

	tex^ = {}
}
