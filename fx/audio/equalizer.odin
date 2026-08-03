package audio

import "core:math"

EqBand :: struct {
    gain_db:    f32,
    b0, b1, b2: f32,
    a1, a2:     f32,
    z1, z2:     [2]f32,
}

eq_bands: [10]EqBand
pregain_db := f32(0.0)

eq_set_gain :: proc(band: int, gain_db: f32) {
    eq_bands[band].gain_db = gain_db
    eq_recalculate_band(band)
}

eq_get_gain :: proc(band: int) -> f32 {
    return eq_bands[band].gain_db
}

eq_reset_state :: proc() {
    for &band in eq_bands {
        band.z1 = 0
        band.z2 = 0
    }
}

eq_reset :: proc() {
    pregain_db = 0
    for i in 0 ..< 10 {
        eq_bands[i].gain_db = 0
        eq_recalculate_band(i)
    }
}

eq_recalculate_all :: proc() {
    for i in 0 ..< 10 {
        eq_recalculate_band(i)
    }
}

eq_recalculate_band :: proc(i: int) {
    band := &eq_bands[i]

    A := math.pow(10, band.gain_db / 40)
    frequencies := [10]f32{31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000}
    omega := 2 * math.PI * frequencies[i] / f32(state.sample_rate)
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

eq_process :: proc(samples: [][2]f32) {
    preamp_gain := math.pow(10, pregain_db / 20.0)

    for &sample in samples {
        sample *= preamp_gain
    }

    for &sample in samples {
        for &x, i in sample {
            for &band in eq_bands {
                y := band.b0 * x + band.z1[i]
                band.z1[i] = band.b1 * x - band.a1 * y + band.z2[i]
                band.z2[i] = band.b2 * x - band.a2 * y
                x = y
            }
        }
    }
}

