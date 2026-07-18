package main

import "base:intrinsics"

import "core:math"
import "core:slice"

import "fx"

FFT_SIZE :: 2048
FFT_BITS :: 11
SPECTRUM_BANDS :: 64

work_buffer: [FFT_SIZE]complex64
hann_table: [FFT_SIZE]f32
twiddle_table: [FFT_SIZE / 2]complex64

fft_init :: proc() #no_bounds_check {
	for i in 0 ..< FFT_SIZE {
		hann_table[i] = 0.5 - 0.5 * math.cos(2.0 * math.PI * f32(i) / (FFT_SIZE - 1))
	}
	for i in 0 ..< FFT_SIZE / 2 {
		angle := -2.0 * math.PI * f32(i) / FFT_SIZE
		twiddle_table[i] = complex(math.cos(angle), math.sin(angle))
	}
}

fft :: proc() #no_bounds_check {
	for i in 0 ..< u32(FFT_SIZE) {
		j := intrinsics.reverse_bits(i) >> (32 - FFT_BITS)
		if i < j {
			work_buffer[i], work_buffer[j] = work_buffer[j], work_buffer[i]
		}
	}

	for length := u32(2); length <= FFT_SIZE; length <<= 1 {
		for i := u32(0); i < FFT_SIZE; i += length {
			for k in 0 ..< length / 2 {
				w := twiddle_table[k * FFT_SIZE / length]
				u := work_buffer[i + k]
				v := work_buffer[i + k + length / 2] * w
				work_buffer[i + k] = u + v
				work_buffer[i + k + length / 2] = u - v
			}
		}
	}
}

ring_buffer: struct {
	data: [FFT_SIZE]f32,
	pos:  int,
}

spectrum: [SPECTRUM_BANDS]f32
spectrum_peak: [SPECTRUM_BANDS]f32

SPECTRUM_RISE_SPEED :: f32(8.0)
SPECTRUM_FALL_SPEED :: f32(6.0)
SPECTRUM_PEAK_FALL :: f32(1.0)

visualizer_push :: proc(frames: [][2]f32) {
	for f in frames {
		ring_buffer.data[ring_buffer.pos] = (f.x + f.y) * 0.5
		ring_buffer.pos = (ring_buffer.pos + 1) % FFT_SIZE
	}
}

visualizer_update :: proc() {
	dt := fx.frame_time()
	if !player.playing {
		for i in 0 ..< SPECTRUM_BANDS {
			spectrum[i] = max(spectrum[i] - SPECTRUM_FALL_SPEED * dt, 0)
			spectrum_peak[i] = max(spectrum_peak[i] - SPECTRUM_PEAK_FALL * dt, 0)
		}
		return
	}

	for i in 0 ..< FFT_SIZE {
		work_buffer[i] = ring_buffer.data[(ring_buffer.pos + i) % FFT_SIZE] * hann_table[i]
	}

	fft()

	min_bin := 1
	max_bin := FFT_SIZE / 2 - 1
	log_min := math.log(f32(min_bin), 2.0)
	log_max := math.log(f32(max_bin), 2.0)

	for &current, band in spectrum {
		t0 := f32(band) / f32(SPECTRUM_BANDS)
		t1 := f32(band + 1) / f32(SPECTRUM_BANDS)

		bin_low := int(math.pow(2.0, log_min + (log_max - log_min) * t0))
		bin_high := clamp(
			int(math.pow(2.0, log_min + (log_max - log_min) * t1)),
			bin_low + 1,
			max_bin,
		)

		sum := f32(0)
		for c in work_buffer[bin_low:bin_high + 1] {
			sum += math.sqrt(real(c) * real(c) + imag(c) * imag(c))
		}

		mag := sum / f32(bin_high - bin_low + 1)
		target := clamp(math.log(1.0 + mag * 8.0, 2.0) / 8.0, 0, 1)

		if target > current {
			current = min(current + dt * SPECTRUM_RISE_SPEED, target)
		} else {
			current = max(current - dt * SPECTRUM_FALL_SPEED, target)
		}

		spectrum_peak[band] = max(spectrum_peak[band] - SPECTRUM_PEAK_FALL * dt, current)
	}
}

draw_visualizer :: proc(bounds: fx.Rect) {
	if bounds.w <= 0 || bounds.h <= 0 do return
	bar_width := max((bounds.w - 2 * f32(SPECTRUM_BANDS - 1)) / f32(SPECTRUM_BANDS), 1)
	for level, index in spectrum {
		bar_height := max(bounds.h * level, 2)
		x := bounds.x + f32(index) * (bar_width + 2)
		y := bounds.y + bounds.h - bar_height
		peak_y := bounds.y + bounds.h - bounds.h * spectrum_peak[index]

		color := COLOR_ACCENT
		if len(visualizer_palette) > 0 {
			color = visualizer_color_at(f32(index) / f32(SPECTRUM_BANDS - 1))
		}
		top := fx.color_lerp(color, fx.WHITE, .08)
		bottom := fx.color_brightness(color, .42)
		fx.draw_rect({x, y, bar_width, bar_height}, {top, top, bottom, bottom})
		fx.draw_rect({x, peak_y - 2, bar_width, 2}, fx.color_opacity(color, .62), 1)
	}
}

Palette_Bucket :: struct {
	sum:   [4]int,
	count: int,
	score: f32,
}

visualizer_palette: [dynamic; 8]fx.Color

PALETTE_NEUTRAL_CHROMA :: f32(0.045)
PALETTE_NEUTRAL_MAX :: 2
PALETTE_NEUTRAL_LIGHTNESS_GAP :: f32(0.25)
PALETTE_SURFACE_DISTANCE :: f32(0.12)

PALETTE_HUE_GAP :: f32(0.42)
PALETTE_LIGHTNESS_GAP :: f32(0.34)
PALETTE_CHROMA_GAP :: f32(0.10)

hue_distance :: proc(a, b: f32) -> f32 {
	diff := abs(a - b)
	return min(diff, 2.0 * math.PI - diff)
}

oklch_distance :: proc(l1, c1, h1, l2, c2, h2: f32) -> f32 {
	hue_gap := hue_distance(h1, h2)
	return math.sqrt(
		(l1 - l2) * (l1 - l2) +
		c1 * c1 + c2 * c2 - 2 * c1 * c2 * math.cos(hue_gap),
	)
}

visualizer_palette_accepts :: proc(color: fx.Color) -> bool {
	l, c, h := fx.color_to_oklch(color)
	s_l, s_c, s_h := fx.color_to_oklch(COLOR_SURFACE)

	if oklch_distance(l, c, h, s_l, s_c, s_h) < PALETTE_SURFACE_DISTANCE {
		return false
	}

	is_neutral := c < PALETTE_NEUTRAL_CHROMA
	neutral_count := 0

	for existing in visualizer_palette {
		existing_l, existing_c, existing_h := fx.color_to_oklch(existing)
		existing_is_neutral := existing_c < PALETTE_NEUTRAL_CHROMA

		if existing_is_neutral {
			neutral_count += 1
		}

		if is_neutral && existing_is_neutral {
			if neutral_count >= PALETTE_NEUTRAL_MAX ||
			   abs(l - existing_l) < PALETTE_NEUTRAL_LIGHTNESS_GAP {
				return false
			}
		} else if !is_neutral && !existing_is_neutral {
			same_hue := hue_distance(h, existing_h) < PALETTE_HUE_GAP
			same_tone :=
				abs(l - existing_l) < PALETTE_LIGHTNESS_GAP &&
				abs(c - existing_c) < PALETTE_CHROMA_GAP
			if same_hue && same_tone {
				return false
			}
		}
	}

	return true
}

visualizer_create_palette :: proc(pixels: []fx.Color) {
	clear(&visualizer_palette)
	if len(pixels) == 0 do return

	buckets: [512]Palette_Bucket

	for color in pixels {
		l, c, _ := fx.color_to_oklch(color)
		if l < 0.25 {
			continue
		}

		idx := (int(color.r) >> 5) << 6 | (int(color.g) >> 5) << 3 | (int(color.b) >> 5)
		bucket := &buckets[idx]
		bucket.sum += cast([4]int)color
		bucket.count += 1
		bucket.score += l * 0.55 + c * 0.8
	}

	slice.sort_by(buckets[:], proc(a, b: Palette_Bucket) -> bool {
		return a.score > b.score
	})

	for bucket in buckets {
		if bucket.count == 0 do break
		color := cast(fx.Color)(bucket.sum / bucket.count)
		if visualizer_palette_accepts(color) {
			append(&visualizer_palette, color)
			if len(visualizer_palette) >= cap(visualizer_palette) {
				break
			}
		}
	}
}

visualizer_color_at :: proc(t: f32) -> fx.Color {
	count := len(visualizer_palette)
	scaled := clamp(t, 0, 1) * f32(count - 1)

	idx := int(scaled)
	if idx >= count - 1 {
		return visualizer_palette[count - 1]
	}

	return fx.color_lerp(visualizer_palette[idx], visualizer_palette[idx + 1], scaled - f32(idx))
}
