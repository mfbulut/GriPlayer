package audio

import "core:math"

resampler: struct {
	buffer:      [16384][2]f32,
	len:         int,
	pos:         f64,
	ratio:       f64,
	sample_rate: u32,
	eof:         bool,
}

resampler_reset :: proc(native_rate: u32) {
	resampler.sample_rate = native_rate
	resampler.ratio = f64(native_rate) / 48000.0
	resampler.pos = f64(SINC_RADIUS - 1)
	resampler.len = 0
	resampler.eof = false
}

resample_read :: proc(out_samples: [][2]f32) -> int {
	needed := len(out_samples)
	if needed == 0 do return 0

	produced := 0
	for produced < needed {
		base := int(math.floor(resampler.pos))
		needed_len := base + SINC_RADIUS + 1

		for resampler.len < needed_len && resampler.len < len(resampler.buffer) && !resampler.eof {
			space := len(resampler.buffer) - resampler.len
			chunk_len := min(space, 1024)
			read := int(decode_raw(resampler.buffer[resampler.len:resampler.len + chunk_len]))
			if read == 0 {
				resampler.eof = true
				break
			}
			resampler.len += read
		}

		if resampler.eof && resampler.len < needed_len {
			pad_to := min(needed_len, len(resampler.buffer))
			for resampler.len < pad_to {
				resampler.buffer[resampler.len] = {0, 0}
				resampler.len += 1
			}
		}

		base = int(math.floor(resampler.pos))
		if base + SINC_RADIUS >= resampler.len {
			break
		}

		frac := resampler.pos - f64(base)
		phase := int(frac * f64(SINC_PHASES))
		phase = clamp(phase, 0, SINC_PHASES - 1)

		start_idx := base - SINC_RADIUS + 1
		acc: [2]f32
		for j in 0 ..< SINC_TAPS {
			idx := start_idx + j
			if idx < 0 || idx >= resampler.len do continue
			acc += resampler.buffer[idx] * SINC_TABLE[phase][j]
		}
		out_samples[produced] = acc
		produced += 1
		resampler.pos += resampler.ratio

		discard := int(math.floor(resampler.pos)) - (SINC_RADIUS - 1)
		if discard > len(resampler.buffer) / 2 {
			copy(resampler.buffer[:resampler.len - discard], resampler.buffer[discard:resampler.len])
			resampler.len -= discard
			resampler.pos -= f64(discard)
		}
	}

	return produced
}
