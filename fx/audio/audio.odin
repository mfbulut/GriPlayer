package audio

import "core:os"
import "core:slice"
import "core:strings"

import "core:sys/windows"
import "vendor:windows/wasapi"
import "opusfile"
import "vorbisfile"
import "drmp3"
import "drflac"
import "drwav"

Decoder :: union {
    ^opusfile.File,
    ^vorbisfile.File,
    ^drmp3.File,
    ^drflac.File,
    ^drwav.File,
}

state: struct {
    device: ^wasapi.IMMDevice,
    client: ^wasapi.IAudioClient,
    render_client: ^wasapi.IAudioRenderClient,
    decoder: Decoder,
    buffer_size: u32,
    sample_rate: u32,
    total_pcm: i64,
    channels: u32,
}

volume := f32(0.5)
muted := false

initialize :: proc() {
    windows.CoInitializeEx(nil, cast(windows.COINIT)4)
    enumerator: ^wasapi.IMMDeviceEnumerator
    windows.CoCreateInstance(wasapi.CLSID_MMDeviceEnumerator, nil, windows.CLSCTX_INPROC_SERVER, wasapi.IID_IMMDeviceEnumerator, cast(^rawptr)&enumerator)
    enumerator->GetDefaultAudioEndpoint(.Render, .Console, &state.device)
    init_wasapi(48000)
}

init_wasapi :: proc(sample_rate: u32) {
    if state.client != nil {
        state.client->Stop()
        state.client->Release()
    }
    if state.render_client != nil {
        state.render_client->Release()
    }

    state.device->Activate(wasapi.IID_IAudioClient, windows.CLSCTX_INPROC_SERVER, nil, cast(^rawptr)&state.client)

    KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := windows.GUID {0x00000003,0x0000,0x0010,{0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

    format := windows.WAVEFORMATEXTENSIBLE {
        Format = {
            wFormatTag = windows.WAVE_FORMAT_EXTENSIBLE,
            nChannels = 2,
            nSamplesPerSec = sample_rate,
            nAvgBytesPerSec = 32 * 2 * sample_rate / 8,
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
    state.sample_rate = sample_rate
}

open :: proc(path: string, gapless := false) -> bool {
    switch d in state.decoder {
    case ^opusfile.File:
        opusfile.free(d)
    case ^vorbisfile.File:
        vorbisfile.clear(d)
        free(d)
    case ^drmp3.File:
        drmp3.uninit(d)
        free(d)
    case ^drflac.File:
        drflac.close(d)
    case ^drwav.File:
        drwav.uninit(d)
        free(d)
    case:
    }

    state.decoder = nil
    prev_sample_rate := state.sample_rate
    ext := strings.to_lower(os.ext(path), context.temp_allocator)

    switch ext {
    case ".opus":
        if of := opusfile.open_file(path); of != nil {
            opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
            state.decoder = of
            state.sample_rate = 48000
            state.channels = 2
            state.total_pcm = opusfile.pcm_total(of, -1)
        } else {
            return false
        }

    case ".ogg":
        if vf := vorbisfile.open_file(path); vf != nil {
            state.decoder = vf
            info := vorbisfile.info(vf, -1)
            state.sample_rate = u32(info.rate)
            state.channels = u32(info.channels)
            state.total_pcm = vorbisfile.pcm_total(vf, -1)
        } else if of := opusfile.open_file(path); of != nil {
            opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
            state.decoder = of
            state.sample_rate = 48000
            state.channels = 2
            state.total_pcm = opusfile.pcm_total(of, -1)
        } else {
            return false
        }
    case ".mp3":
        if mp3 := drmp3.open_file(path); mp3 != nil {
            state.decoder = mp3
            state.sample_rate = u32(drmp3.get_sampleRate(mp3))
            state.channels = u32(drmp3.get_channels(mp3))
            state.total_pcm = i64(drmp3.get_pcm_frame_count(mp3))
        } else {
            return false
        }
    case ".flac":
        if flac := drflac.open_file(path); flac != nil {
            state.decoder = flac
            state.sample_rate = u32(drflac.get_sampleRate(flac))
            state.channels = u32(drflac.get_channels(flac))
            state.total_pcm = i64(drflac.get_totalPCMFrameCount(flac))
        } else {
            return false
        }
    case ".wav":
        if wav := drwav.open_file(path); wav != nil {
            state.decoder = wav
            state.sample_rate = u32(drwav.get_sampleRate(wav))
            state.channels = u32(drwav.get_channels(wav))
            state.total_pcm = i64(drwav.get_totalPCMFrameCount(wav))
        } else {
            return false
        }
    }

    if state.sample_rate != prev_sample_rate {
        init_wasapi(state.sample_rate)
    } else if gapless == false {
        reset()
    }

    return true
}

update :: proc(callback: proc(samples: [][2]f32) = nil) -> bool {
    if state.decoder == nil do return false

    padding: windows.UINT32
    state.client->GetCurrentPadding(&padding)

    available_frames := state.buffer_size - padding
    if available_frames == 0 do return false

    buffer: [^]u8
    state.render_client->GetBuffer(available_frames, &buffer)

    frames_read: i32
    switch d in state.decoder {
    case ^opusfile.File:
        frames_read = opusfile.read_float_stereo(d, cast([^]f32)buffer, cast(i32)(available_frames * 2))
    case ^drmp3.File:
        temp_buffer := make([]f32, available_frames * state.channels)
        defer delete(temp_buffer)
        frames_read = i32(drmp3.read_pcm_frames_f32(d, u64(available_frames), raw_data(temp_buffer)))
        if frames_read > 0 {
            out := cast([^][2]f32)buffer
            if state.channels >= 2 {
                for i in 0..<frames_read {
                    out[i][0] = temp_buffer[i * 2 + 0]
                    out[i][1] = temp_buffer[i * 2 + 1]
                }
            } else if state.channels == 1 {
                for i in 0..<frames_read {
                    out[i][0] = temp_buffer[i]
                    out[i][1] = temp_buffer[i]
                }
            }
        }
    case ^drflac.File:
        temp_buffer := make([]f32, available_frames * state.channels)
        defer delete(temp_buffer)
        frames_read = i32(drflac.read_pcm_frames_f32(d, u64(available_frames), raw_data(temp_buffer)))
        if frames_read > 0 {
            out := cast([^][2]f32)buffer
            if state.channels >= 2 {
                for i in 0..<frames_read {
                    out[i][0] = temp_buffer[i * 2 + 0]
                    out[i][1] = temp_buffer[i * 2 + 1]
                }
            } else if state.channels == 1 {
                for i in 0..<frames_read {
                    out[i][0] = temp_buffer[i]
                    out[i][1] = temp_buffer[i]
                }
            }
        }
    case ^drwav.File:
        temp_buffer := make([]f32, available_frames * state.channels)
        defer delete(temp_buffer)
        frames_read = i32(drwav.read_pcm_frames_f32(d, u64(available_frames), raw_data(temp_buffer)))
        if frames_read > 0 {
            out := cast([^][2]f32)buffer
            if state.channels >= 2 {
                for i in 0..<frames_read {
                    out[i][0] = temp_buffer[i * 2 + 0]
                    out[i][1] = temp_buffer[i * 2 + 1]
                }
            } else if state.channels == 1 {
                for i in 0..<frames_read {
                    out[i][0] = temp_buffer[i]
                    out[i][1] = temp_buffer[i]
                }
            }
        }
    case ^vorbisfile.File:
        channels: [^][^]f32
        frames_read = vorbisfile.read_float(d, &channels, cast(i32)available_frames, nil)

        if frames_read > 0 {
            out := cast([^][2]f32)buffer

            if state.channels >= 2 {
                left := channels[0]
                right := channels[1]
                for i in 0..<frames_read {
                    out[i][0] = left[i]
                    out[i][1] = right[i]
                }
            } else if state.channels == 1 {
                mono := channels[0]
                for i in 0..<frames_read {
                    out[i][0] = mono[i]
                    out[i][1] = mono[i]
                }
            }
        }
    case:
    }

    if frames_read <= 0 {
        state.render_client->ReleaseBuffer(0, 0)
        return true
    }

    samples := slice.from_ptr(cast(^[2]f32)buffer, int(frames_read))

    if callback != nil {
        callback(samples)
    }

    current_vol := muted ? f32(0) : (volume * volume)
    for &sample in samples {
        sample[0] *= current_vol
        sample[1] *= current_vol
    }

    state.render_client->ReleaseBuffer(u32(frames_read), 0)

    return false
}

seek :: proc(position: f32) {
    if state.decoder == nil do return
    target_pcm := i64(position * f32(state.sample_rate))
    target_pcm = clamp(target_pcm, 0, state.total_pcm - 1)

    switch d in state.decoder {
    case ^opusfile.File:
        opusfile.pcm_seek(d, target_pcm)
    case ^drmp3.File:
        drmp3.seek_to_pcm_frame(d, u64(target_pcm))
    case ^drflac.File:
        drflac.seek_to_pcm_frame(d, u64(target_pcm))
    case ^drwav.File:
        drwav.seek_to_pcm_frame(d, u64(target_pcm))
    case ^vorbisfile.File:
        vorbisfile.pcm_seek(d, target_pcm)
    case:
    }
    reset()
}

position :: proc() -> f32 {
    current_pcm: i64
    switch d in state.decoder {
    case ^opusfile.File:
        current_pcm = opusfile.pcm_tell(d)
    case ^vorbisfile.File:
        current_pcm = vorbisfile.pcm_tell(d)
    case ^drmp3.File:
        current_pcm = i64(drmp3.get_currentPCMFrame(d))
    case ^drflac.File:
        current_pcm = i64(drflac.get_currentPCMFrame(d))
    case ^drwav.File:
        current_pcm = i64(drwav.get_currentPCMFrame(d))
    case:
        return 0
    }
    return f32(current_pcm) / f32(state.sample_rate)
}

duration :: proc() -> f32 {
    if state.decoder == nil do return 0
    return f32(state.total_pcm) / f32(state.sample_rate)
}

pause :: proc() {
    state.client->Stop()
}

resume :: proc() {
    state.client->Start()
}

reset :: proc() {
    state.client->Reset()
}