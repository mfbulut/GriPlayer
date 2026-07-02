package audio

import "core:slice"
import "core:strings"

import win "core:sys/windows"
import "opusfile"
import "wasapi"

SAMPLES_PER_SECOND :: 48000
BITS_PER_CHANNEL :: 32
CHANNEL_COUNT :: 2

state: struct {
    client:        ^wasapi.IAudioClient,
    render_client: ^wasapi.IAudioRenderClient,
    volume:        ^wasapi.ISimpleAudioVolume,
    buffer_size:   win.UINT32,
    of:            ^opusfile.OggOpusFile,
}

initialize :: proc() {
    hr := win.CoInitializeEx(nil, cast(win.COINIT)2)
    if hr != win.S_OK && hr != win.S_FALSE {
        panic("[ERROR] Failed to initialize COM")
    }

    enumerator: ^wasapi.IMMDeviceEnumerator
    hr = win.CoCreateInstance(&wasapi.CLSID_MMDeviceEnumerator, nil, win.CLSCTX_ALL, &wasapi.IID_IMMDeviceEnumerator, cast(^rawptr)&enumerator)
    if win.FAILED(hr) do panic("[ERROR] Failed to create MMDeviceEnumerator")
    defer (cast(^win.IUnknown)enumerator)->Release()

    device: ^wasapi.IMMDevice
    hr = enumerator->GetDefaultAudioEndpoint(.eRender, .eConsole, &device)
    if win.FAILED(hr) do panic("[ERROR] Failed to get default audio endpoint")
    defer (cast(^win.IUnknown)device)->Release()

    hr = device->Activate(&wasapi.IID_IAudioClient, win.CLSCTX_ALL, nil, cast(^rawptr)&state.client)
    if win.FAILED(hr) do panic("[ERROR] Failed to activate IAudioClient")

    KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := win.GUID {0x00000003,0x0000,0x0010,{0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

    format := win.WAVEFORMATEXTENSIBLE {
        Format = {
            wFormatTag = win.WAVE_FORMAT_EXTENSIBLE,
            nChannels = CHANNEL_COUNT,
            nSamplesPerSec = SAMPLES_PER_SECOND,
            nAvgBytesPerSec = BITS_PER_CHANNEL * CHANNEL_COUNT * SAMPLES_PER_SECOND / 8,
            nBlockAlign = BITS_PER_CHANNEL * CHANNEL_COUNT / 8,
            wBitsPerSample = BITS_PER_CHANNEL,
            cbSize = size_of(win.WAVEFORMATEXTENSIBLE) - size_of(win.WAVEFORMATEX),
        },
        Samples = {wValidBitsPerSample = BITS_PER_CHANNEL},
        dwChannelMask = {.FRONT_LEFT, .FRONT_RIGHT},
        SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
    }

    hr = state.client->Initialize(.AUDCLNT_SHAREMODE_SHARED, wasapi.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | wasapi.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 500000, 0, cast(^win.WAVEFORMATEX)&format, nil)
    if win.FAILED(hr) do panic("[WARN] Failed to initialize IAudioClient with preferred format. Error:")

    hr = state.client->GetService(&wasapi.IID_IAudioRenderClient, cast(^rawptr)&state.render_client)
    if win.FAILED(hr) do panic("[ERROR] Failed to get IAudioRenderClient")

    hr = state.client->GetService(&wasapi.IID_ISimpleAudioVolume, cast(^rawptr)&state.volume)
    if win.FAILED(hr) do panic("[WARN] Failed to get ISimpleAudioVolume")

    hr = state.client->Start()
    if win.FAILED(hr) do panic("[ERROR] Failed to start IAudioClient")

    hr = state.client->GetBufferSize(&state.buffer_size)
    if win.FAILED(hr) do panic("[ERROR] Failed to get buffer size")
}

open :: proc(path: string, gapless := false) -> bool {
    if state.of != nil {
        opusfile.free(state.of)
        state.of = nil
    }

    c_str := strings.clone_to_cstring(path, context.temp_allocator)
    of := opusfile.open_file(c_str, nil)
    if of == nil do return false
    opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
    state.of = of

    if gapless == false {
        state.client->Reset()
    }

    return true
}

update :: proc(callback: proc(samples: [][2]f32) = nil) -> bool {
    if state.of == nil do return false

    padding: win.UINT32
    hr := state.client->GetCurrentPadding(&padding)
    if win.FAILED(hr) do return false

    available_frames := state.buffer_size - padding
    if available_frames == 0 do return false

    buffer: [^]f32
    hr = state.render_client->GetBuffer(available_frames, cast(^^win.BYTE)&buffer)
    if win.FAILED(hr) do return false

    frames_read := opusfile.read_float_stereo(state.of, buffer, cast(i32)(available_frames * CHANNEL_COUNT))

    if frames_read < 0 {
        state.render_client->ReleaseBuffer(0, 0)
        return true
    } else if frames_read == 0 {
        state.render_client->ReleaseBuffer(0, 0)
        return true
    }

    if callback != nil {
        samples_slice := slice.from_ptr(cast(^[2]f32)buffer, int(frames_read))
        callback(samples_slice)
    }

    state.render_client->ReleaseBuffer(u32(frames_read), 0)

    return false
}

seek :: proc(position: f32) {
    total_pcm := opusfile.pcm_total(state.of, -1)
    target_pcm := clamp(i64(position * SAMPLES_PER_SECOND), 0, total_pcm - 1)
    opusfile.pcm_seek(state.of, target_pcm)
    state.client->Reset()
}

position :: proc() -> f32 {
    current_pcm := opusfile.pcm_tell(state.of)
    return f32(current_pcm) / SAMPLES_PER_SECOND
}

duration :: proc() -> f32 {
    total_pcm := opusfile.pcm_total(state.of, -1)
    return f32(total_pcm) / SAMPLES_PER_SECOND
}

pause :: proc() {
    state.client->Stop()
}

resume :: proc() {
    state.client->Start()
}

set_volume :: proc(volume: f32) {
    v := clamp(volume * volume, 0.0, 1.0)
    state.volume->SetMasterVolume(v, nil)
}