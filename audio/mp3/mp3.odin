package mp3

import "core:encoding/endian"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf16"

Info :: struct {
	sample_rate:  u64,
	channels:     u64,
	bitrate:      u64,
	sample_count: u64,
	layer:        u64,
	version:      u64,
}

Tags :: struct {
	title:  string,
	artist: string,
	album:  string,
	track:  int,
}

File :: struct {
	data:         []u8,
	pos:          u64,
	info:         Info,
	tags:         Tags,
	cover:           []u8,
	cover_allocated: bool,
	audio_start:     u64,
	cur_sample:   u64,

	reserv_buf:   [512]u8,
	reserv_len:   int,

	mdct_overlap: [2][9 * 32]f32,
	qmf_state:    [15 * 2 * 32]f32,

	buf_pos:      u64,
	buf_len:      u64,
	pcm_buf:      [2][1152]f32,
}

L3_Gr_Info :: struct {
	part_23_length:    u16,
	big_values:        u16,
	global_gain:       u8,
	scalefac_compress: u16,
	block_type:        u8,
	mixed_block_flag:  u8,
	table_select:      [3]u8,
	subblock_gain:     [3]u8,
	region_count:      [3]u8,
	preflag:           u8,
	scalefac_scale:    u8,
	count1_table:      u8,
	scfsi:             u8,
	sfbtab:            []u8,
	n_long_sfb:        int,
	n_short_sfb:       int,
}

Bit_Stream :: struct {
	buf: []u8,
	pos: int,
}

open_file :: proc(path: string) -> ^File {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil

	f := new(File)
	f.data = data

	parse_id3(f)
	parse_id3v1(f)

	first_pos, ok := find_next_frame(f, f.audio_start)
	if !ok {
		destroy(f)
		return nil
	}

	f.audio_start = first_pos
	f.pos = first_pos

	hdr := f.data[first_pos : first_pos + 4]
	f.info.version = u64((hdr[1] >> 3) & 3)
	f.info.layer = 4 - u64((hdr[1] >> 1) & 3)
	f.info.channels = ((hdr[3] >> 6) & 3) == 3 ? 1 : 2

	sr_idx := (hdr[2] >> 2) & 3
	f.info.sample_rate = u64(SAMPLE_RATES[f.info.version][sr_idx])
	br_idx := (hdr[2] >> 4) & 0xF
	f.info.bitrate = u64(BITRATES[f.info.version][1][br_idx])

	if f.info.sample_rate == 0 {
		destroy(f)
		return nil
	}

	parse_vbr_header(f, first_pos)

	if f.info.sample_count == 0 && f.info.bitrate > 0 {
		audio_bytes := u64(len(f.data)) - f.audio_start
		f.info.sample_count = u64((f64(audio_bytes * 8) / f64(f.info.bitrate * 1000)) * f64(f.info.sample_rate))
	}

	return f
}

destroy :: proc(f: ^File) {
	if f == nil do return
	delete(f.data)
	if len(f.tags.title) > 0  do delete(f.tags.title)
	if len(f.tags.artist) > 0 do delete(f.tags.artist)
	if len(f.tags.album) > 0  do delete(f.tags.album)
	if f.cover_allocated      do delete(f.cover)
	free(f)
}

read_float_stereo :: proc(f: ^File, output: [][2]f32) -> int {
	if f == nil || f.info.channels == 0 do return 0
	written := 0
	total := len(output)

	for written < total {
		if f.buf_pos >= f.buf_len {
			if !decode_next_frame(f) do break
		}

		for f.buf_pos < f.buf_len && written < total {
			if f.info.channels == 1 {
				val := f.pcm_buf[0][f.buf_pos]
				output[written] = {val, val}
			} else {
				output[written] = {f.pcm_buf[0][f.buf_pos], f.pcm_buf[1][f.buf_pos]}
			}
			written += 1
			f.buf_pos += 1
			f.cur_sample += 1
		}
	}
	return written
}

reset_stream_state :: proc(f: ^File, target: u64, pos: u64) {
	f.pos = pos
	f.reserv_len = 0
	f.mdct_overlap = 0
	f.qmf_state = 0
	f.cur_sample = target
	f.buf_pos = 0
	f.buf_len = 0
}

pcm_seek :: proc(f: ^File, target_pcm: u64) {
	if f == nil || len(f.data) == 0 do return
	target := f.info.sample_count > 0 ? clamp(target_pcm, 0, f.info.sample_count - 1) : target_pcm

	if target == f.cur_sample do return

	// Intra-buffer seek optimization
	if target > f.cur_sample {
		rem_in_buf := f.buf_len - f.buf_pos
		diff := target - f.cur_sample
		if diff <= rem_in_buf {
			f.buf_pos += diff
			f.cur_sample = target
			return
		}
	}

	reset_stream_state(f, 0, f.audio_start)
	if target == 0 do return

	spf := u64(f.info.version == 3 ? 1152 : 576)
	target_frame := target / spf
	intra_offset := target % spf
	warmup_start := target_frame > 2 ? target_frame - 2 : 0

	for _ in 0 ..< warmup_start {
		if !skip_next_frame(f) do break
	}
	f.cur_sample = warmup_start * spf

	for cur_fr := warmup_start; cur_fr < target_frame; cur_fr += 1 {
		if !decode_next_frame(f) do break
		f.cur_sample += f.buf_len
	}

	if decode_next_frame(f) {
		f.buf_pos = min(intra_offset, f.buf_len)
		f.cur_sample = target
	}
}

skip_next_frame :: proc(f: ^File) -> bool {
	for f.pos + 4 <= u64(len(f.data)) {
		hdr_pos, ok := find_next_frame(f, f.pos)
		if !ok do return false

		frame_bytes, samples, ok_hdr := parse_frame_header(f.data[hdr_pos : hdr_pos + 4])
		if !ok_hdr || hdr_pos + u64(frame_bytes) > u64(len(f.data)) {
			f.pos = hdr_pos + 1
			continue
		}

		if skip_frame_payload(f, f.data[hdr_pos : hdr_pos + 4], f.data[hdr_pos : hdr_pos + u64(frame_bytes)]) {
			f.pos = hdr_pos + u64(frame_bytes)
			f.buf_pos = 0
			f.buf_len = u64(samples)
			return true
		}
		f.pos = hdr_pos + 1
	}
	return false
}

skip_frame_payload :: proc(f: ^File, hdr: []u8, frame_data: []u8) -> bool {
	offset := 4 + ((hdr[1] & 1) == 0 ? 2 : 0)
	nch := ((hdr[3] >> 6) & 3) == 3 ? 1 : 2
	is_mpeg1 := ((hdr[1] >> 3) & 3) == 3
	ngr := is_mpeg1 ? 2 : 1

	side_len := is_mpeg1 ? (nch == 1 ? 17 : 32) : (nch == 1 ? 9 : 17)
	if offset + side_len > len(frame_data) do return false

	side_bs := Bit_Stream{buf = frame_data[offset : offset + side_len]}
	offset += side_len

	gr_info: [4]L3_Gr_Info
	main_data_begin := read_side_info(&side_bs, gr_info[:], hdr, nch, ngr)
	if main_data_begin < 0 do return false

	payload := frame_data[offset:]
	scratch: [4096]u8
	bytes_have := min(f.reserv_len, main_data_begin)
	reserv_src := max(0, f.reserv_len - main_data_begin)

	if bytes_have > 0 do copy(scratch[:bytes_have], f.reserv_buf[reserv_src : reserv_src + bytes_have])
	if len(payload) > 0 do copy(scratch[bytes_have : bytes_have + len(payload)], payload)

	tot_bytes := bytes_have + len(payload)
	bit_pos := 0
	if f.reserv_len >= main_data_begin {
		for gr in 0 ..< ngr {
			for ch in 0 ..< nch {
				gi := &gr_info[gr * nch + ch]
				bit_pos += int(gi.part_23_length)
			}
		}
	}

	remains := min(tot_bytes - ((bit_pos + 7) / 8), 511)
	if remains > 0 {
		pos := tot_bytes - remains
		copy(f.reserv_buf[:remains], scratch[pos : pos + remains])
	}
	f.reserv_len = max(0, remains)
	return true
}

pcm_tell :: proc(f: ^File) -> u64 { return f.cur_sample }
pcm_total :: proc(f: ^File) -> u64 { return f.info.sample_count }

// Frame Decoding & Reservoir Pipeline

decode_next_frame :: proc(f: ^File) -> bool {
	for f.pos + 4 <= u64(len(f.data)) {
		hdr_pos, ok := find_next_frame(f, f.pos)
		if !ok do return false

		frame_bytes, samples, ok_hdr := parse_frame_header(f.data[hdr_pos : hdr_pos + 4])
		if !ok_hdr || hdr_pos + u64(frame_bytes) > u64(len(f.data)) {
			f.pos = hdr_pos + 1
			continue
		}

		if decode_frame_payload(f, f.data[hdr_pos : hdr_pos + 4], f.data[hdr_pos : hdr_pos + u64(frame_bytes)], samples) {
			f.pos = hdr_pos + u64(frame_bytes)
			f.buf_pos = 0
			f.buf_len = u64(samples)
			return true
		}
		f.pos = hdr_pos + 1
	}
	return false
}

decode_frame_payload :: proc(f: ^File, hdr: []u8, frame_data: []u8, samples_per_frame: int) -> bool {
	offset := 4 + ((hdr[1] & 1) == 0 ? 2 : 0)
	nch := ((hdr[3] >> 6) & 3) == 3 ? 1 : 2
	is_mpeg1 := ((hdr[1] >> 3) & 3) == 3
	ngr := is_mpeg1 ? 2 : 1

	side_len := is_mpeg1 ? (nch == 1 ? 17 : 32) : (nch == 1 ? 9 : 17)
	if offset + side_len > len(frame_data) do return false

	side_bs := Bit_Stream{buf = frame_data[offset : offset + side_len]}
	offset += side_len

	gr_info: [4]L3_Gr_Info
	main_data_begin := read_side_info(&side_bs, gr_info[:], hdr, nch, ngr)
	if main_data_begin < 0 do return false

	payload := frame_data[offset:]
	scratch: [4096]u8
	bytes_have := min(f.reserv_len, main_data_begin)
	reserv_src := max(0, f.reserv_len - main_data_begin)

	if bytes_have > 0 do copy(scratch[:bytes_have], f.reserv_buf[reserv_src : reserv_src + bytes_have])
	if len(payload) > 0 do copy(scratch[bytes_have : bytes_have + len(payload)], payload)

	tot_bytes := bytes_have + len(payload)
	if tot_bytes + 8 <= len(scratch) do slice.zero(scratch[tot_bytes : tot_bytes + 8])

	main_bs := Bit_Stream{buf = scratch[:tot_bytes + 8]}
	grbuf: [2][576]f32
	ist_pos: [2][40]u8
	scf: [40]f32
	pcm_offset := 0

	if f.reserv_len >= main_data_begin {
		for gr in 0 ..< ngr {
			for ch in 0 ..< nch {
				gi := &gr_info[gr * nch + ch]
				limit := main_bs.pos + int(gi.part_23_length)
				decode_scalefactors(hdr, ist_pos[ch][:], &main_bs, gi, scf[:], ch)
				huffman_decode(grbuf[ch][:], &main_bs, gi, scf[:], limit)
			}

			if (hdr[3] & 0x10) != 0 && nch == 2 {
				intensity_stereo(grbuf[0][:], ist_pos[1][:], &gr_info[gr * nch], hdr)
			} else if (hdr[3] & 0xE0) == 0x60 && nch == 2 {
				midside_stereo(&grbuf)
			}

			for ch in 0 ..< nch {
				gi := &gr_info[gr * nch + ch]
				sr_mode := get_my_sample_rate(hdr)
				n_long := (gi.mixed_block_flag != 0 ? 2 : 0) << uint(sr_mode == 2 ? 1 : 0)
				aa_bands := 31

				if gi.n_short_sfb > 0 {
					aa_bands = n_long - 1
					reorder(grbuf[ch][n_long * 18 :], gi.sfbtab[gi.n_long_sfb :])
				}
				if aa_bands > 0 do antialias(grbuf[ch][:], aa_bands)

				imdct_granule(grbuf[ch][:], f.mdct_overlap[ch][:], uint(gi.block_type), uint(n_long))
				change_sign(grbuf[ch][:])
			}

			synth_granule(&f.qmf_state, grbuf[:], 18, nch, f.pcm_buf[:], pcm_offset)
			pcm_offset += 576
		}
	} else {
		slice.zero(f.pcm_buf[0][:])
		slice.zero(f.pcm_buf[1][:])
	}

	remains := min(tot_bytes - ((main_bs.pos + 7) / 8), 511)
	if remains > 0 {
		pos := tot_bytes - remains
		copy(f.reserv_buf[:remains], scratch[pos : pos + remains])
	}
	f.reserv_len = max(0, remains)
	return true
}

// Side Info & Scalefactors

read_side_info :: proc(bs: ^Bit_Stream, gr: []L3_Gr_Info, hdr: []u8, nch: int, ngr: int) -> int {
	is_mpeg1 := ((hdr[1] >> 3) & 3) == 3
	sr_idx := max(0, get_my_sample_rate(hdr) - 1)
	gr_count := nch * ngr
	main_begin := is_mpeg1 ? int(get_bits(bs, 9)) : int(get_bits(bs, uint(8 + nch)) >> uint(nch))
	scfsi := is_mpeg1 ? get_bits(bs, uint(7 + gr_count)) : 0

	idx := 0
	for _ in 0 ..< ngr {
		for _ in 0 ..< nch {
			gi := &gr[idx]
			if nch == 1 do scfsi <<= 4

			gi.part_23_length = u16(get_bits(bs, 12))
			gi.big_values = u16(get_bits(bs, 9))
			if gi.big_values > 288 do return -1

			gi.global_gain = u8(get_bits(bs, 8))
			gi.scalefac_compress = u16(get_bits(bs, is_mpeg1 ? 4 : 9))
			gi.sfbtab = SCF_LONG[sr_idx]
			gi.n_long_sfb = 22
			gi.n_short_sfb = 0

			if get_bits(bs, 1) != 0 {
				gi.block_type = u8(get_bits(bs, 2))
				if gi.block_type == 0 do return -1
				gi.mixed_block_flag = u8(get_bits(bs, 1))
				gi.region_count = {7, 255, 255}

				if gi.block_type == 2 {
					scfsi &= 0x0F0F
					if gi.mixed_block_flag == 0 {
						gi.region_count[0] = 8
						gi.sfbtab = SCF_SHORT[sr_idx]
						gi.n_long_sfb = 0
						gi.n_short_sfb = 39
					} else {
						gi.sfbtab = SCF_MIXED[sr_idx]
						gi.n_long_sfb = is_mpeg1 ? 8 : 6
						gi.n_short_sfb = 30
					}
				}
				tables := get_bits(bs, 10) << 5
				gi.subblock_gain = {u8(get_bits(bs, 3)), u8(get_bits(bs, 3)), u8(get_bits(bs, 3))}
				gi.table_select = {u8(tables >> 10), u8((tables >> 5) & 31), 0}
			} else {
				gi.block_type = 0
				gi.mixed_block_flag = 0
				tables := get_bits(bs, 15)
				gi.region_count = {u8(get_bits(bs, 4)), u8(get_bits(bs, 3)), 255}
				gi.table_select = {u8(tables >> 10), u8((tables >> 5) & 31), u8(tables & 31)}
			}

			gi.preflag = is_mpeg1 ? u8(get_bits(bs, 1)) : u8(gi.scalefac_compress >= 500 ? 1 : 0)
			gi.scalefac_scale = u8(get_bits(bs, 1))
			gi.count1_table = u8(get_bits(bs, 1))
			gi.scfsi = u8((scfsi >> 12) & 15)
			scfsi <<= 4
			idx += 1
		}
	}
	return main_begin
}

decode_scalefactors :: proc(hdr: []u8, ist_pos: []u8, bs: ^Bit_Stream, gi: ^L3_Gr_Info, scf: []f32, ch: int) {
	is_mpeg1 := ((hdr[1] >> 3) & 3) == 3
	is_ms := (hdr[3] & 0xE0) == 0x60
	part_idx := (gi.n_short_sfb > 0 ? 1 : 0) + (gi.n_long_sfb == 0 ? 1 : 0)
	partition := SCF_PARTITIONS[part_idx]

	scf_size: [4]u8
	iscf: [40]u8
	scf_shift := int(gi.scalefac_scale) + 1
	scfsi := int(gi.scfsi)

	if is_mpeg1 {
		p := SCFC_DECODE[gi.scalefac_compress]
		scf_size = {p >> 2, p >> 2, p & 3, p & 3}
	} else {
		is_ist := (hdr[3] & 0x10) != 0 && ch != 0
		sfc := int(gi.scalefac_compress >> (is_ist ? 1 : 0))
		k := (is_ist ? 1 : 0) * 12
		for sfc >= 0 {
			modprod := 1
			for i := 3; i >= 0; i -= 1 {
				m := int(MOD_TAB[k + i])
				scf_size[i] = u8((sfc / modprod) % m)
				modprod *= m
			}
			sfc -= modprod
			if sfc >= 0 do k += 4
		}
		partition = partition[k:]
		scfsi = -16
	}

	scf_idx, ist_idx := 0, 0
	for i in 0 ..< 4 {
		if i >= len(partition) || partition[i] == 0 do break
		cnt := int(partition[i])
		if (scfsi & 8) != 0 {
			copy(iscf[scf_idx : scf_idx + cnt], ist_pos[ist_idx : ist_idx + cnt])
		} else {
			bits := uint(scf_size[i])
			if bits == 0 {
				slice.zero(iscf[scf_idx : scf_idx + cnt])
				slice.zero(ist_pos[ist_idx : ist_idx + cnt])
			} else {
				max_scf := scfsi < 0 ? int((1 << bits) - 1) : -1
				for k in 0 ..< cnt {
					s := int(get_bits(bs, bits))
					ist_pos[ist_idx + k] = u8(s == max_scf ? 255 : s)
					iscf[scf_idx + k] = u8(s)
				}
			}
		}
		scfsi *= 2
		ist_idx += cnt
		scf_idx += cnt
	}

	if gi.n_short_sfb > 0 {
		sh := uint(3 - scf_shift)
		for i := 0; i < gi.n_short_sfb; i += 3 {
			iscf[gi.n_long_sfb + i + 0] += gi.subblock_gain[0] << sh
			iscf[gi.n_long_sfb + i + 1] += gi.subblock_gain[1] << sh
			iscf[gi.n_long_sfb + i + 2] += gi.subblock_gain[2] << sh
		}
	} else if gi.preflag != 0 {
		for i in 0 ..< 10 do iscf[11 + i] += PREAMP[i]
	}

	gain := ldexp_q2(2048.0, 44 - (int(gi.global_gain) - 214 - (is_ms ? 2 : 0)))
	total_sfb := gi.n_long_sfb + gi.n_short_sfb
	for i in 0 ..< total_sfb {
		scf[i] = ldexp_q2(gain, int(iscf[i]) << uint(scf_shift))
	}
}

// Huffman Decoding

read_byte_safe :: #force_inline proc(buf: []u8, p: ^int) -> u32 {
	if p^ < len(buf) {
		b := u32(buf[p^])
		p^ += 1
		return b
	}
	p^ += 1
	return 0
}

huffman_decode :: proc(dst: []f32, bs: ^Bit_Stream, gi: ^L3_Gr_Info, scf: []f32, limit: int) {
	slice.zero(dst)

	ptr := bs.pos / 8
	bit_offset := uint(bs.pos & 7)
	b0 := read_byte_safe(bs.buf, &ptr)
	b1 := read_byte_safe(bs.buf, &ptr)
	b2 := read_byte_safe(bs.buf, &ptr)
	b3 := read_byte_safe(bs.buf, &ptr)
	cache := (((b0 * 256 + b1) * 256 + b2) * 256 + b3) << bit_offset
	sh := int(bit_offset) - 8

	dst_idx := 0
	big_vals := int(gi.big_values)
	ireg, sfb_idx, scf_idx := 0, 0, 0
	one: f32 = 0.0

	// Big values region
	for big_vals > 0 {
		tab_num := gi.table_select[ireg]
		sfb_cnt := int(gi.region_count[ireg])
		ireg += 1
		codebook := int(TABINDEX[tab_num])
		linbits := uint(LINBITS[tab_num])

		for {
			if sfb_idx >= len(gi.sfbtab) || gi.sfbtab[sfb_idx] == 0 do break
			np := int(gi.sfbtab[sfb_idx]) / 2
			sfb_idx += 1
			pairs := min(big_vals, np)
			one = scf[scf_idx]
			scf_idx += 1

			for _ in 0 ..< pairs {
				w: uint = 5
				leaf := int(HUFFMAN_TABS[codebook + int(cache >> (32 - w))])
				for leaf < 0 {
					cache <<= w; sh += int(w)
					w = uint(leaf & 7)
					leaf = int(HUFFMAN_TABS[codebook + int(cache >> (32 - w)) - (leaf >> 3)])
				}
				fl := uint(leaf >> 8)
				cache <<= fl; sh += int(fl)

				for _ in 0 ..< 2 {
					lsb := leaf & 0x0F
					leaf >>= 4
					if lsb == 15 && linbits > 0 {
						lsb += int(cache >> (32 - linbits))
						cache <<= linbits; sh += int(linbits)
						for sh >= 0 {
							cache |= read_byte_safe(bs.buf, &ptr) << uint(sh); sh -= 8
						}
						if dst_idx < len(dst) {
							dst[dst_idx] = one * pow_43(lsb) * ((i32(cache) < 0) ? -1.0 : 1.0)
						}
					} else if dst_idx < len(dst) {
						dst[dst_idx] = POW43[16 + lsb - 16 * int(cache >> 31)] * one
					}
					if lsb != 0 { cache <<= 1; sh += 1 }
					dst_idx += 1
				}

				for sh >= 0 {
					cache |= read_byte_safe(bs.buf, &ptr) << uint(sh); sh -= 8
				}
			}

			big_vals -= np
			sfb_cnt -= 1
			if big_vals <= 0 || sfb_cnt < 0 do break
		}
	}

	// Count1 quadruplets region
	np_cnt := 1 - big_vals
	for dst_idx + 3 < len(dst) {
		c1_tab := (gi.count1_table != 0) ? TAB33[:] : TAB32[:]
		leaf := int(c1_tab[cache >> 28])
		if (leaf & 8) == 0 {
			leaf = int(c1_tab[(leaf >> 3) + int((cache << 4) >> uint(32 - (leaf & 3)))])
		}
		fl := uint(leaf & 7)
		cache <<= fl; sh += int(fl)

		if (ptr * 8 - 24 + sh) > limit do break

		for s in 0 ..< 4 {
			if s == 0 || s == 2 {
				np_cnt -= 1
				if np_cnt <= 0 {
					if sfb_idx >= len(gi.sfbtab) || gi.sfbtab[sfb_idx] == 0 do break
					np_cnt = int(gi.sfbtab[sfb_idx]) / 2
					sfb_idx += 1
					if np_cnt == 0 do break
					one = scf[scf_idx]
					scf_idx += 1
				}
			}
			if (leaf & (128 >> uint(s))) != 0 {
				dst[dst_idx + s] = (i32(cache) < 0) ? -one : one
				cache <<= 1; sh += 1
			}
		}

		for sh >= 0 {
			cache |= read_byte_safe(bs.buf, &ptr) << uint(sh); sh -= 8
		}
		dst_idx += 4
	}

	bs.pos = limit
}

// Stereo, IMDCT, & Synthesis Filterbank

midside_stereo :: proc(grbuf: ^[2][576]f32) {
	a, b := grbuf[0], grbuf[1]
	grbuf[0] = a + b
	grbuf[1] = a - b
}

intensity_stereo :: proc(left: []f32, ist_pos: []u8, gr: ^L3_Gr_Info, hdr: []u8) {
	is_mpeg1 := ((hdr[1] >> 3) & 3) == 3
	is_ms := (hdr[3] & 0x20) != 0
	n_sfb := gr.n_long_sfb + gr.n_short_sfb
	max_blocks := gr.n_short_sfb > 0 ? 3 : 1
	max_band: [3]int = {-1, -1, -1}

	right := left[576:]
	ro := 0
	for i in 0 ..< n_sfb {
		if i >= len(gr.sfbtab) do break
		bl := int(gr.sfbtab[i])
		for k := 0; k < bl; k += 2 {
			if right[ro + k] != 0.0 || right[ro + k + 1] != 0.0 {
				max_band[i % 3] = i
				break
			}
		}
		ro += bl
	}

	if gr.n_long_sfb > 0 {
		m := max(max_band[0], max(max_band[1], max_band[2]))
		max_band = {m, m, m}
	}

	for i in 0 ..< max_blocks {
		itop := n_sfb - max_blocks + i
		prev := itop - max_blocks
		if itop < len(ist_pos) {
			ist_pos[itop] = (prev >= 0 && max_band[i] < prev) ? ist_pos[prev] : (is_mpeg1 ? 3 : 0)
		}
	}

	offset := 0
	for i := 0; i < len(gr.sfbtab) && gr.sfbtab[i] != 0; i += 1 {
		bl := int(gr.sfbtab[i])
		ipos := u32(i < len(ist_pos) ? ist_pos[i] : 0)
		if i > max_band[i % 3] && ipos < (is_mpeg1 ? 7 : 64) {
			s: f32 = is_ms ? 1.41421356 : 1.0
			kl, kr: f32 = 1.0, 1.0
			if is_mpeg1 {
				kl, kr = PAN[2 * ipos] * s, PAN[2 * ipos + 1] * s
			} else {
				gr_right := mem.ptr_offset(gr, 1)
				mpeg2_sh := uint(gr_right.scalefac_compress & 1)
				ratio := ldexp_q2(1.0, int(((ipos + 1) >> 1) << mpeg2_sh))
				if (ipos & 1) != 0 {
					kl, kr = ratio * s, s
				} else {
					kl, kr = s, ratio * s
				}
			}
			for k in 0 ..< bl {
				left[576 + offset + k] = left[offset + k] * kr
				left[offset + k] *= kl
			}
		} else if is_ms {
			for k in 0 ..< bl {
				a, b := left[offset + k], left[576 + offset + k]
				left[offset + k] = a + b
				left[576 + offset + k] = a - b
			}
		}
		offset += bl
	}
}

reorder :: proc(buf: []f32, sfb: []u8) {
	scratch: [576]f32
	dst_idx, src_idx, ptr := 0, 0, 0
	for ptr < len(sfb) && sfb[ptr] != 0 {
		bl := int(sfb[ptr]); ptr += 3
		for _ in 0 ..< bl {
			if dst_idx + 2 < len(scratch) && src_idx + 2 * bl < len(buf) {
				scratch[dst_idx + 0] = buf[src_idx]
				scratch[dst_idx + 1] = buf[src_idx + bl]
				scratch[dst_idx + 2] = buf[src_idx + 2 * bl]
			}
			dst_idx += 3; src_idx += 1
		}
		src_idx += 2 * bl
	}
	copy(buf[:dst_idx], scratch[:dst_idx])
}

antialias :: proc(grbuf: []f32, nbands: int) {
	offset := 0
	for _ in 0 ..< nbands {
		for i in 0 ..< 8 {
			u := grbuf[offset + 18 + i]
			d := grbuf[offset + 17 - i]
			grbuf[offset + 18 + i] = u * ANTIALIAS[0][i] - d * ANTIALIAS[1][i]
			grbuf[offset + 17 - i] = u * ANTIALIAS[1][i] + d * ANTIALIAS[0][i]
		}
		offset += 18
	}
}

dct3_9 :: proc(y: ^[9]f32) {
	s0, s2, s4, s6, s8 := y[0], y[2], y[4], y[6], y[8]
	t0 := s0 + s6 * 0.5
	s0 -= s6
	t4 := (s4 + s2) * 0.93969262
	t2 := (s8 + s2) * 0.76604444
	s6 = (s4 - s8) * 0.17364818
	s4 += s8 - s2
	s2 = s0 - s4 * 0.5
	y[4] = s4 + s0
	s8 = t0 - t2 + s6
	s0 = t0 - t4 + t2
	s4 = t0 + t4 - s6

	s1, s3, s5, s7 := y[1], y[3] * 0.86602540, y[5], y[7]
	t0 = (s5 + s1) * 0.98480775
	t4 = (s5 - s7) * 0.34202014
	t2 = (s1 + s7) * 0.64278761
	s1 = (s1 - s5 - s7) * 0.86602540
	s5 = t0 - s3 - t2
	s7 = t4 - s3 - t0
	s3 = t4 + s3 - t2

	y[0] = s4 - s7; y[1] = s2 + s1; y[2] = s0 - s3; y[3] = s8 + s5
	y[5] = s8 - s5; y[6] = s0 + s3; y[7] = s2 - s1; y[8] = s4 + s7
}

imdct36 :: proc(grbuf: []f32, overlap: []f32, window: []f32, nbands: int) {
	gr_idx, ovl_idx := 0, 0
	tw_cos := (cast(^[9]f32)&TWID9[9])^
	tw_sin := (cast(^[9]f32)&TWID9[0])^
	win0 := (cast(^[9]f32)&window[0])^
	win1 := (cast(^[9]f32)&window[9])^

	for _ in 0 ..< nbands {
		co, si: [9]f32
		co[0] = -grbuf[gr_idx]
		si[0] =  grbuf[gr_idx + 17]

		for i in 0 ..< 4 {
			si[8 - 2 * i] =  grbuf[gr_idx + 4 * i + 1] - grbuf[gr_idx + 4 * i + 2]
			co[1 + 2 * i] =  grbuf[gr_idx + 4 * i + 1] + grbuf[gr_idx + 4 * i + 2]
			si[7 - 2 * i] =  grbuf[gr_idx + 4 * i + 4] - grbuf[gr_idx + 4 * i + 3]
			co[2 + 2 * i] = -(grbuf[gr_idx + 4 * i + 3] + grbuf[gr_idx + 4 * i + 4])
		}
		dct3_9(&co); dct3_9(&si)
		si[1] = -si[1]; si[3] = -si[3]; si[5] = -si[5]; si[7] = -si[7]

		sum := co * tw_cos + si * tw_sin
		new_ovl := co * tw_sin - si * tw_cos

		ovl := (cast(^[9]f32)&overlap[ovl_idx])^
		(cast(^[9]f32)&overlap[ovl_idx])^ = new_ovl

		(cast(^[9]f32)&grbuf[gr_idx])^ = ovl * win0 - sum * win1
		high := ovl * win1 + sum * win0
		for i in 0 ..< 9 do grbuf[gr_idx + 17 - i] = high[i]

		gr_idx += 18; ovl_idx += 9
	}
}

imdct12 :: proc(x: []f32, dst: []f32, overlap: []f32) {
	m1, a1 := (x[6] + x[3]) * 0.86602540, -x[0] - (x[12] + x[9]) * 0.5
	co := [3]f32{a1 + m1, -x[0] + x[12] + x[9], a1 - m1}

	m2, a2 := (x[12] - x[9]) * 0.86602540, x[15] - (x[6] - x[3]) * 0.5
	si := [3]f32{a2 + m2, -(x[15] + x[6] - x[3]), a2 - m2}

	for i in 0 ..< 3 {
		ovl := overlap[i]
		sum := co[i] * TWID3[3 + i] + si[i] * TWID3[i]
		overlap[i] = co[i] * TWID3[i] - si[i] * TWID3[3 + i]
		dst[i]     = ovl * TWID3[2 - i] - sum * TWID3[5 - i]
		dst[5 - i] = ovl * TWID3[5 - i] + sum * TWID3[2 - i]
	}
}

imdct_granule :: proc(grbuf: []f32, overlap: []f32, block_type: uint, n_long: uint) {
	if n_long > 0 do imdct36(grbuf, overlap, MDCT_WINDOW[0][:], int(n_long))
	rem := 32 - int(n_long)
	og, oo := int(n_long) * 18, int(n_long) * 9

	if block_type == 2 {
		for _ in 0 ..< rem {
			tmp: [18]f32
			copy(tmp[:], grbuf[og : og + 18])
			copy(grbuf[og : og + 6], overlap[oo : oo + 6])
			imdct12(tmp[:], grbuf[og + 6:], overlap[oo + 6:])
			imdct12(tmp[1:], grbuf[og + 12:], overlap[oo + 6:])
			imdct12(tmp[2:], overlap[oo:], overlap[oo + 6:])
			oo += 9; og += 18
		}
	} else {
		win := block_type == 3 ? 1 : 0
		imdct36(grbuf[og:], overlap[oo:], MDCT_WINDOW[win][:], rem)
	}
}

change_sign :: proc(grbuf: []f32) {
	for b := 1; b < 32; b += 2 {
		for i := 1; i < 18; i += 2 do grbuf[b * 18 + i] = -grbuf[b * 18 + i]
	}
}

dct_ii :: proc(grbuf: []f32, n: int) {
	for k in 0 ..< n {
		t: [4][8]f32
		y := grbuf[k:]

		for i in 0 ..< 8 {
			x0, x1, x2, x3 := y[i * 18], y[(15 - i) * 18], y[(16 + i) * 18], y[(31 - i) * 18]
			t0, t1 := x0 + x3, x1 + x2
			t2 := (x1 - x2) * SEC[3 * i + 0]
			t3 := (x0 - x3) * SEC[3 * i + 1]
			t[0][i] = t0 + t1
			t[1][i] = (t0 - t1) * SEC[3 * i + 2]
			t[2][i] = t3 + t2
			t[3][i] = (t3 - t2) * SEC[3 * i + 2]
		}

		for m in 0 ..< 4 {
			x0, x1, x2, x3 := t[m][0], t[m][1], t[m][2], t[m][3]
			x4, x5, x6, x7 := t[m][4], t[m][5], t[m][6], t[m][7]

			xt := x0 - x7; x0 += x7
			x7 = x1 - x6; x1 += x6
			x6 = x2 - x5; x2 += x5
			x5 = x3 - x4; x3 += x4
			x4 = x0 - x3; x0 += x3
			x3 = x1 - x2; x1 += x2

			t[m][0] = x0 + x1
			t[m][4] = (x0 - x1) * 0.70710677
			x5 = x5 + x6
			x6 = (x6 + x7) * 0.70710677
			x7 = x7 + xt
			x3 = (x3 + x4) * 0.70710677

			x5 -= x7 * 0.198912367
			x7 += x5 * 0.382683432
			x5 -= x7 * 0.198912367
			x0 = xt - x6; xt += x6

			t[m][1] = (xt + x7) * 0.50979561
			t[m][2] = (x4 + x3) * 0.54119611
			t[m][3] = (x0 - x5) * 0.60134488
			t[m][5] = (x0 + x5) * 0.89997619
			t[m][6] = (x4 - x3) * 1.30656302
			t[m][7] = (xt - x7) * 2.56291556
		}

		y_idx := 0
		for i in 0 ..< 7 {
			y[y_idx + 0 * 18] = t[0][i]
			y[y_idx + 1 * 18] = t[2][i] + t[3][i] + t[3][i + 1]
			y[y_idx + 2 * 18] = t[1][i] + t[1][i + 1]
			y[y_idx + 3 * 18] = t[2][i + 1] + t[3][i] + t[3][i + 1]
			y_idx += 4 * 18
		}
		y[y_idx + 0 * 18] = t[0][7]
		y[y_idx + 1 * 18] = t[2][7] + t[3][7]
		y[y_idx + 2 * 18] = t[1][7]
		y[y_idx + 3 * 18] = t[3][7]
	}
}

synth_granule :: proc(qmf_state: ^[15 * 2 * 32]f32, grbuf: [][576]f32, nbands: int, nch: int, pcm_out: [][1152]f32, pcm_offset: int) {
	for i in 0 ..< nch do dct_ii(grbuf[i][:], nbands)

	lins: [33 * 64]f32
	mem.copy(&lins[0], &qmf_state[0], 15 * 64 * size_of(f32))
	scale: f32 = 1.0 / 32768.0

	for i := 0; i < nbands; i += 2 {
		zb := i * 64 + 15 * 64
		w_idx := 0
		xl := grbuf[0][i :]
		xr := nch == 2 ? grbuf[1][i :] : xl

		lins[zb + 60] = xl[18 * 16]; lins[zb + 61] = xr[18 * 16]; lins[zb + 62] = xl[0]; lins[zb + 63] = xr[0]
		lins[zb + 124] = xl[1 + 18 * 16]; lins[zb + 125] = xr[1 + 18 * 16]; lins[zb + 126] = xl[1]; lins[zb + 127] = xr[1]

		base := pcm_offset + 32 * i
		synth_pair(pcm_out, 0, base, lins[:], i * 64 + 60, scale)
		synth_pair(pcm_out, 0, base + 32, lins[:], i * 64 + 124, scale)
		if nch == 2 {
			synth_pair(pcm_out, 1, base, lins[:], i * 64 + 61, scale)
			synth_pair(pcm_out, 1, base + 32, lins[:], i * 64 + 125, scale)
		}

		for step := 14; step >= 0; step -= 1 {
			lins[zb + 4 * step]          = xl[18 * (31 - step)]
			lins[zb + 4 * step + 1]      = xr[18 * (31 - step)]
			lins[zb + 4 * step + 2]      = xl[1 + 18 * (31 - step)]
			lins[zb + 4 * step + 3]      = xr[1 + 18 * (31 - step)]
			lins[zb + 4 * (step + 16)]     = xl[1 + 18 * (1 + step)]
			lins[zb + 4 * (step + 16) + 1] = xr[1 + 18 * (1 + step)]
			lins[zb + 4 * (step - 16) + 2] = xl[18 * (1 + step)]
			lins[zb + 4 * (step - 16) + 3] = xr[18 * (1 + step)]

			a, b: [4]f32
			for k in 0 ..< 8 {
				w0, w1 := SYNTH_WIN[w_idx], SYNTH_WIN[w_idx + 1]; w_idx += 2
				vz := (cast(^[4]f32)&lins[zb + 4 * step - k * 64])^
				vy := (cast(^[4]f32)&lins[zb + 4 * step - (15 - k) * 64])^
				b_term := vz * w1 + vy * w0
				a_term := (k & 1) != 0 ? (vy * w1 - vz * w0) : (vz * w0 - vy * w1)
				if k == 0 { a = a_term; b = b_term } else { a += a_term; b += b_term }
			}

			a *= scale; b *= scale
			for c in 0 ..< nch {
				pcm_out[c][base + (15 - step)] = a[c]
				pcm_out[c][base + (17 + step)] = b[c]
				pcm_out[c][base + (47 - step)] = a[2 + c]
				pcm_out[c][base + (49 + step)] = b[2 + c]
			}
		}
	}
	mem.copy(&qmf_state[0], &lins[nbands * 64], 15 * 64 * size_of(f32))
}

synth_pair :: proc(pcm_out: [][1152]f32, ch: int, base: int, lins: []f32, z: int, scale: f32) {
	a := (lins[z + 14 * 64] - lins[z]) * 29.0 + (lins[z + 64] + lins[z + 13 * 64]) * 213.0 +
	     (lins[z + 12 * 64] - lins[z + 2 * 64]) * 459.0 + (lins[z + 3 * 64] + lins[z + 11 * 64]) * 2037.0 +
	     (lins[z + 10 * 64] - lins[z + 4 * 64]) * 5153.0 + (lins[z + 5 * 64] + lins[z + 9 * 64]) * 6574.0 +
	     (lins[z + 8 * 64] - lins[z + 6 * 64]) * 37489.0 + lins[z + 7 * 64] * 75038.0
	pcm_out[ch][base] = a * scale

	z2 := z + 2
	a2 := lins[z2 + 14 * 64] * 104.0 + lins[z2 + 12 * 64] * 1567.0 + lins[z2 + 10 * 64] * 9727.0 +
	      lins[z2 + 8 * 64] * 64019.0 - lins[z2 + 6 * 64] * 9975.0 - lins[z2 + 4 * 64] * 45.0 +
	      lins[z2 + 2 * 64] * 146.0 - lins[z2] * 5.0
	pcm_out[ch][base + 16] = a2 * scale
}

// Utilities & Math Helpers

pow_43 :: proc(x: int) -> f32 {
	if x < 129 do return POW43[16 + x]
	mult: f32 = 256.0
	x := x
	if x < 1024 { mult = 16.0; x <<= 3 }
	sign := (2 * x) & 64
	frac := f32((x & 63) - sign) / f32((x & ~int(63)) + sign)
	return POW43[16 + ((x + sign) >> 6)] * (1.0 + frac * ((4.0 / 3.0) + frac * (2.0 / 9.0))) * mult
}

ldexp_q2 :: proc(y: f32, exp_q2: int) -> f32 {
	y, exp := y, exp_q2
	for exp > 0 {
		e := min(120, exp)
		y *= EXPFRAC[e & 3] * f32(u32(1 << 30) >> uint(e >> 2))
		exp -= e
	}
	return y
}

get_bits :: proc(bs: ^Bit_Stream, bits: uint) -> u32 {
	if bits == 0 do return 0
	p, sh := bs.pos / 8, uint(bs.pos & 7)
	b0 := u32(p + 0 < len(bs.buf) ? bs.buf[p + 0] : 0)
	b1 := u32(p + 1 < len(bs.buf) ? bs.buf[p + 1] : 0)
	b2 := u32(p + 2 < len(bs.buf) ? bs.buf[p + 2] : 0)
	b3 := u32(p + 3 < len(bs.buf) ? bs.buf[p + 3] : 0)
	bs.pos += int(bits)
	return (((b0 << 24) | (b1 << 16) | (b2 << 8) | b3) << sh) >> (32 - bits)
}

get_my_sample_rate :: proc(hdr: []u8) -> int {
	return int((hdr[2] >> 2) & 3) + (int((hdr[1] >> 3) & 1) + int((hdr[1] >> 4) & 1)) * 3
}

parse_frame_header :: proc(b: []u8) -> (frame_bytes: int, samples: int, ok: bool) {
	if len(b) < 4 || b[0] != 0xFF || (b[1] & 0xE0) != 0xE0 do return 0, 0, false
	v := (b[1] >> 3) & 3
	if v == 1 || ((b[1] >> 1) & 3) != 1 do return 0, 0, false // Layer III only
	br := (b[2] >> 4) & 0xF
	sr := (b[2] >> 2) & 3
	if br == 0 || br == 15 || sr == 3 || (b[3] & 3) == 2 do return 0, 0, false
	kbps := int(BITRATES[v][1][br])
	hz := int(SAMPLE_RATES[v][sr])
	samples = v == 3 ? 1152 : 576
	return (samples * kbps * 125) / hz + int((b[2] >> 1) & 1), samples, true
}

find_next_frame :: proc(f: ^File, start: u64) -> (pos: u64, ok: bool) {
	max_p := u64(len(f.data))
	for p := start; p + 4 <= max_p; p += 1 {
		if f.data[p] == 0xFF && (f.data[p + 1] & 0xE0) == 0xE0 {
			if fb, _, ok_h := parse_frame_header(f.data[p : p + 4]); ok_h {
				next_p := p + u64(fb)
				if next_p + 4 <= max_p {
					if _, _, ok_next := parse_frame_header(f.data[next_p : next_p + 4]); ok_next do return p, true
				} else {
					return p, true
				}
			}
		}
	}
	return 0, false
}

// ID3 & VBR Metadata Parsing

synchsafe_u32 :: proc(b: []u8) -> u64 {
	return (u64(b[0] & 0x7F) << 21) | (u64(b[1] & 0x7F) << 14) | (u64(b[2] & 0x7F) << 7) | u64(b[3] & 0x7F)
}

parse_track_number :: proc(s: string) -> int {
	if len(s) == 0 do return 0
	trimmed := strings.trim_space(s)
	slash_idx := strings.index_byte(trimmed, '/')
	num_part := slash_idx >= 0 ? trimmed[:slash_idx] : trimmed
	return strconv.parse_int(num_part) or_else 0
}

find_image_magic :: proc(data: []u8) -> int {
	if len(data) < 4 do return -1
	for i in 0 ..< min(256, len(data) - 4) {
		if data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF {
			return i
		}
		if data[i] == 0x89 && data[i + 1] == 0x50 && data[i + 2] == 0x4E && data[i + 3] == 0x47 {
			return i
		}
		if data[i] == 0x47 && data[i + 1] == 0x49 && data[i + 2] == 0x46 {
			return i
		}
	}
	return -1
}

deunsynchronize :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	has_unsynch := false
	for i in 0 ..< len(data) - 1 {
		if data[i] == 0xFF && data[i + 1] == 0x00 {
			has_unsynch = true
			break
		}
	}
	if !has_unsynch do return nil

	out := make([]u8, len(data), allocator)
	out_idx := 0
	i := 0
	for i < len(data) {
		out[out_idx] = data[i]
		out_idx += 1
		if data[i] == 0xFF && i + 1 < len(data) && data[i + 1] == 0x00 {
			i += 2
		} else {
			i += 1
		}
	}
	return out[:out_idx]
}

parse_apic :: proc(f: ^File, body: []u8, is_v2: bool, unsynch: bool) {
	if len(body) < 8 do return
	enc := body[0]
	p := 1

	if is_v2 {
		if p + 3 > len(body) do return
		p += 3 // 3-byte format (e.g. "JPG")
	} else {
		for p < len(body) && body[p] != 0 do p += 1
		p += 1 // skip MIME null terminator
	}

	if p >= len(body) do return
	pic_type := body[p]
	p += 1

	// Description string terminated according to encoding
	if enc == 1 || enc == 2 {
		for p + 1 < len(body) {
			if body[p] == 0 && body[p + 1] == 0 {
				p += 2
				break
			}
			p += 2
		}
	} else {
		for p < len(body) && body[p] != 0 do p += 1
		p += 1
	}

	if p >= len(body) do return

	img_data := body[p:]
	magic_off := find_image_magic(img_data)
	if magic_off >= 0 {
		img_data = img_data[magic_off:]
	}

	if len(img_data) == 0 do return
	if pic_type != 3 && len(f.cover) > 0 do return

	if f.cover_allocated {
		delete(f.cover)
		f.cover_allocated = false
	}

	if unsynch {
		clean := deunsynchronize(img_data, context.allocator)
		if clean != nil {
			f.cover = clean
			f.cover_allocated = true
			return
		}
	}

	f.cover = img_data
	f.cover_allocated = false
}

parse_id3 :: proc(f: ^File) {
	if len(f.data) < 10 || string(f.data[:3]) != "ID3" do return
	ver := f.data[3]
	flags := f.data[5]
	tag_size := synchsafe_u32(f.data[6:10])
	tag_end := min(10 + tag_size, u64(len(f.data)))
	f.audio_start = tag_end + ((flags & 0x10) != 0 ? 10 : 0) // Footer (ID3v2.4)

	pos: u64 = 10

	// Extended Header
	if (flags & 0x40) != 0 && pos + 4 <= tag_end {
		ext_sz: u64 = 0
		if ver == 3 {
			ext_sz = 4 + u64(endian.unchecked_get_u32be(f.data[pos : pos + 4]))
		} else if ver == 4 {
			ext_sz = synchsafe_u32(f.data[pos : pos + 4])
		}
		if pos + ext_sz <= tag_end do pos += ext_sz
	}

	global_unsynch := (flags & 0x80) != 0

	for {
		if ver == 2 {
			if pos + 6 > tag_end do break
			id := string(f.data[pos : pos + 3])
			if id[0] == 0 do break
			sz := u64(f.data[pos + 3]) << 16 | u64(f.data[pos + 4]) << 8 | u64(f.data[pos + 5])
			bpos := pos + 6
			if bpos + sz > tag_end do break
			body := f.data[bpos : bpos + sz]

			switch id {
			case "TT2": f.tags.title = decode_id3_text(body)
			case "TP1", "TP2":
				if len(f.tags.artist) == 0 do f.tags.artist = decode_id3_text(body)
			case "TAL": f.tags.album = decode_id3_text(body)
			case "TRK":
				s := decode_id3_text(body); defer delete(s)
				f.tags.track = parse_track_number(s)
			case "PIC":
				parse_apic(f, body, true, global_unsynch)
			}
			pos = bpos + sz
		} else {
			if pos + 10 > tag_end do break
			id := string(f.data[pos : pos + 4])
			if id[0] == 0 do break
			sz := ver == 4 ? synchsafe_u32(f.data[pos + 4 : pos + 8]) : u64(endian.unchecked_get_u32be(f.data[pos + 4 : pos + 8]))
			fflags := endian.unchecked_get_u16be(f.data[pos + 8 : pos + 10])
			bpos := pos + 10
			if bpos + sz > tag_end do break
			body := f.data[bpos : bpos + sz]

			// ID3v2.4 Data Length Indicator (bit 0 = 0x0001)
			if ver == 4 && (fflags & 0x0001) != 0 && len(body) >= 4 {
				body = body[4:]
			}

			frame_unsynch := global_unsynch || (ver == 4 && (fflags & 0x0002) != 0)

			switch id {
			case "TIT2": f.tags.title = decode_id3_text(body)
			case "TPE1": f.tags.artist = decode_id3_text(body)
			case "TPE2":
				if len(f.tags.artist) == 0 do f.tags.artist = decode_id3_text(body)
			case "TALB": f.tags.album = decode_id3_text(body)
			case "TRCK":
				s := decode_id3_text(body); defer delete(s)
				f.tags.track = parse_track_number(s)
			case "APIC":
				parse_apic(f, body, false, frame_unsynch)
			}
			pos = bpos + sz
		}
	}
}

decode_id3_text :: proc(body: []u8) -> string {
	if len(body) <= 1 do return ""
	enc, txt := body[0], body[1:]
	switch enc {
	case 0: // ISO-8859-1 (Latin-1)
		end := slice.linear_search(txt, 0) or_else len(txt)
		b := strings.builder_make(context.temp_allocator)
		for c in txt[:end] do strings.write_rune(&b, rune(c))
		s := strings.trim_space(strings.to_string(b))
		return strings.clone(s, context.allocator)

	case 1: // UTF-16 with BOM
		if len(txt) < 2 do return ""
		be := txt[0] == 0xFE && txt[1] == 0xFF
		le := txt[0] == 0xFF && txt[1] == 0xFE
		if !be && !le do return ""
		raw := txt[2:]
		u16_count := len(raw) / 2
		u16s := make([]u16, u16_count, context.temp_allocator)
		valid_len := 0
		for i in 0 ..< u16_count {
			b0, b1 := u16(raw[i * 2]), u16(raw[i * 2 + 1])
			val := be ? (b0 << 8 | b1) : (b1 << 8 | b0)
			if val == 0 do break
			u16s[i] = val
			valid_len += 1
		}
		buf := make([]byte, valid_len * 4, context.temp_allocator)
		n := utf16.decode_to_utf8(buf, u16s[:valid_len])
		s := strings.trim_space(string(buf[:n]))
		return strings.clone(s, context.allocator)

	case 2: // UTF-16BE without BOM (ID3v2.4)
		u16_count := len(txt) / 2
		u16s := make([]u16, u16_count, context.temp_allocator)
		valid_len := 0
		for i in 0 ..< u16_count {
			b0, b1 := u16(txt[i * 2]), u16(txt[i * 2 + 1])
			val := (b0 << 8 | b1)
			if val == 0 do break
			u16s[i] = val
			valid_len += 1
		}
		buf := make([]byte, valid_len * 4, context.temp_allocator)
		n := utf16.decode_to_utf8(buf, u16s[:valid_len])
		s := strings.trim_space(string(buf[:n]))
		return strings.clone(s, context.allocator)

	case 3: // UTF-8
		end := slice.linear_search(txt, 0) or_else len(txt)
		s := strings.trim_space(string(txt[:end]))
		return strings.clone(s, context.allocator)
	}
	return ""
}

parse_id3v1 :: proc(f: ^File) {
	n := len(f.data)
	if n < 128 || string(f.data[n - 128 : n - 125]) != "TAG" do return
	tag := f.data[n - 128 : n]
	clean_v1 :: proc(dst: ^string, src: []u8) {
		if len(dst^) > 0 do return
		end := slice.linear_search(src, 0) or_else len(src)
		s := strings.trim_space(string(src[:end]))
		if len(s) > 0 do dst^ = strings.clone(s, context.allocator)
	}
	clean_v1(&f.tags.title, tag[3:33])
	clean_v1(&f.tags.artist, tag[33:63])
	clean_v1(&f.tags.album, tag[63:93])
	if f.tags.track == 0 && tag[125] == 0 && tag[126] != 0 {
		f.tags.track = int(tag[126])
	}
}

parse_vbr_header :: proc(f: ^File, first_pos: u64) {
	hdr := f.data[first_pos : first_pos + 4]
	v := (hdr[1] >> 3) & 3
	spf := u64(v == 3 ? 1152 : 576)
	side_len := v == 3 ? (((hdr[3] >> 6) & 3) == 3 ? 17 : 32) : (((hdr[3] >> 6) & 3) == 3 ? 9 : 17)
	xo := first_pos + 4 + ((hdr[1] & 1) == 0 ? 2 : 0) + u64(side_len)

	if xo + 8 <= u64(len(f.data)) {
		m := string(f.data[xo : xo + 4])
		if m == "Xing" || m == "Info" {
			flags := endian.unchecked_get_u32be(f.data[xo + 4 : xo + 8])
			curr := xo + 8
			if (flags & 1) != 0 && curr + 4 <= u64(len(f.data)) {
				f.info.sample_count = u64(endian.unchecked_get_u32be(f.data[curr : curr + 4])) * spf
				curr += 4
			}
			return
		}
	}

	vo := first_pos + 4 + ((hdr[1] & 1) == 0 ? 2 : 0) + 32
	if vo + 26 <= u64(len(f.data)) && string(f.data[vo : vo + 4]) == "VBRI" {
		f.info.sample_count = u64(endian.unchecked_get_u32be(f.data[vo + 14 : vo + 18])) * spf
	}
}
