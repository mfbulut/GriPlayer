package audio

import "core:sync"
import "core:thread"
import "core:sys/windows"
import "vendor:windows/wasapi"

wasapi_state: struct {
	device:        ^wasapi.IMMDevice,
	audio_client:  ^wasapi.IAudioClient,
	render_client: ^wasapi.IAudioRenderClient,
	buffer_event:  windows.HANDLE,
	buffer_size:   u32,
}

init :: proc() {
	decoder.volume = 0.5
	for i in 0 ..< 10 {
		eq_recalculate_band(i)
	}
	thread.run(audio_thread_proc)
}

audio_thread_proc :: proc() {
	if sync.guard(&global_mutex) {
		windows.CoInitializeEx(nil, .MULTITHREADED)
		enumerator: ^wasapi.IMMDeviceEnumerator
		windows.CoCreateInstance(wasapi.CLSID_MMDeviceEnumerator, nil, windows.CLSCTX_INPROC_SERVER, wasapi.IID_IMMDeviceEnumerator, cast(^rawptr)&enumerator)
		if enumerator != nil {
			enumerator->GetDefaultAudioEndpoint(.Render, .Console, &wasapi_state.device)
			enumerator->Release()
		}
		if wasapi_state.device == nil do return

		wasapi_state.buffer_event = windows.CreateEventW(nil, false, false, nil)
		wasapi_state.device->Activate(wasapi.IID_IAudioClient, windows.CLSCTX_INPROC_SERVER, nil, cast(^rawptr)&wasapi_state.audio_client)

		if wasapi_state.audio_client == nil do return

		format := windows.WAVEFORMATEXTENSIBLE {
			Format = {
				wFormatTag = windows.WAVE_FORMAT_EXTENSIBLE,
				nChannels = 2,
				nSamplesPerSec = 48000,
				nAvgBytesPerSec = 32 * 2 * 48000 / 8,
				nBlockAlign = 32 * 2 / 8,
				wBitsPerSample = 32,
				cbSize = size_of(windows.WAVEFORMATEXTENSIBLE) - size_of(windows.WAVEFORMATEX),
			},
			Samples = {wValidBitsPerSample = 32},
			dwChannelMask = {.FRONT_LEFT, .FRONT_RIGHT},
			SubFormat = wasapi.KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
		}

		stream_flags := cast(windows.DWORD)wasapi.AUDCLNT_FLAG.STREAM_AUTOCONVERTPCM |
						cast(windows.DWORD)wasapi.AUDCLNT_FLAG.STREAM_SRC_DEFAULT_QUALITY |
						cast(windows.DWORD)wasapi.AUDCLNT_FLAG.STREAM_EVENTCALLBACK

		res := wasapi_state.audio_client->Initialize(.SHARED, stream_flags, 500000, 0, cast(^wasapi.WAVEFORMATEX)&format, nil)

		if res == 0 {
			wasapi_state.audio_client->SetEventHandle(wasapi_state.buffer_event)
			wasapi_state.audio_client->GetService(wasapi.IID_IAudioRenderClient, cast(^rawptr)&wasapi_state.render_client)
			wasapi_state.audio_client->GetBufferSize(&wasapi_state.buffer_size)
		}
	}

	for {
		windows.WaitForSingleObject(wasapi_state.buffer_event, windows.INFINITE)

		sync.guard(&global_mutex)

		if wasapi_state.audio_client == nil || wasapi_state.render_client == nil do continue

		padding: u32
		if wasapi_state.audio_client->GetCurrentPadding(&padding) != 0 do continue

		if padding >= wasapi_state.buffer_size do continue
		frames_available := wasapi_state.buffer_size - padding
		if frames_available == 0 do continue

		buffer: [^]byte
		hr := wasapi_state.render_client->GetBuffer(frames_available, &buffer)
		if hr != 0 || buffer == nil do continue

		samples := (cast([^][2]f32)buffer)[:frames_available]
		frames_read := read_float(samples)

		wasapi_state.render_client->ReleaseBuffer(u32(frames_read), 0)
	}
}

pause :: proc() {
	sync.guard(&global_mutex)
	if wasapi_state.audio_client != nil {
		wasapi_state.audio_client->Stop()
	}
}

resume :: proc() {
	sync.guard(&global_mutex)
	if wasapi_state.audio_client != nil {
		wasapi_state.audio_client->Start()
	}
}

wasapi_reset :: proc() {
	if wasapi_state.audio_client != nil {
		wasapi_state.audio_client->Stop()
		wasapi_state.audio_client->Reset()
	}
}

reset :: proc() {
	sync.guard(&global_mutex)
	wasapi_reset()
}