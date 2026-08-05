package flac

import "base:intrinsics"
import "core:os"

File :: struct {
    data: []u8,
    pos: u64,
    bit_buf: u64,
    bit_count: u64,

    info: Info,
    tags: Tags,
    cover: []u8,
    audio_start: u64,
    cur_sample: u64,

    buf_pos: u64,
    buf_len: u64,
    pcm_buf: [][]i32,
}

Info :: struct {
    min_block_size: u64,
    max_block_size: u64,
    min_frame_size: u64,
    max_frame_size: u64,
    sample_rate:    u64,
    channels:       u64,
    bit_depth:      u64,
    sample_count:   u64,
}

Tags :: struct {
    vendor:   string,
    comments: []string,
}

Seek_Point :: struct {
    sample_number: u64,
    stream_offset: u64,
    frame_samples: u64,
}

Frame_Header :: struct {
    blocking_strategy:   u64,
    block_size:          u64,
    sample_rate:         u64,
    bits_per_sample:     u64,
    channel_count:       u64,
    channel:             Channel,
    sample_or_frame_num: u64,
}

Subframe_Type :: enum {
    Constant,
    Verbatim,
    Fixed,
    LPC,
}

Channel :: enum {
    Independent_Mono   = 0,
    Independent_Stereo = 1,
    Independent_3C     = 2,
    Independent_4C     = 3,
    Independent_5C     = 4,
    Independent_6C     = 5,
    Independent_7C     = 6,
    Independent_8C     = 7,
    Left_Side_Stereo   = 8,
    Right_Side_Stereo  = 9,
    Mid_Side_Stereo    = 10,
}

open_file :: proc(path: string) -> ^File {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil do return nil

    f := new(File)
    f.data = data

    magic, ok := read_bits(f, 32)
    if !ok || magic != 0x664C6143 {
        free(f)
        delete(data)
        return nil
    }

    if !parse(f) {
        free(f)
        delete(data)
        return nil
    }

    f.audio_start = f.pos

    return f
}

destroy :: proc(file: ^File) {
    if file == nil do return
    for buf in file.pcm_buf {
        delete(buf)
    }
    delete(file.pcm_buf)
    delete(file.data)
    delete(file.tags.comments)
    free(file)
}

parse :: proc(f: ^File) -> bool {
    for {
        is_last := read_bits(f, 1) or_return
        type := read_bits(f, 7) or_return
        len := read_bits(f, 24) or_return
        end_pos := f.pos + len

        switch type {
        case 0: parse_stream_info(f) or_return
        case 4: parse_vorbis_comment(f) or_return
        case 6: parse_picture(f) or_return
        }

        f.pos = end_pos
        if is_last != 0 do break
    }

    return true
}

parse_stream_info :: proc(f: ^File) -> bool {
    f.info.min_block_size = read_bits(f, 16) or_return
    f.info.max_block_size = read_bits(f, 16) or_return
    f.info.min_frame_size = read_bits(f, 24) or_return
    f.info.max_frame_size = read_bits(f, 24) or_return
    f.info.sample_rate = read_bits(f, 20) or_return
    f.info.channels = (read_bits(f, 3) or_return) + 1
    f.info.bit_depth = (read_bits(f, 5) or_return) + 1
    f.info.sample_count = read_bits(f, 36) or_return
    read_bytes(f, 16) or_return

    channels := f.info.channels > 0 ? f.info.channels : 8
    buf_size := f.info.max_block_size > 0 ? f.info.max_block_size : 65535

    f.pcm_buf = make([][]i32, channels)
    for i in 0 ..< channels {
        f.pcm_buf[i] = make([]i32, buf_size)
    }

    return true
}

parse_picture :: proc(f: ^File) -> bool {
    pic_type := read_bits(f, 32) or_return
    mime_len := read_bits(f, 32) or_return
    read_bytes(f, mime_len) or_return
    desc_len := read_bits(f, 32) or_return
    read_bytes(f, desc_len) or_return
    read_bytes(f, 16)

    data_len := read_bits(f, 32) or_return
    cover_data := read_bytes(f, data_len) or_return

    if pic_type == 3 || len(f.cover) == 0 {
        f.cover = cover_data
    }

    return true
}

parse_vorbis_comment :: proc(f: ^File) -> bool {
    vendor_len := read_u32le(f) or_return
    f.tags.vendor = string(read_bytes(f, vendor_len) or_return)

    count := read_u32le(f) or_return
    f.tags.comments = make([]string, count)

    for i in 0 ..< count {
        len := read_u32le(f) or_return
        f.tags.comments[i] = string(read_bytes(f, len) or_return)
    }

    return true
}

frame_header :: proc(f: ^File) -> (fh: Frame_Header, ok: bool) {
    align_to_byte(f)
    header_start := f.pos

    fh.bits_per_sample = f.info.bit_depth
    fh.sample_rate = f.info.sample_rate

    sync := read_bits(f, 14) or_return
    if sync != 0x3FFE do return
    if (read_bits(f, 1) or_return) != 0 do return
    fh.blocking_strategy = read_bits(f, 1) or_return

    block_size_enum := read_bits(f, 4) or_return
    sample_rate_enum := read_bits(f, 4) or_return
    channel_enum := read_bits(f, 4) or_return
    bit_depth_enum := read_bits(f, 3) or_return
    if (read_bits(f, 1) or_return) != 0 do return

    bs := BLOCK_SIZES[block_size_enum]
    if bs < 0 do return
    if bs > 0 do fh.block_size = u64(bs)

    sr := SAMPLE_RATES[sample_rate_enum]
    if sr < 0 do return
    if sr > 0 do fh.sample_rate = u64(sr)

    ss := SAMPLE_SIZES[bit_depth_enum]
    if ss < 0 do return
    if ss > 0 do fh.bits_per_sample = u64(ss)

    if channel_enum > 10 do return
    fh.channel = Channel(channel_enum)
    fh.channel_count = channel_enum >= 8 ? 2 : channel_enum + 1

    sync_val := read_utf8_uint(f) or_return
    fh.sample_or_frame_num = sync_val

    switch block_size_enum {
    case 6:
        v := read_bits(f, 8) or_return
        fh.block_size = u64(v) + 1
    case 7:
        v := read_bits(f, 16) or_return
        fh.block_size = u64(v) + 1
    }

    switch sample_rate_enum {
    case 12:
        v := read_bits(f, 8) or_return
        fh.sample_rate = u64(v) * 1000
    case 13:
        v := read_bits(f, 16) or_return
        fh.sample_rate = u64(v)
    case 14:
        v := read_bits(f, 16) or_return
        fh.sample_rate = u64(v) * 10
    }

    crc8 := read_bits(f, 8) or_return

    if f.pos > header_start {
        calc_crc := flac_crc8(f.data[header_start : f.pos - 1])
        if u8(crc8) != calc_crc do return
    }

    return fh, true
}

decode_next_frame :: proc(f: ^File) -> bool {
    frame_start := f.pos
    fh := frame_header(f) or_return

    block_size := fh.block_size
    if block_size > u64(len(f.pcm_buf[0])) do return false

    for chan_idx in 0 ..< fh.channel_count {
        if chan_idx >= u64(len(f.pcm_buf)) do return false
        if (read_bits(f, 1) or_return) != 0 do return false

        sf_type_bits := read_bits(f, 6) or_return
        wasted_flag := read_bits(f, 1) or_return

        wasted_bits: u64 = 0
        if wasted_flag == 1 {
            wasted_bits = (read_unary(f) or_return) + 1
        }

        if wasted_bits >= fh.bits_per_sample do return false
        bps := fh.bits_per_sample - wasted_bits

        if (fh.channel == .Left_Side_Stereo && chan_idx == 1) ||
           (fh.channel == .Right_Side_Stereo && chan_idx == 0) ||
           (fh.channel == .Mid_Side_Stereo && chan_idx == 1) {
            bps += 1
        }

        sf_type: Subframe_Type
        order: u64 = 0

        if (sf_type_bits & 0x20) != 0 {
            sf_type = .LPC
            order = (sf_type_bits & 0x1F) + 1
        } else if (sf_type_bits & 0x08) != 0 {
            sf_type = .Fixed
            order = sf_type_bits & 0x07
            if order > 4 do return false
        } else if (sf_type_bits & 0x01) != 0 {
            sf_type = .Verbatim
        } else if sf_type_bits == 0 {
            sf_type = .Constant
        } else {
            return false
        }

        switch sf_type {
        case .Constant:
            s := sign_extend(read_bits(f, bps) or_return, bps)
            for i in 0 ..< block_size {
                f.pcm_buf[chan_idx][i] = s
            }
        case .Verbatim:
            for i in 0 ..< block_size {
                f.pcm_buf[chan_idx][i] = sign_extend(read_bits(f, bps) or_return, bps)
            }
        case .Fixed:
            if block_size < order do return false
            for i in 0 ..< order {
                f.pcm_buf[chan_idx][i] = sign_extend(read_bits(f, bps) or_return, bps)
            }
            decode_residual(f, chan_idx, block_size, order) or_return
            restore_fixed_signal(f.pcm_buf[chan_idx], block_size, order)
        case .LPC:
            if block_size < order do return false
            for i in 0 ..< order {
                f.pcm_buf[chan_idx][i] = sign_extend(read_bits(f, bps) or_return, bps)
            }
            lpc_prec := (read_bits(f, 4) or_return) + 1
            if lpc_prec == 16 do return false
            lpc_shift := sign_extend(read_bits(f, 5) or_return, 5)
            if lpc_shift < 0 do return false

            coeffs: [32]i32
            for j in 0 ..< order {
                coeffs[j] = sign_extend(read_bits(f, lpc_prec) or_return, lpc_prec)
            }

            decode_residual(f, chan_idx, block_size, order) or_return
            restore_lpc_signal(f.pcm_buf[chan_idx], block_size, order, coeffs[:order], lpc_shift)
        }

        if wasted_bits > 0 {
            for i in 0 ..< block_size {
                f.pcm_buf[chan_idx][i] <<= wasted_bits
            }
        }
    }

    if len(f.pcm_buf) >= 2 {
        c0 := f.pcm_buf[0]
        c1 := f.pcm_buf[1]
        #partial switch fh.channel {
        case .Left_Side_Stereo:
            for i in 0 ..< block_size {
                c1[i] = c0[i] - c1[i]
            }
        case .Right_Side_Stereo:
            for i in 0 ..< block_size {
                c0[i] = c0[i] + c1[i]
            }
        case .Mid_Side_Stereo:
            for i in 0 ..< block_size {
                mid := c0[i] << 1 | (c1[i] & 1)
                c0[i] = (mid + c1[i]) >> 1
                c1[i] = (mid - c1[i]) >> 1
            }
        case:
        }
    }

    align_to_byte(f)
    crc16 := read_bits(f, 16) or_return
    if f.pos >= frame_start + 2 {
        calc_crc16 := flac_crc16(f.data[frame_start : f.pos - 2])
        if u16(crc16) != calc_crc16 do return false
    }

    f.buf_pos = 0
    f.buf_len = block_size
    return true
}

decode_residual :: proc(f: ^File, chan_idx: u64, block_size: u64, order: u64) -> bool {
    method := read_bits(f, 2) or_return
    if method > 1 do return false

    partition_order := read_bits(f, 4) or_return
    num_partitions := u64(1) << partition_order
    samples_per_partition := block_size >> partition_order

    param_bits: u64 = (method == 0) ? 4 : 5
    escape_val: u64 = (1 << param_bits) - 1

    sample_idx := order

    for p in 0 ..< num_partitions {
        k := read_bits(f, param_bits) or_return
        n_samples := (p == 0) ? (samples_per_partition - order) : samples_per_partition

        if k == escape_val {
            verbatim_bps := read_bits(f, 5) or_return
            for _ in 0 ..< n_samples {
                if sample_idx >= block_size do return false
                if verbatim_bps == 0 {
                    f.pcm_buf[chan_idx][sample_idx] = 0
                } else {
                    f.pcm_buf[chan_idx][sample_idx] = sign_extend(read_bits(f, verbatim_bps) or_return, verbatim_bps)
                }
                sample_idx += 1
            }
        } else {
            for _ in 0 ..< n_samples {
                if sample_idx >= block_size do return false
                q := read_unary(f) or_return
                r: u64 = 0
                if k > 0 {
                    r = read_bits(f, k) or_return
                }
                val := (q << k) | r
                res := (val & 1 != 0) ? -i32(val >> 1) - 1 : i32(val >> 1)
                f.pcm_buf[chan_idx][sample_idx] = res
                sample_idx += 1
            }
        }
    }

    return true
}

restore_fixed_signal :: proc(buf: []i32, block_size: u64, order: u64) {
    c := FIXED_COEFFS[order]
    for i in order ..< block_size {
        pred: i32 = 0
        for j in 0 ..< order do pred += i32(c[j]) * buf[i - 1 - j]
        buf[i] += pred
    }
}

restore_lpc_signal :: proc(buf: []i32, block_size: u64, order: u64, coeffs: []i32, shift: i32) {
    for i in order ..< block_size {
        accu: i64 = 0
        for j in 0 ..< order {
            accu += i64(coeffs[j]) * i64(buf[i - j - 1])
        }
        buf[i] += i32(accu >> u64(shift))
    }
}

read_float :: proc(f: ^File, output: []f32) -> int {
    channels := f.info.channels
    if channels == 0 do return 0

    scale := f32(u64(1) << (f.info.bit_depth - 1))
    written := 0
    total := len(output)

    for written < total {
        if f.buf_pos >= f.buf_len {
            if !decode_next_frame(f) {
                break
            }
        }

        for f.buf_pos < f.buf_len && written < total {
            for c in 0 ..< channels {
                if written >= total do break
                sample_i32 := f.pcm_buf[c][f.buf_pos]
                output[written] = f32(sample_i32) / scale
                written += 1
            }
            f.buf_pos += 1
            f.cur_sample += 1
        }
    }

    return written
}

pcm_seek :: proc(f: ^File, target_pcm: u64) {
    if f == nil || len(f.data) == 0 do return

    target := target_pcm
    if f.info.sample_count > 0 {
        target = clamp(target_pcm, 0, f.info.sample_count - 1)
    }

    if target == 0 {
        f.pos = f.audio_start
        align_to_byte(f)
        f.cur_sample = 0
        f.buf_pos = 0
        f.buf_len = 0
        return
    }

    window := f.info.max_frame_size > 0 ? f.info.max_frame_size + 16 : 262144
    low_pos := f.audio_start
    high_pos := u64(len(f.data))

    best_pos := f.audio_start
    best_sample: u64 = 0
    have_best := false

    for _ in 0 ..< 48 {
        if low_pos >= high_pos do break

        probe_pos := low_pos + (high_pos - low_pos) / 2
        win_end := min(probe_pos + window, high_pos)

        hdr_pos, fh, sample_num, ok := find_frame_in_window(f, probe_pos, win_end)

        if !ok {
            if probe_pos <= low_pos do break
            high_pos = probe_pos
            continue
        }

        if sample_num <= target {
            if !have_best || sample_num > best_sample {
                best_pos = hdr_pos
                best_sample = sample_num
                have_best = true
            }

            if fh.block_size > 0 && target < sample_num + fh.block_size {
                break
            }

            if hdr_pos + 1 <= low_pos do break
            low_pos = hdr_pos + 1
        } else {
            if hdr_pos <= low_pos do break
            high_pos = hdr_pos
        }
    }

    f.pos = best_pos
    align_to_byte(f)
    f.cur_sample = best_sample
    f.buf_pos = 0
    f.buf_len = 0

    for f.cur_sample < target {
        if !decode_next_frame(f) {
            break
        }
        if f.cur_sample + f.buf_len <= target {
            f.cur_sample += f.buf_len
            f.buf_pos = 0
            f.buf_len = 0
        } else {
            offset := target - f.cur_sample
            f.buf_pos = offset
            f.cur_sample = target
            break
        }
    }
}

find_frame_in_window :: proc(f: ^File, start_offset: u64, end_offset: u64) -> (hdr_pos: u64, fh: Frame_Header, sample_num: u64, ok: bool) {
    max_pos := min(end_offset, u64(len(f.data)))
    if start_offset >= max_pos do return

    pos := start_offset
    for pos + 2 <= max_pos {
        b0 := f.data[pos]
        b1 := f.data[pos + 1]
        if b0 == 0xFF && (b1 & 0xFE) == 0xF8 {
            saved_pos := f.pos
            saved_buf := f.bit_buf
            saved_cnt := f.bit_count

            f.pos = pos
            align_to_byte(f)

            if parsed_fh, parsed_ok := frame_header(f); parsed_ok {
                valid := true
                if f.info.channels > 0 && parsed_fh.channel_count != f.info.channels do valid = false
                if f.info.sample_rate > 0 && parsed_fh.sample_rate != f.info.sample_rate do valid = false
                if f.info.bit_depth > 0 && parsed_fh.bits_per_sample != f.info.bit_depth do valid = false

                if valid {
                    s_num: u64
                    if parsed_fh.blocking_strategy == 0 {
                        s_num = parsed_fh.sample_or_frame_num * parsed_fh.block_size
                    } else {
                        s_num = parsed_fh.sample_or_frame_num
                    }

                    f.pos = saved_pos
                    f.bit_buf = saved_buf
                    f.bit_count = saved_cnt
                    return pos, parsed_fh, s_num, true
                }
            }

            f.pos = saved_pos
            f.bit_buf = saved_buf
            f.bit_count = saved_cnt
        }
        pos += 1
    }

    return 0, {}, 0, false
}

pcm_tell :: proc(f: ^File) -> u64 {
    return f.cur_sample
}

pcm_total :: proc(f: ^File) -> u64 {
    return f.info.sample_count
}

// Tables
@(rodata)
BLOCK_SIZES := [16]i32 {
    -1, 192, 576, 1152, 2304, 4608, 0, 0,
    256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
}

@(rodata)
SAMPLE_RATES := [16]i32 {
    0, 88200, 176400, 192000, 8000, 16000, 22050, 24000,
    32000, 44100, 48000, 96000, 0, 0, 0, -1,
}

@(rodata)
SAMPLE_SIZES := [8]i8 { 0, 8, 12, -1, 16, 20, 24, -1 }

@(rodata)
FIXED_COEFFS := [5][4]i8 {
    {0,  0, 0,  0},
    {1,  0, 0,  0},
    {2, -1, 0,  0},
    {3, -3, 1,  0},
    {4, -6, 4, -1},
}

// Utils

flac_crc8 :: proc(data: []u8) -> u8 {
    crc: u8 = 0
    for b in data {
        crc ~= b
        for _ in 0 ..< 8 {
            if (crc & 0x80) != 0 {
                crc = (crc << 1) ~ 0x07
            } else {
                crc <<= 1
            }
        }
    }
    return crc
}

flac_crc16 :: proc(data: []u8) -> u16 {
    crc: u16 = 0
    for b in data {
        crc ~= u16(b) << 8
        for _ in 0 ..< 8 {
            if (crc & 0x8000) != 0 {
                crc = (crc << 1) ~ 0x8005
            } else {
                crc <<= 1
            }
        }
    }
    return crc
}

read_bytes :: proc(f: ^File, n: u64) -> (v: []u8, ok: bool) {
    if int(f.pos + n) > len(f.data) do return
    v = f.data[f.pos : f.pos + n]
    f.pos += n
    return v, true
}

read_u32le :: proc(f: ^File) -> (v: u64, ok: bool) {
    data := read_bytes(f, 4) or_return
    return u64(data[0]) | (u64(data[1]) << 8) | (u64(data[2]) << 16) | (u64(data[3]) << 24), true
}

align_to_byte :: proc(f: ^File) {
    f.bit_buf = 0
    f.bit_count = 0
}

read_bits :: #force_inline proc(f: ^File, count: u64) -> (v: u64, ok: bool) {
    for f.bit_count < count {
        if int(f.pos) >= len(f.data) do return
        f.bit_buf |= u64(f.data[f.pos]) << (56 - f.bit_count)
        f.bit_count += 8
        f.pos += 1
    }

    v = f.bit_buf >> (64 - count)
    f.bit_buf <<= count
    f.bit_count -= count
    return v, true
}

read_utf8_uint :: proc(f: ^File) -> (v: u64, ok: bool) {
    b0 := read_bits(f, 8) or_return
    if b0 & 0x80 == 0 do return b0, true

    num_ones := u64(intrinsics.count_leading_zeros(~u8(b0)))

    v = b0 & (0xFF >> (num_ones + 1))
    for _ in 1 ..< num_ones {
        cb := read_bits(f, 8) or_return
        if (cb & 0xC0) != 0x80 do return
        v = (v << 6) | (cb & 0x3F)
    }

    return v, true
}

sign_extend :: proc(x: u64, b: u64) -> i32 {
    m := u64(1) << (b - 1)
    return i32((x ~ m) - m)
}

read_unary :: proc(f: ^File) -> (q: u64, ok: bool) {
    for {
        bit := read_bits(f, 1) or_return
        if bit == 1 do break
        q += 1
    }
    return q, true
}