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
    pcm_buf: [8][]i32,
}

Info :: struct {
    sample_rate:  u64,
    channels:     u64,
    bit_depth:    u64,
    sample_count: u64,
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

    if !parse(f) || f.info.sample_rate == 0 {
        free(f)
        delete(data)
        return nil
    }

    f.audio_start = f.pos

    for i in 0 ..< 8 {
        f.pcm_buf[i] = make([]i32, 65535)
    }

    return f
}

destroy :: proc(file: ^File) {
    if file == nil do return
    for buf in file.pcm_buf {
        delete(buf)
    }
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
        case 0:
            if len != 34 do return false
            parse_stream_info(f) or_return
        case 4: parse_vorbis_comment(f)
        case 6: parse_picture(f)
        }

        f.pos = end_pos
        if is_last != 0 do break
    }

    return true
}

parse_stream_info :: proc(f: ^File) -> bool {
    read_bits(f, 16) or_return
    read_bits(f, 16) or_return
    read_bits(f, 24) or_return
    read_bits(f, 24) or_return
    f.info.sample_rate = read_bits(f, 20) or_return
    f.info.channels = (read_bits(f, 3) or_return) + 1
    f.info.bit_depth = (read_bits(f, 5) or_return) + 1
    f.info.sample_count = read_bits(f, 36) or_return
    read_bytes(f, 16) or_return

    return true
}

parse_picture :: proc(f: ^File) -> bool {
    pic_type := read_bits(f, 32) or_return
    mime_len := read_bits(f, 32) or_return
    read_bytes(f, mime_len) or_return
    desc_len := read_bits(f, 32) or_return
    read_bytes(f, desc_len) or_return
    read_bytes(f, 16) or_return

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

    crc8_calculated := crc8(f.data[header_start : f.pos])
    crc8_stored := read_bits(f, 8) or_return
    if u8(crc8_stored) != crc8_calculated do return


    return fh, true
}

decode_next_frame :: proc(f: ^File) -> bool {
    if decode_single_frame(f) do return true

    search_pos := f.pos
    for {
        hdr_pos, _, _, ok := find_frame_in_window(f, search_pos, u64(len(f.data)))
        if !ok do break

        f.pos = hdr_pos
        align_to_byte(f)
        if decode_single_frame(f) do return true

        search_pos = hdr_pos + 1
    }

    return false
}

decode_single_frame :: proc(f: ^File) -> bool {
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
    crc16_calculated := crc16(f.data[frame_start : f.pos])
    crc16_stored := read_bits(f, 16) or_return
    if u16(crc16_stored) != crc16_calculated do return false

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
    if samples_per_partition == 0 do return false

    param_bits: u64 = (method == 0) ? 4 : 5
    escape_val: u64 = (1 << param_bits) - 1

    sample_idx := order

    for p in 0 ..< num_partitions {
        k := read_bits(f, param_bits) or_return

        p_start := p * samples_per_partition
        p_end := (p + 1) * samples_per_partition
        res_start := max(p_start, order)
        n_samples := p_end > res_start ? (p_end - res_start) : 0

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

read_float_stereo :: proc(f: ^File, output: [][2]f32) -> int {
    if f.info.channels == 0 do return 0

    if f.info.bit_depth == 0 || f.info.bit_depth > 32 do return 0
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
            if f.info.channels == 1 {
                sample_i32 := f.pcm_buf[0][f.buf_pos]
                val := f32(sample_i32) / scale
                output[written] = {val, val}
            } else {
                s0 := f32(f.pcm_buf[0][f.buf_pos]) / scale
                s1 := f32(f.pcm_buf[1][f.buf_pos]) / scale
                output[written] = {s0, s1}
            }
            written += 1
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

    window: u64 = 262144
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

// Utils

crc8 :: proc(data: []u8) -> u8 {
    crc: u8 = 0
    for b in data {
        crc = CRC8_TABLE[crc ~ b]
    }
    return crc
}

crc16 :: proc(data: []u8) -> u16 {
    crc: u16 = 0
    for b in data {
        crc = (crc << 8) ~ CRC16_TABLE[u8(crc >> 8) ~ b]
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
    for q < 65536 {
        bit := read_bits(f, 1) or_return
        if bit == 1 do return q, true
        q += 1
    }
    return
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

@(rodata)
CRC8_TABLE := [256]u8 {
    0x00, 0x07, 0x0E, 0x09, 0x1C, 0x1B, 0x12, 0x15, 0x38, 0x3F, 0x36, 0x31, 0x24, 0x23, 0x2A, 0x2D,
    0x70, 0x77, 0x7E, 0x79, 0x6C, 0x6B, 0x62, 0x65, 0x48, 0x4F, 0x46, 0x41, 0x54, 0x53, 0x5A, 0x5D,
    0xE0, 0xE7, 0xEE, 0xE9, 0xFC, 0xFB, 0xF2, 0xF5, 0xD8, 0xDF, 0xD6, 0xD1, 0xC4, 0xC3, 0xCA, 0xCD,
    0x90, 0x97, 0x9E, 0x99, 0x8C, 0x8B, 0x82, 0x85, 0xA8, 0xAF, 0xA6, 0xA1, 0xB4, 0xB3, 0xBA, 0xBD,
    0xC7, 0xC0, 0xC9, 0xCE, 0xDB, 0xDC, 0xD5, 0xD2, 0xFF, 0xF8, 0xF1, 0xF6, 0xE3, 0xE4, 0xED, 0xEA,
    0xB7, 0xB0, 0xB9, 0xBE, 0xAB, 0xAC, 0xA5, 0xA2, 0x8F, 0x88, 0x81, 0x86, 0x93, 0x94, 0x9D, 0x9A,
    0x27, 0x20, 0x29, 0x2E, 0x3B, 0x3C, 0x35, 0x32, 0x1F, 0x18, 0x11, 0x16, 0x03, 0x04, 0x0D, 0x0A,
    0x57, 0x50, 0x59, 0x5E, 0x4B, 0x4C, 0x45, 0x42, 0x6F, 0x68, 0x61, 0x66, 0x73, 0x74, 0x7D, 0x7A,
    0x89, 0x8E, 0x87, 0x80, 0x95, 0x92, 0x9B, 0x9C, 0xB1, 0xB6, 0xBF, 0xB8, 0xAD, 0xAA, 0xA3, 0xA4,
    0xF9, 0xFE, 0xF7, 0xF0, 0xE5, 0xE2, 0xEB, 0xEC, 0xC1, 0xC6, 0xCF, 0xC8, 0xDD, 0xDA, 0xD3, 0xD4,
    0x69, 0x6E, 0x67, 0x60, 0x75, 0x72, 0x7B, 0x7C, 0x51, 0x56, 0x5F, 0x58, 0x4D, 0x4A, 0x43, 0x44,
    0x19, 0x1E, 0x17, 0x10, 0x05, 0x02, 0x0B, 0x0C, 0x21, 0x26, 0x2F, 0x28, 0x3D, 0x3A, 0x33, 0x34,
    0x4E, 0x49, 0x40, 0x47, 0x52, 0x55, 0x5C, 0x5B, 0x76, 0x71, 0x78, 0x7F, 0x6A, 0x6D, 0x64, 0x63,
    0x3E, 0x39, 0x30, 0x37, 0x22, 0x25, 0x2C, 0x2B, 0x06, 0x01, 0x08, 0x0F, 0x1A, 0x1D, 0x14, 0x13,
    0xAE, 0xA9, 0xA0, 0xA7, 0xB2, 0xB5, 0xBC, 0xBB, 0x96, 0x91, 0x98, 0x9F, 0x8A, 0x8D, 0x84, 0x83,
    0xDE, 0xD9, 0xD0, 0xD7, 0xC2, 0xC5, 0xCC, 0xCB, 0xE6, 0xE1, 0xE8, 0xEF, 0xFA, 0xFD, 0xF4, 0xF3,
}

@(rodata)
CRC16_TABLE := [256]u16 {
    0x0000, 0x8005, 0x800F, 0x000A, 0x801B, 0x001E, 0x0014, 0x8011,
    0x8033, 0x0036, 0x003C, 0x8039, 0x0028, 0x802D, 0x8027, 0x0022,
    0x8063, 0x0066, 0x006C, 0x8069, 0x0078, 0x807D, 0x8077, 0x0072,
    0x0050, 0x8055, 0x805F, 0x005A, 0x804B, 0x004E, 0x0044, 0x8041,
    0x80C3, 0x00C6, 0x00CC, 0x80C9, 0x00D8, 0x80DD, 0x80D7, 0x00D2,
    0x00F0, 0x80F5, 0x80FF, 0x00FA, 0x80EB, 0x00EE, 0x00E4, 0x80E1,
    0x00A0, 0x80A5, 0x80AF, 0x00AA, 0x80BB, 0x00BE, 0x00B4, 0x80B1,
    0x8093, 0x0096, 0x009C, 0x8099, 0x0088, 0x808D, 0x8087, 0x0082,
    0x8183, 0x0186, 0x018C, 0x8189, 0x0198, 0x819D, 0x8197, 0x0192,
    0x01B0, 0x81B5, 0x81BF, 0x01BA, 0x81AB, 0x01AE, 0x01A4, 0x81A1,
    0x01E0, 0x81E5, 0x81EF, 0x01EA, 0x81FB, 0x01FE, 0x01F4, 0x81F1,
    0x81D3, 0x01D6, 0x01DC, 0x81D9, 0x01C8, 0x81CD, 0x81C7, 0x01C2,
    0x0140, 0x8145, 0x814F, 0x014A, 0x815B, 0x015E, 0x0154, 0x8151,
    0x8173, 0x0176, 0x017C, 0x8179, 0x0168, 0x816D, 0x8167, 0x0162,
    0x8123, 0x0126, 0x012C, 0x8129, 0x0138, 0x813D, 0x8137, 0x0132,
    0x0110, 0x8115, 0x811F, 0x011A, 0x810B, 0x010E, 0x0104, 0x8101,
    0x8303, 0x0306, 0x030C, 0x8309, 0x0318, 0x831D, 0x8317, 0x0312,
    0x0330, 0x8335, 0x833F, 0x033A, 0x832B, 0x032E, 0x0324, 0x8321,
    0x0360, 0x8365, 0x836F, 0x036A, 0x837B, 0x037E, 0x0374, 0x8371,
    0x8353, 0x0356, 0x035C, 0x8359, 0x0348, 0x834D, 0x8347, 0x0342,
    0x03C0, 0x83C5, 0x83CF, 0x03CA, 0x83DB, 0x03DE, 0x03D4, 0x83D1,
    0x83F3, 0x03F6, 0x03FC, 0x83F9, 0x03E8, 0x83ED, 0x83E7, 0x03E2,
    0x83A3, 0x03A6, 0x03AC, 0x83A9, 0x03B8, 0x83BD, 0x83B7, 0x03B2,
    0x0390, 0x8395, 0x839F, 0x039A, 0x838B, 0x038E, 0x0384, 0x8381,
    0x0280, 0x8285, 0x828F, 0x028A, 0x829B, 0x029E, 0x0294, 0x8291,
    0x82B3, 0x02B6, 0x02BC, 0x82B9, 0x02A8, 0x82AD, 0x82A7, 0x02A2,
    0x82E3, 0x02E6, 0x02EC, 0x82E9, 0x02F8, 0x82FD, 0x82F7, 0x02F2,
    0x02D0, 0x82D5, 0x82DF, 0x02DA, 0x82CB, 0x02CE, 0x02C4, 0x82C1,
    0x8243, 0x0246, 0x024C, 0x8249, 0x0258, 0x825D, 0x8257, 0x0252,
    0x0270, 0x8275, 0x827F, 0x027A, 0x826B, 0x026E, 0x0264, 0x8261,
    0x0220, 0x8225, 0x822F, 0x022A, 0x823B, 0x023E, 0x0234, 0x8231,
    0x8213, 0x0216, 0x021C, 0x8219, 0x0208, 0x820D, 0x8207, 0x0202,
}