package audio

import "core:slice"
import "core:strings"

import "core:sys/windows"
import "vendor:windows/wasapi"
import "opusfile"

SAMPLES_PER_SECOND :: 48000

state: struct {
    client: ^wasapi.IAudioClient,
    render_client: ^wasapi.IAudioRenderClient,
    buffer_size: windows.UINT32,
    of: ^opusfile.OggOpusFile,
    volume: f32,
}

initialize :: proc() {
    windows.CoInitializeEx(nil, cast(windows.COINIT)4)

    enumerator: ^wasapi.IMMDeviceEnumerator
    windows.CoCreateInstance(wasapi.CLSID_MMDeviceEnumerator, nil, windows.CLSCTX_INPROC_SERVER, wasapi.IID_IMMDeviceEnumerator, cast(^rawptr)&enumerator)

    device: ^wasapi.IMMDevice
    enumerator->GetDefaultAudioEndpoint(.Render, .Console, &device)
    device->Activate(wasapi.IID_IAudioClient, windows.CLSCTX_INPROC_SERVER, nil, cast(^rawptr)&state.client)

    KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := windows.GUID {0x00000003,0x0000,0x0010,{0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

    format := windows.WAVEFORMATEXTENSIBLE {
        Format = {
            wFormatTag = windows.WAVE_FORMAT_EXTENSIBLE,
            nChannels = 2,
            nSamplesPerSec = SAMPLES_PER_SECOND,
            nAvgBytesPerSec = 32 * 2 * SAMPLES_PER_SECOND / 8,
            nBlockAlign = 32 * 2 / 8,
            wBitsPerSample = 32,
            cbSize = size_of(windows.WAVEFORMATEXTENSIBLE) - size_of(windows.WAVEFORMATEX),
        },
        Samples = {wValidBitsPerSample = 32},
        dwChannelMask = {.FRONT_LEFT, .FRONT_RIGHT},
        SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
    }

    stream_flags := cast(windows.DWORD)wasapi.AUDCLNT_FLAG.STREAM_AUTOCONVERTPCM | cast(windows.DWORD)wasapi.AUDCLNT_FLAG.STREAM_SRC_DEFAULT_QUALITY

    state.client->Initialize(.SHARED, stream_flags, 500000, 0, cast(^wasapi.WAVEFORMATEX)&format, nil)
    state.client->GetService(wasapi.IID_IAudioRenderClient, cast(^rawptr)&state.render_client)
    state.client->GetBufferSize(&state.buffer_size)
    state.volume = 1.0
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

    padding: windows.UINT32
    state.client->GetCurrentPadding(&padding)

    available_frames := state.buffer_size - padding
    if available_frames == 0 do return false

    buffer: [^]u8
    state.render_client->GetBuffer(available_frames, &buffer)

    frames_read := opusfile.read_float_stereo(state.of, cast([^]f32)buffer, cast(i32)(available_frames * 2))

    if frames_read <= 0 {
        state.render_client->ReleaseBuffer(0, 0)
        return true
    }

    samples_slice := slice.from_ptr(cast(^[2]f32)buffer, int(frames_read))

    for &sample in samples_slice {
        sample[0] *= state.volume
        sample[1] *= state.volume
    }

    if callback != nil {
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
    state.volume = clamp(volume * volume, 0.0, 1.0)
}