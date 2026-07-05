package fx

import D3D11 "vendor:directx/d3d11"
import D3D_COMPILER "vendor:directx/d3d_compiler"
import win "core:sys/windows"

Shader :: struct {
	vshader: ^D3D11.IVertexShader,
	pshader: ^D3D11.IPixelShader,
	ilayout: ^D3D11.IInputLayout,
}

load_shader :: proc(src: string, dbg_name: cstring) -> Shader {
	shader: Shader

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
	if win.FAILED(hr) {
		ptr := cast([^]byte)vshader_error->GetBufferPointer()
		l := vshader_error->GetBufferSize()
		panic(string(ptr[:l]))
	} else {
		state.device->CreateVertexShader(
			vshader_blob->GetBufferPointer(),
			vshader_blob->GetBufferSize(),
			nil,
			&shader.vshader,
		)
	}

	hr = state.device->CreateInputLayout(
		raw_data(input_layout),
		u32(len(input_layout)),
		vshader_blob->GetBufferPointer(),
		vshader_blob->GetBufferSize(),
		&shader.ilayout,
	)
	if win.FAILED(hr) {
		panic("[ERROR] Failed to create D3D11 input layout")
	}

	defer if vshader_blob != nil {
		vshader_blob->Release()
	}


	// Pixel Shader
	pshader_blob: ^D3D11.IBlob
	pshader_error: ^D3D11.IBlob
	hr = D3D_COMPILER.Compile(
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
		l := pshader_error->GetBufferSize()
		panic(string(ptr[:l]))
	} else {
		state.device->CreatePixelShader(
			pshader_blob->GetBufferPointer(),
			pshader_blob->GetBufferSize(),
			nil,
			&shader.pshader,
		)
	}

	return shader
}

set_shader :: proc(shader: Shader) {
	state.device_ctx->VSSetShader(shader.vshader, nil, 0)
	state.device_ctx->PSSetShader(shader.pshader, nil, 0)
	if shader.ilayout != nil {
		state.device_ctx->IASetInputLayout(shader.ilayout)
	}
}
