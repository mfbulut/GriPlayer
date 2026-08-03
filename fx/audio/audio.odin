package audio

import "core:os"
import "core:sync"
import "core:thread"

import "core:sys/windows"
import "vendor:windows/wasapi"
import "vendor:stb/vorbis"
import "opusfile"
import "drmp3"
import "drflac"
import "drwav"

Decoder :: union {
    ^opusfile.File,
    ^vorbis.vorbis,
    ^drmp3.File,
    ^drflac.File,
    ^drwav.File,
}

state: struct {
    mu:            sync.Mutex,
    device:        ^wasapi.IMMDevice,
    audio_client:  ^wasapi.IAudioClient,
    render_client: ^wasapi.IAudioRenderClient,
    buffer_event:  windows.HANDLE,
    decoder:       Decoder,
    buffer_size:   u32,
    total_pcm:     i64,
    channels:      u32,
    sample_rate:   u32,
    volume:        f32,
    song_finished: bool,
    callback: proc(samples: [][2]f32),
}

initialize :: proc() {
    windows.CoInitializeEx(nil, .MULTITHREADED)
    enumerator: ^wasapi.IMMDeviceEnumerator
    windows.CoCreateInstance(wasapi.CLSID_MMDeviceEnumerator, nil, windows.CLSCTX_INPROC_SERVER, wasapi.IID_IMMDeviceEnumerator, cast(^rawptr)&enumerator)
    enumerator->GetDefaultAudioEndpoint(.Render, .Console, &state.device)
    state.buffer_event = windows.CreateEventW(nil, false, false, nil)

    state.volume = 0.5
    eq_recalculate_all()

    init_wasapi(48000)
    thread.run(audio_thread_proc)
}

init_wasapi :: proc(new_sample_rate: u32) {
    if state.audio_client != nil {
        state.audio_client->Stop()
        state.audio_client->Release()
    }
    if state.render_client != nil {
        state.render_client->Release()
    }

    state.device->Activate(wasapi.IID_IAudioClient, windows.CLSCTX_INPROC_SERVER, nil, cast(^rawptr)&state.audio_client)

    format := windows.WAVEFORMATEXTENSIBLE {
        Format = {
            wFormatTag = windows.WAVE_FORMAT_EXTENSIBLE,
            nChannels = 2,
            nSamplesPerSec = new_sample_rate,
            nAvgBytesPerSec = 32 * 2 * new_sample_rate / 8,
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
    state.audio_client->Initialize(.SHARED, stream_flags, 500000, 0, cast(^wasapi.WAVEFORMATEX)&format, nil)
    state.audio_client->SetEventHandle(state.buffer_event)
    state.audio_client->GetService(wasapi.IID_IAudioRenderClient, cast(^rawptr)&state.render_client)
    state.audio_client->GetBufferSize(&state.buffer_size)
    state.sample_rate = new_sample_rate
    eq_recalculate_all()
}

open :: proc(path: string) -> bool {
    sync.mutex_guard(&state.mu)

    switch d in state.decoder {
    case ^opusfile.File:
        opusfile.free(d)
    case ^vorbis.vorbis:
        vorbis.close(d)
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

    switch os.ext(path) {
    case ".opus", ".OPUS":
        if of := opusfile.open_file(path); of != nil {
            opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
            state.decoder = of
            state.sample_rate = 48000
            state.channels = 2
            state.total_pcm = opusfile.pcm_total(of, -1)
        }
    case ".ogg", ".OGG":
        if vf := open_vorbis_file(path); vf != nil {
            state.decoder = vf
            info := vorbis.get_info(vf)
            state.sample_rate = info.sample_rate
            state.channels = u32(info.channels)
            state.total_pcm = i64(vorbis.stream_length_in_samples(vf))
        } else if of := opusfile.open_file(path); of != nil {
            opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
            state.decoder = of
            state.sample_rate = 48000
            state.channels = 2
            state.total_pcm = opusfile.pcm_total(of, -1)
        }
    case ".mp3", ".MP3":
        if mp3 := drmp3.open_file(path); mp3 != nil {
            state.decoder = mp3
            state.sample_rate = drmp3.get_sampleRate(mp3)
            state.channels = drmp3.get_channels(mp3)
            state.total_pcm = i64(drmp3.get_pcm_frame_count(mp3))
        }
    case ".flac", ".FLAC":
        if flac := drflac.open_file(path); flac != nil {
            state.decoder = flac
            state.sample_rate = drflac.get_sampleRate(flac)
            state.channels = drflac.get_channels(flac)
            state.total_pcm = i64(drflac.get_totalPCMFrameCount(flac))
        }
    case ".wav", ".WAV":
        if wav := drwav.open_file(path); wav != nil {
            state.decoder = wav
            state.sample_rate = drwav.get_sampleRate(wav)
            state.channels = drwav.get_channels(wav)
            state.total_pcm = i64(drwav.get_totalPCMFrameCount(wav))
        }
    }

    if state.decoder == nil do return false

    if state.sample_rate != prev_sample_rate {
        init_wasapi(state.sample_rate)
    }

    state.song_finished = false
    return true
}

temp_buffer: [500000 * 8]f32

audio_thread_proc :: proc() {
    windows.CoInitializeEx(nil, .MULTITHREADED)

    for {
        windows.WaitForSingleObject(state.buffer_event, windows.INFINITE)

        sync.mutex_guard(&state.mu)
        if state.decoder == nil do continue

        padding: u32
        state.audio_client->GetCurrentPadding(&padding)
        frames_available := state.buffer_size - padding
        if frames_available == 0 do continue

        buffer: [^]byte
        state.render_client->GetBuffer(frames_available, &buffer)

        frames_read: i32 = 0

        for frames_read < i32(frames_available) {
            needed := frames_available - u32(frames_read)
            read_count: i32 = 0
            buf_offset := frames_read * i32(state.channels)

            switch d in state.decoder {
            case ^opusfile.File:
                read_count = opusfile.read_float_stereo(d, &temp_buffer[buf_offset], i32(needed * state.channels))
            case ^vorbis.vorbis:
                read_count = vorbis.get_samples_float_interleaved(d, i32(state.channels), &temp_buffer[buf_offset], i32(needed * state.channels))
            case ^drmp3.File:
                read_count = i32(drmp3.read_pcm_frames_f32(d, u64(needed), &temp_buffer[buf_offset]))
            case ^drflac.File:
                read_count = i32(drflac.read_pcm_frames_f32(d, u64(needed), &temp_buffer[buf_offset]))
            case ^drwav.File:
                read_count = i32(drwav.read_pcm_frames_f32(d, u64(needed), &temp_buffer[buf_offset]))
            }

            if read_count <= 0 do break
            frames_read += read_count
        }

        samples := (cast([^][2]f32)buffer)[:frames_read]

        if state.channels == 2 {
            for i in 0..<frames_read {
                samples[i][0] = temp_buffer[i * 2 + 0]
                samples[i][1] = temp_buffer[i * 2 + 1]
            }
        } else if state.channels == 1 {
            for i in 0..<frames_read {
                samples[i][0] = temp_buffer[i]
                samples[i][1] = temp_buffer[i]
            }
        } else {
            ch := i32(state.channels)
            for i in 0..<frames_read {
                samples[i][0] = temp_buffer[i * ch + 0]
                samples[i][1] = temp_buffer[i * ch + 1]
            }
        }

        eq_process(samples)

        if state.callback != nil {
            state.callback(samples)
        }

        current_vol := state.volume * state.volume
        for &sample in samples {
            sample *= current_vol
        }

        state.render_client->ReleaseBuffer(u32(frames_read), 0)

        if frames_read == 0 {
            state.song_finished = true
        }
    }
}

seek :: proc(position: f32) {
    sync.mutex_guard(&state.mu)

    if state.decoder == nil do return
    target_pcm := i64(position * f32(state.sample_rate))
    target_pcm = clamp(target_pcm, 0, state.total_pcm - 1)

    switch d in state.decoder {
    case ^opusfile.File:
        opusfile.pcm_seek(d, target_pcm)
    case ^vorbis.vorbis:
        vorbis.seek(d, u32(target_pcm))
    case ^drmp3.File:
        drmp3.seek_to_pcm_frame(d, u64(target_pcm))
    case ^drflac.File:
        drflac.seek_to_pcm_frame(d, u64(target_pcm))
    case ^drwav.File:
        drwav.seek_to_pcm_frame(d, u64(target_pcm))
    case:
    }

    state.audio_client->Reset()
}

position :: proc() -> f32 {
    sync.mutex_guard(&state.mu)

    current_pcm: i64
    switch d in state.decoder {
    case ^opusfile.File:
        current_pcm = opusfile.pcm_tell(d)
    case ^vorbis.vorbis:
        current_pcm = i64(vorbis.get_sample_offset(d))
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
    sync.mutex_guard(&state.mu)
    if state.decoder == nil do return 0
    return f32(state.total_pcm) / f32(state.sample_rate)
}

pause :: proc() {
    sync.mutex_guard(&state.mu)
    state.audio_client->Stop()
}

resume :: proc() {
    sync.mutex_guard(&state.mu)
    state.audio_client->Start()
}

reset :: proc() {
    sync.mutex_guard(&state.mu)
    state.audio_client->Reset()
}

get_volume :: proc() -> f32 {
    sync.mutex_guard(&state.mu)
    return state.volume
}

set_volume :: proc(vol: f32) {
    sync.mutex_guard(&state.mu)
    state.volume = clamp(vol, 0, 1)
}

get_sample_rate :: proc() -> u32 {
    sync.mutex_guard(&state.mu)
    return state.sample_rate
}

is_finished :: proc() -> bool {
    sync.mutex_guard(&state.mu)
    return state.song_finished
}

set_callback :: proc(cb: proc(samples: [][2]f32)) {
    sync.mutex_guard(&state.mu)
    state.callback = cb
}