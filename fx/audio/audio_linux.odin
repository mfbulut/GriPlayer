#+build linux
package audio

import "core:c"
import "core:sync"
import "core:thread"
import "core:time"

snd_pcm_t :: distinct rawptr

// Values from <alsa/asoundlib.h> / <alsa/pcm.h>
SND_PCM_STREAM_PLAYBACK       :: i32(0)
SND_PCM_FORMAT_FLOAT_LE       :: i32(14)
SND_PCM_ACCESS_RW_INTERLEAVED :: i32(3)

foreign import asound "system:asound"

@(default_calling_convention = "c")
foreign asound {
	snd_pcm_open       :: proc(pcm: ^snd_pcm_t, name: cstring, stream: i32, mode: i32) -> i32 ---
	snd_pcm_set_params :: proc(pcm: snd_pcm_t, format: i32, access: i32, channels: u32, rate: u32, soft_resample: i32, latency_us: u32) -> i32 ---
	snd_pcm_writei     :: proc(pcm: snd_pcm_t, buffer: rawptr, size: c.ulong) -> c.long ---
	snd_pcm_recover    :: proc(pcm: snd_pcm_t, err: i32, silent: i32) -> i32 ---
	snd_pcm_drop       :: proc(pcm: snd_pcm_t) -> i32 ---
	snd_pcm_prepare    :: proc(pcm: snd_pcm_t) -> i32 ---
	snd_pcm_close      :: proc(pcm: snd_pcm_t) -> i32 ---
}

alsa_state: struct {
	pcm:    snd_pcm_t,
	paused: bool,
}

BUFFER_FRAMES :: 1024

init :: proc() {
	for i in 0 ..< 10 {
		eq_recalculate_band(i)
	}
	thread.run(audio_thread_proc)
}

audio_thread_proc :: proc() {
	if snd_pcm_open(&alsa_state.pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0 do return
	// 50ms latency, matching WASAPI's Initialize(..., 500000 /* 100ns units */, ...)
	if snd_pcm_set_params(alsa_state.pcm, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED, 2, 48000, 1, 50000) < 0 do return

	buffer: [BUFFER_FRAMES][2]f32

	for {
		if alsa_state.paused {
			time.sleep(10 * time.Millisecond)
			continue
		}

		frames_read: u32
		if sync.guard(&global_mutex) {
			frames_read = read_float(buffer[:])
		}

		if frames_read == 0 {
			time.sleep(5 * time.Millisecond)
			continue
		}

		written := snd_pcm_writei(alsa_state.pcm, raw_data(buffer[:]), c.ulong(frames_read))
		if written < 0 {
			snd_pcm_recover(alsa_state.pcm, i32(written), 1)
		}
	}
}

pause :: proc() {
	alsa_state.paused = true
}

resume :: proc() {
	alsa_state.paused = false
}

reset :: proc() {
	sync.guard(&global_mutex)
	reset_locked()
}

// Called both from reset() above (mutex not yet held) and directly from
// decoder.odin's seek() (mutex already held there) — must not lock itself.
reset_locked :: proc() {
	if alsa_state.pcm != nil {
		snd_pcm_drop(alsa_state.pcm)
		snd_pcm_prepare(alsa_state.pcm)
	}
}
