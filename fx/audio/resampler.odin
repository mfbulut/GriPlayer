package audio

import "core:math"

TABLE_PHASES :: 32
TAPS         :: 16

resampler_state: struct {
	buffer:        [65536][2]f32,
	buf_count:     int,
	pos_in:        f64,
	sample_rate:   u32,
	table:         [33][16]f32,
	eof:           bool,
	seek_pcm:      i64,
	total_shifted: i64,
}

bessel_i0 :: proc(x: f64) -> f64 {
	sum := 1.0
	term := 1.0
	x_half := x / 2.0
	for k := 1; k <= 25; k += 1 {
		term *= (x_half / f64(k))
		sum += term * term
		if term * term < 1e-12 * sum do break
	}
	return sum
}

kaiser_window :: proc(t: f64, half_taps: f64, beta: f64) -> f64 {
	ratio := t / half_taps
	if math.abs(ratio) >= 1.0 do return 0.0
	arg := beta * math.sqrt(1.0 - ratio * ratio)
	return bessel_i0(arg) / bessel_i0(beta)
}

sinc :: proc(x: f64) -> f64 {
	if math.abs(x) < 1e-9 do return 1.0
	pix := math.PI * x
	return math.sin(pix) / pix
}

rebuild_polyphase_table :: proc() {
	if resampler_state.sample_rate == 0 do return

	f_in := f64(resampler_state.sample_rate)
	f_out := 48000.0
	ratio := f_in / f_out
	c := math.min(1.0, 1.0 / ratio)

	cutoff := 0.45 * c
	beta := 8.5
	half_taps := 8.0

	for p in 0 ..= TABLE_PHASES {
		eta := f64(p) / f64(TABLE_PHASES)
		sum: f64 = 0.0

		for k in 0 ..< TAPS {
			t := (f64(k) - 7.5) - eta
			val := c * sinc(2.0 * cutoff * t) * kaiser_window(t * c, half_taps, beta)
			resampler_state.table[p][k] = f32(val)
			sum += val
		}

		if sum != 0.0 {
			inv_sum := f32(1.0 / sum)
			for k in 0 ..< TAPS {
				resampler_state.table[p][k] *= inv_sum
			}
		}
	}
}

resampler_reset :: proc(start_pcm: i64 = 0) {
	for i in 0 ..< len(resampler_state.buffer) {
		resampler_state.buffer[i] = {0, 0}
	}
	resampler_state.buf_count = 7
	resampler_state.pos_in = 7.0
	resampler_state.sample_rate = decoder.sample_rate
	resampler_state.eof = false
	resampler_state.seek_pcm = start_pcm
	resampler_state.total_shifted = 0
	rebuild_polyphase_table()
}

resampler_position :: proc() -> f32 {
	if decoder.sample_rate == 0 do return 0
	current_pcm := f64(resampler_state.seek_pcm + resampler_state.total_shifted) + (resampler_state.pos_in - 7.0)
	if decoder.total_pcm > 0 {
		current_pcm = math.min(current_pcm, f64(decoder.total_pcm))
	}
	return f32(current_pcm / f64(decoder.sample_rate))
}

resampler_read :: proc(out_samples: [][2]f32) -> int {
	if decoder.sample_rate == 48000 {
		return decode_raw(out_samples)
	}

	if decoder.sample_rate == 0 do return 0

	if resampler_state.sample_rate != decoder.sample_rate {
		resampler_state.sample_rate = decoder.sample_rate
		rebuild_polyphase_table()
	}

	ratio := f64(decoder.sample_rate) / 48000.0
	out_needed := len(out_samples)
	if out_needed == 0 do return 0

	frames_out := 0

	for frames_out < out_needed {
		int_pos := int(resampler_state.pos_in)

		if int_pos > 7 {
			shift := int_pos - 7
			copy(resampler_state.buffer[:resampler_state.buf_count - shift], resampler_state.buffer[shift:resampler_state.buf_count])
			resampler_state.buf_count -= shift
			resampler_state.pos_in -= f64(shift)
			resampler_state.total_shifted += i64(shift)
			int_pos = 7
		}

		needed_input_end := int_pos + 9
		if resampler_state.buf_count < needed_input_end {
			if !resampler_state.eof {
				space_available := len(resampler_state.buffer) - resampler_state.buf_count
				if space_available > 0 {
					read_count := decode_raw(resampler_state.buffer[resampler_state.buf_count:])
					if read_count > 0 {
						resampler_state.buf_count += read_count
					} else {
						resampler_state.eof = true
						pad_end := math.min(resampler_state.buf_count + TAPS, len(resampler_state.buffer))
						for i := resampler_state.buf_count; i < pad_end; i += 1 {
							resampler_state.buffer[i] = {0, 0}
						}
						resampler_state.buf_count = pad_end
					}
				}
			}
		}

		if int_pos + 8 >= resampler_state.buf_count {
			break
		}

		frac := resampler_state.pos_in - f64(int_pos)
		p_exact := frac * f64(TABLE_PHASES)
		p0 := int(p_exact)
		p1 := p0 + 1
		alpha := f32(p_exact - f64(p0))

		sample: [2]f32 = {0, 0}
		base_idx := int_pos - 7

		for k in 0 ..< TAPS {
			c0 := resampler_state.table[p0][k]
			c1 := resampler_state.table[p1][k]
			coeff := c0 * (1.0 - alpha) + c1 * alpha

			in_s := resampler_state.buffer[base_idx + k]
			sample[0] += coeff * in_s[0]
			sample[1] += coeff * in_s[1]
		}

		out_samples[frames_out] = sample
		frames_out += 1
		resampler_state.pos_in += ratio
	}

	return frames_out
}