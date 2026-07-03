package main

import "base:intrinsics"
import "core:math"

import "fx"

FFT_SIZE :: 2048
FFT_BITS :: 11
SPECTRUM_BANDS :: 64

work_buffer: [FFT_SIZE]complex64
hann_table: [FFT_SIZE]f32
twiddle_table: [FFT_SIZE / 2]complex64

fft_init :: proc() #no_bounds_check {
    for i in 0..<FFT_SIZE {
        hann_table[i] = 0.5 - 0.5 * math.cos(2.0 * math.PI * f32(i) / (FFT_SIZE - 1))
    }
    for i in 0..<FFT_SIZE/2 {
        angle := -2.0 * math.PI * f32(i) / FFT_SIZE
        twiddle_table[i] = complex(math.cos(angle), math.sin(angle))
    }
}

fft :: proc() #no_bounds_check {
    for i in 0..<u32(FFT_SIZE) {
        j := intrinsics.reverse_bits(i) >> (32 - FFT_BITS)
        if i < j {
            work_buffer[i], work_buffer[j] = work_buffer[j], work_buffer[i]
        }
    }

    for length := u32(2); length <= FFT_SIZE; length <<= 1 {
        for i := u32(0); i < FFT_SIZE; i += length {
            for k in 0..<length/2 {
                w := twiddle_table[k * FFT_SIZE / length]
                u := work_buffer[i + k]
                v := work_buffer[i + k + length / 2] * w
                work_buffer[i + k] = u + v
                work_buffer[i + k + length / 2] = u - v
            }
        }
    }
}

ring_buffer : struct {
	data: [FFT_SIZE]f32,
	pos : int,
}

spectrum: [SPECTRUM_BANDS]f32
spectrum_peak: [SPECTRUM_BANDS]f32

SPECTRUM_RISE_SPEED :: f32(8.0)
SPECTRUM_FALL_SPEED :: f32(6.0)
SPECTRUM_PEAK_FALL  :: f32(1.0)
SPECTRUM_BAR_GAP    :: f32(3)

visualizer_push :: proc(frames: [][2]f32) {
	for f in frames {
		ring_buffer.data[ring_buffer.pos] = (f.x + f.y) * 0.5
		ring_buffer.pos = (ring_buffer.pos + 1) % FFT_SIZE
	}
}

visualizer_update :: proc() {
	dt := fx.frame_time()
	if !player.playing {
		for i in 0..<SPECTRUM_BANDS {
			spectrum[i] = max(spectrum[i] - SPECTRUM_FALL_SPEED * dt, 0)
			spectrum_peak[i] = max(spectrum_peak[i] - SPECTRUM_PEAK_FALL * dt, 0)
		}
		return
	}

	for i in 0..<FFT_SIZE {
		work_buffer[i] = ring_buffer.data[(ring_buffer.pos + i) % FFT_SIZE] * hann_table[i]
	}

	fft()

	min_bin := 1
	max_bin := FFT_SIZE / 2 - 1
	log_min := math.log(f32(min_bin), 2.0)
	log_max := math.log(f32(max_bin), 2.0)

	for &current, band in spectrum {
		t0 := f32(band) / f32(SPECTRUM_BANDS)
		t1 := f32(band+1) / f32(SPECTRUM_BANDS)

		bin_low := int(math.pow(2.0, log_min + (log_max - log_min) * t0))
		bin_high := clamp(int(math.pow(2.0, log_min + (log_max - log_min) * t1)), bin_low + 1, max_bin)

		sum := f32(0)
		for c in work_buffer[bin_low:bin_high+1] {
			sum += math.sqrt(real(c) * real(c) + imag(c) * imag(c))
		}

		mag := sum / f32(bin_high - bin_low + 1)
		target := clamp(math.log(1.0 + mag * 8.0, 2.0) / 8.0, 0, 1)

		if target > current {
			current = min(current + dt * SPECTRUM_RISE_SPEED, target)
		} else {
			current = max(current - dt * SPECTRUM_FALL_SPEED, target)
		}

		if current > spectrum_peak[band] {
			spectrum_peak[band] = current
		} else {
			spectrum_peak[band] = max(spectrum_peak[band] - SPECTRUM_PEAK_FALL * dt, current)
		}
	}
}

ui_visualizer :: proc() {
	bounds := layout_next()

	bar_w := max((bounds.w - SPECTRUM_BAR_GAP * f32(SPECTRUM_BANDS - 1)) / f32(SPECTRUM_BANDS), 1)

	for level, i in spectrum {
		bar_h := max(bounds.h * level, 2)
		x := bounds.x + f32(i) * (bar_w + SPECTRUM_BAR_GAP)
		y := bounds.y + bounds.h - bar_h
		fx.rect({x, y, bar_w, bar_h}, [4]fx.Color{ACCENT_BRIGHT, ACCENT_BRIGHT, ACCENT_DARK, ACCENT_DARK})
		peak_y := bounds.y + bounds.h - bounds.h * spectrum_peak[i]
		fx.rect({x, peak_y - 2, bar_w, 2}, TEXT_SECONDARY, 1)
	}
}
