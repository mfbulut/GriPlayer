package fx

import "core:os"

import win "core:sys/windows"
import D3D11 "vendor:directx/d3d11"
import stbi "vendor:stb/image"

Texture :: struct {
	srv:  ^D3D11.IShaderResourceView,
	size: [2]int,
}

load_texture_raw :: proc(bytes: []byte, width: int, height: int, mipmaps := true) -> Texture {
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

	hr := d3d11_state.device->CreateTexture2D(&tex_desc, p_init_data, &d3d_tex)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create D3D11 Texture2D")
	}

	if mipmaps {
		d3d11_state.device_ctx->UpdateSubresource(
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

	hr = d3d11_state.device->CreateShaderResourceView(d3d_tex, &srv_desc, &tex.srv)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create D3D11 Shader Resource View")
	}

	if mipmaps {
		d3d11_state.device_ctx->GenerateMips(tex.srv)
	}

	if d3d_tex != nil {
		d3d_tex->Release()
	}

	return tex
}

load_texture_from_bytes :: proc(bytes: []byte, mipmaps := true) -> Texture {
	if len(bytes) == 0 do return {}

	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(bytes), cast(i32)len(bytes), &w, &h, &channels, 4)

	if pixels == nil {
		return {}
	}
	defer stbi.image_free(pixels)

	return load_texture_raw(pixels[:w * h * 4], cast(int)w, cast(int)h, mipmaps)
}

load_and_resize_texture :: proc(bytes: []byte, size: int) -> Texture {
	if len(bytes) == 0 do return {}

	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(bytes), cast(i32)len(bytes), &w, &h, &channels, 4)

	if pixels == nil do return {}
	defer stbi.image_free(pixels)

	dest_w, dest_h: int
	if w < h {
		dest_w = size
		dest_h = int(f32(h) * (f32(size) / f32(w)))
	} else {
		dest_h = size
		dest_w = int(f32(w) * (f32(size) / f32(h)))
	}

	resized_pixels := make([]u8, dest_w * dest_h * 4, context.temp_allocator)
	defer delete(resized_pixels, context.temp_allocator)

	success := stbi.resize_uint8(
		pixels, w, h, 0, raw_data(resized_pixels),
		cast(i32)dest_w, cast(i32)dest_h, 0, 4,
	)

	if success == 0 do return {}

	return load_texture_raw(resized_pixels, dest_w, dest_h, false)
}

load_texture_from_file :: proc(filepath: string, mipmaps := true) -> Texture {
	file_data, err := os.read_entire_file(filepath, context.temp_allocator)
	if err != nil {
		return {}
	}

	return load_texture_from_bytes(file_data, mipmaps)
}

load_texture :: proc{
	load_texture_raw,
	load_texture_from_bytes,
	load_texture_from_file,
}

texture_free :: proc(tex: ^Texture) {
	if tex.srv != nil {
		tex.srv->Release()
	}

	tex^ = {}
}
