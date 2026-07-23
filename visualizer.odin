package main

import "base:intrinsics"
import "core:math"
import "core:slice"

import "fx"

FFT_SIZE       :: 2048
FFT_BITS       :: 11
SPECTRUM_BANDS :: 64

SPECTRUM_RISE_SPEED :: f32(8)
SPECTRUM_FALL_SPEED :: f32(6)
SPECTRUM_PEAK_FALL  :: f32(1)

fft_work: [FFT_SIZE]complex64
fft_hann: [FFT_SIZE]f32
fft_twiddle: [FFT_SIZE / 2]complex64
audio_ring: [FFT_SIZE]f32
audio_ring_pos: int
spectrum: [SPECTRUM_BANDS]f32
spectrum_peak: [SPECTRUM_BANDS]f32

fft_init :: proc() #no_bounds_check {
	for index in 0 ..< FFT_SIZE {
		fft_hann[index] = 0.5 - 0.5 * math.cos(2 * math.PI * f32(index) / (FFT_SIZE - 1))
	}

	for index in 0 ..< FFT_SIZE / 2 {
		angle := -2 * math.PI * f32(index) / FFT_SIZE
		fft_twiddle[index] = complex(math.cos(angle), math.sin(angle))
	}
}

fft_run :: proc() #no_bounds_check {
	for index in 0 ..< u32(FFT_SIZE) {
		reversed := intrinsics.reverse_bits(index) >> (32 - FFT_BITS)
		if index < reversed {
			fft_work[index], fft_work[reversed] = fft_work[reversed], fft_work[index]
		}
	}

	for length := u32(2); length <= FFT_SIZE; length <<= 1 {
		for start := u32(0); start < FFT_SIZE; start += length {
			for offset in 0 ..< length / 2 {
				left := fft_work[start + offset]
				right := fft_work[start + offset + length / 2] * fft_twiddle[offset * FFT_SIZE / length]
				fft_work[start + offset] = left + right
				fft_work[start + offset + length / 2] = left - right
			}
		}
	}
}

visualizer_push :: proc(frames: [][2]f32) {
	for frame in frames {
		audio_ring[audio_ring_pos] = (frame.x + frame.y) * 0.5
		audio_ring_pos = (audio_ring_pos + 1) % FFT_SIZE
	}
}

visualizer_update :: proc() {
	dt := fx.frame_time()
	if !player.playing {
		for index in 0 ..< SPECTRUM_BANDS {
			spectrum[index] = max(spectrum[index] - SPECTRUM_FALL_SPEED * dt, 0)
			spectrum_peak[index] = max(spectrum_peak[index] - SPECTRUM_PEAK_FALL * dt, 0)
		}
		return
	}

	for index in 0 ..< FFT_SIZE {
		fft_work[index] = audio_ring[(audio_ring_pos + index) % FFT_SIZE] * fft_hann[index]
	}

	fft_run()

	min_bin := 1
	max_bin := FFT_SIZE / 2 - 1
	log_min := math.log(f32(min_bin), 2)
	log_max := math.log(f32(max_bin), 2)
	for &current, band in spectrum {
		t0 := f32(band) / f32(SPECTRUM_BANDS)
		t1 := f32(band + 1) / f32(SPECTRUM_BANDS)
		bin_low := int(math.pow(2, log_min + (log_max - log_min) * t0))
		bin_high := clamp(
			int(math.pow(2, log_min + (log_max - log_min) * t1)),
			bin_low + 1,
			max_bin,
		)

		sum := f32(0)
		for value in fft_work[bin_low:bin_high + 1] {
			sum += math.sqrt(real(value) * real(value) + imag(value) * imag(value))
		}

		magnitude := sum / f32(bin_high - bin_low + 1)
		target := clamp(math.log(1 + magnitude * 8, 2) / 8, 0, 1)
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
	top_space := min(f32(20), bounds.h)
	content := fx.Rect{bounds.x, bounds.y + top_space, bounds.w, bounds.h - top_space}
	if content.h <= 0 do return

	gap := f32(2)
	bar_width := max((content.w - gap * (SPECTRUM_BANDS - 1)) / SPECTRUM_BANDS, 1)
	for level, index in spectrum {
		height := max(content.h * level, 1)
		x := content.x + f32(index) * (bar_width + gap)
		color := COLOR_ACCENT
		if len(visualizer_palette) > 0 {
			color = visualizer_color_at(f32(index) / f32(SPECTRUM_BANDS - 1))
		}

		fx.draw_rect({x, content.y + content.h - height, bar_width, height}, fx.color_opacity(color, 0.7), 1)
		peak_y := content.y + content.h - content.h * spectrum_peak[index]
		fx.draw_rect({x, peak_y, bar_width, 1}, color)
	}
}

Palette_Bucket :: struct {
	sum:   [4]int,
	count: int,
	score: f32,
}

visualizer_palette: [dynamic; 8]fx.Color

PALETTE_NEUTRAL_CHROMA        :: f32(.045)
PALETTE_NEUTRAL_MAX           :: 2
PALETTE_NEUTRAL_LIGHTNESS_GAP :: f32(.25)
PALETTE_SURFACE_DISTANCE      :: f32(.12)
PALETTE_HUE_GAP               :: f32(.42)
PALETTE_LIGHTNESS_GAP         :: f32(.34)
PALETTE_CHROMA_GAP            :: f32(.10)

hue_distance :: proc(a, b: f32) -> f32 {
	difference := abs(a - b)
	return min(difference, 2 * math.PI - difference)
}

oklch_distance :: proc(l1, c1, h1, l2, c2, h2: f32) -> f32 {
	hue_gap := hue_distance(h1, h2)
	return math.sqrt((l1 - l2) * (l1 - l2) + c1 * c1 + c2 * c2 - 2 * c1 * c2 * math.cos(hue_gap))
}

visualizer_palette_accepts :: proc(color: fx.Color) -> bool {
	l, c, h := fx.color_to_oklch(color)
	surface_l, surface_c, surface_h := fx.color_to_oklch(COLOR_SURFACE)
	if oklch_distance(l, c, h, surface_l, surface_c, surface_h) < PALETTE_SURFACE_DISTANCE do return false

	is_neutral := c < PALETTE_NEUTRAL_CHROMA
	neutral_count := 0
	for existing in visualizer_palette {
		existing_l, existing_c, existing_h := fx.color_to_oklch(existing)
		existing_neutral := existing_c < PALETTE_NEUTRAL_CHROMA
		if existing_neutral do neutral_count += 1
		if is_neutral && existing_neutral {
			if neutral_count >= PALETTE_NEUTRAL_MAX || abs(l - existing_l) < PALETTE_NEUTRAL_LIGHTNESS_GAP do return false
		} else if !is_neutral && !existing_neutral {
			same_hue := hue_distance(h, existing_h) < PALETTE_HUE_GAP
			same_tone := abs(l - existing_l) < PALETTE_LIGHTNESS_GAP && abs(c - existing_c) < PALETTE_CHROMA_GAP
			if same_hue && same_tone do return false
		}
	}
	return true
}

visualizer_create_palette :: proc(pixels: []fx.Color) {
	clear(&visualizer_palette)
	if len(pixels) == 0 do return
	buckets: [512]Palette_Bucket
	for color in pixels {
		lightness, chroma, _ := fx.color_to_oklch(color)
		if lightness < 0.25 do continue
		index := (int(color.r) >> 5) << 6 | (int(color.g) >> 5) << 3 | (int(color.b) >> 5)
		bucket := &buckets[index]
		bucket.sum += cast([4]int)color
		bucket.count += 1
		bucket.score += lightness * 0.55 + chroma * 0.8
	}
	slice.sort_by(buckets[:], proc(a, b: Palette_Bucket) -> bool {return a.score > b.score})
	for bucket in buckets {
		if bucket.count == 0 do break
		color := cast(fx.Color)(bucket.sum / bucket.count)
		if visualizer_palette_accepts(color) {
			append(&visualizer_palette, color)
			if len(visualizer_palette) >= cap(visualizer_palette) do break
		}
	}
}

visualizer_color_at :: proc(t: f32) -> fx.Color {
	count := len(visualizer_palette)
	if count == 0 do return COLOR_ACCENT
	scaled := clamp(t, 0, 1) * f32(count - 1)
	index := int(scaled)
	if index >= count - 1 do return visualizer_palette[count - 1]
	return fx.color_lerp(visualizer_palette[index], visualizer_palette[index + 1], scaled - f32(index))
}
