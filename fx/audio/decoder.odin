package audio

import "core:math"
import "core:os"
import "core:strings"
import "core:sync"

import "flac"
import "opusfile"
import "vendor:stb/vorbis"

Decoder_Union :: union {
	^opusfile.File,
	^vorbis.vorbis,
	^flac.File,
}

EqBand :: struct {
	gain_db:    f32,
	b0, b1, b2: f32,
	a1, a2:     f32,
	z1, z2:     [2]f32,
}

decoder: struct {
	decoder:       Decoder_Union,
	total_pcm:     i64,
	sample_rate:   u32,
	volume:        f32,
	song_finished: bool,
	callback:      proc(samples: [][2]f32),
	eq_bands:      [10]EqBand,
	pregain_db:    f32,
}

global_mutex: sync.Mutex

open :: proc(path: string) -> bool {
	sync.guard(&global_mutex)

	switch d in decoder.decoder {
	case ^opusfile.File:
		opusfile.free(d)
	case ^vorbis.vorbis:
		vorbis.close(d)
	case ^flac.File:
		flac.destroy(d)
	case:
	}

	decoder.decoder = nil

	ext := strings.to_lower(os.ext(path), context.temp_allocator)
	switch ext {
	case ".opus":
		if of := opusfile.open_file(path); of != nil {
			opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
			decoder.decoder = of
			decoder.sample_rate = 48000
			decoder.total_pcm = opusfile.pcm_total(of, -1)
		}
	case ".ogg":
		if vf := open_vorbis_file(path); vf != nil {
			decoder.decoder = vf
			info := vorbis.get_info(vf)
			decoder.sample_rate = info.sample_rate
			decoder.total_pcm = i64(vorbis.stream_length_in_samples(vf))
		} else if of := opusfile.open_file(path); of != nil {
			opusfile.set_gain_offset(of, opusfile.TRACK_GAIN, 0)
			decoder.decoder = of
			decoder.sample_rate = 48000
			decoder.total_pcm = opusfile.pcm_total(of, -1)
		}
	case ".flac":
		if ff := flac.open_file(path); ff != nil {
			decoder.decoder = ff
			decoder.sample_rate = u32(ff.info.sample_rate)
			decoder.total_pcm = i64(flac.pcm_total(ff))
		}
	}

	if decoder.decoder == nil do return false
	decoder.song_finished = false
	resampler_reset(decoder.sample_rate)
	return true
}

decode_raw :: proc(samples: [][2]f32) -> u32 {
	if decoder.decoder == nil do return 0

	frames_needed := len(samples)
	if frames_needed == 0 do return 0

	frames_read := 0
	for frames_read < frames_needed {
		remaining := frames_needed - frames_read
		read := 0

		switch d in decoder.decoder {
		case ^opusfile.File:
			read = cast(int)opusfile.read_float_stereo(d, cast([^]f32)raw_data(samples[frames_read:]), i32(remaining))
		case ^vorbis.vorbis:
			read = cast(int)vorbis.get_samples_float_interleaved(d, 2, cast([^]f32)raw_data(samples[frames_read:]), i32(remaining))
		case ^flac.File:
			read = flac.read_float_stereo(d, samples[frames_read:frames_needed])
		}

		if read == 0 do break;
		frames_read += read
	}

	return u32(frames_read)
}

read_float :: proc(samples: [][2]f32) -> u32 {
	if decoder.decoder == nil do return 0

	frames_needed := len(samples)
	if frames_needed == 0 do return 0

	frames_read := 0
	if decoder.sample_rate == 48000 {
		frames_read = int(decode_raw(samples))
	} else {
		frames_read = resample_read(samples)
	}

	out_samples := samples[:frames_read]

	preamp_gain := math.pow(10, decoder.pregain_db / 20.0)

	for &sample in out_samples {
		for &x, i in sample {
			for &band in decoder.eq_bands {
				y := band.b0 * x + band.z1[i]
				band.z1[i] = band.b1 * x - band.a1 * y + band.z2[i]
				band.z2[i] = band.b2 * x - band.a2 * y
				x = y
			}
		}
	}

	for &sample in out_samples {
		sample *= preamp_gain
	}

	if decoder.callback != nil {
		decoder.callback(out_samples)
	}

	current_vol := decoder.volume * decoder.volume
	for &sample in out_samples {
		sample *= current_vol
	}

	if frames_read == 0 {
		decoder.song_finished = true
	}

	return u32(frames_read)
}

seek :: proc(position: f32) {
	sync.guard(&global_mutex)

	if decoder.decoder == nil do return
	target_pcm := i64(position * f32(decoder.sample_rate))
	target_pcm = clamp(target_pcm, 0, decoder.total_pcm - 1)

	switch d in decoder.decoder {
	case ^opusfile.File:
		opusfile.pcm_seek(d, target_pcm)
	case ^vorbis.vorbis:
		vorbis.seek(d, u32(target_pcm))
	case ^flac.File:
		flac.pcm_seek(d, u64(target_pcm))
	case:
	}

	resampler_reset(decoder.sample_rate)
	wasapi_reset()
}

position :: proc() -> f32 {
	sync.guard(&global_mutex)

	current_pcm: i64
	switch d in decoder.decoder {
	case ^opusfile.File:
		current_pcm = opusfile.pcm_tell(d)
	case ^vorbis.vorbis:
		current_pcm = i64(vorbis.get_sample_offset(d))
	case ^flac.File:
		current_pcm = i64(flac.pcm_tell(d))
	case:
		return 0
	}
	return f32(current_pcm) / f32(decoder.sample_rate)
}

duration :: proc() -> f32 {
	sync.guard(&global_mutex)
	if decoder.decoder == nil do return 0
	return f32(decoder.total_pcm) / f32(decoder.sample_rate)
}

get_volume :: proc() -> f32 {
	sync.guard(&global_mutex)
	return decoder.volume
}

set_volume :: proc(vol: f32) {
	sync.guard(&global_mutex)
	decoder.volume = clamp(vol, 0, 1)
}

is_finished :: proc() -> bool {
	sync.guard(&global_mutex)
	return decoder.song_finished
}

set_callback :: proc(cb: proc(samples: [][2]f32)) {
	sync.guard(&global_mutex)
	decoder.callback = cb
}

eq_set_gain :: proc(band: int, gain_db: f32) {
	sync.guard(&global_mutex)
	decoder.eq_bands[band].gain_db = gain_db
	eq_recalculate_band(band)
}

eq_get_gain :: proc(band: int) -> f32 {
	sync.guard(&global_mutex)
	return decoder.eq_bands[band].gain_db
}

eq_reset_state :: proc() {
	sync.guard(&global_mutex)
	for &band in decoder.eq_bands {
		band.z1 = 0
		band.z2 = 0
	}
}

eq_reset :: proc() {
	sync.guard(&global_mutex)
	decoder.pregain_db = 0
	for i in 0 ..< 10 {
		decoder.eq_bands[i].gain_db = 0
		eq_recalculate_band(i)
	}
}

eq_recalculate_band :: proc(i: int) {
	band := &decoder.eq_bands[i]

	A := math.pow(10, band.gain_db / 40)
	frequencies := [10]f32{31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000}
	sample_rate := f32(48000)
	omega := 2 * math.PI * frequencies[i] / sample_rate
	sn := math.sin(omega)
	cs := math.cos(omega)
	alpha := sn / (2 * 1.41)

	b0 := 1 + alpha * A
	b1 := -2 * cs
	b2 := 1 - alpha * A
	a0 := 1 + alpha / A
	a1 := -2 * cs
	a2 := 1 - alpha / A

	band.b0 = b0 / a0
	band.b1 = b1 / a0
	band.b2 = b2 / a0
	band.a1 = a1 / a0
	band.a2 = a2 / a0
}
