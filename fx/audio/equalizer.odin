package audio

import "core:math"

EQ_BAND_COUNT :: 10

eq_frequencies := [EQ_BAND_COUNT]f32{31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000}

EqBand :: struct {
    freq:    f32,
    gain_db: f32,
    q:       f32,

    // Peaking-EQ biquad coefficients (b0 pre-normalized by a0, etc).
    b0, b1, b2, a1, a2: f32,

    // Filter state, one per channel (Direct Form II Transposed).
    z1, z2: [2]f32,
}

eq_bands: [EQ_BAND_COUNT]EqBand
eq_enabled := false

eq_init :: proc() {
    for i in 0 ..< EQ_BAND_COUNT {
        eq_bands[i].freq = eq_frequencies[i]
        eq_bands[i].gain_db = 0
        eq_bands[i].q = 1.41
    }
    eq_recalculate_all()
}

eq_set_gain :: proc(band: int, gain_db: f32) {
    if band < 0 || band >= EQ_BAND_COUNT do return
    eq_bands[band].gain_db = gain_db
    eq_recalculate_band(band)
}

eq_get_gain :: proc(band: int) -> f32 {
    if band < 0 || band >= EQ_BAND_COUNT do return 0
    return eq_bands[band].gain_db
}

eq_reset :: proc() {
    for i in 0 ..< EQ_BAND_COUNT {
        eq_bands[i].gain_db = 0
        eq_recalculate_band(i)
    }
}

eq_recalculate_all :: proc() {
    for i in 0 ..< EQ_BAND_COUNT {
        eq_recalculate_band(i)
    }
}

eq_recalculate_band :: proc(i: int) {
    band := &eq_bands[i]

    sr := f32(state.sample_rate)
    if sr <= 0 do sr = 48000

    A := math.pow(f32(10), band.gain_db / 40)
    omega := 2 * math.PI * band.freq / sr
    sn := math.sin(omega)
    cs := math.cos(omega)
    alpha := sn / (2 * band.q)

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
    if !eq_enabled do return

    for &sample in samples {
        for ch in 0 ..< 2 {
            x := sample[ch]
            for i in 0 ..< EQ_BAND_COUNT {
                band := &eq_bands[i]
                y := band.b0 * x + band.z1[ch]
                band.z1[ch] = band.b1 * x - band.a1 * y + band.z2[ch]
                band.z2[ch] = band.b2 * x - band.a2 * y
                x = y
            }
            sample[ch] = x
        }
    }
}
