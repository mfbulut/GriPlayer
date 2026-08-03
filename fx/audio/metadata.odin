package audio

import "core:os"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"
import "core:encoding/base64"
import "core:encoding/endian"

import "opusfile"
import "vendor:stb/vorbis"
import "drmp3"
import "drflac"
import "drwav"

Metadata :: struct {
	title:    string,
	artist:   string,
	album:    string,
	track:    int,
	duration: f32,
	cover:    []byte,
}

metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	ext := strings.to_lower(os.ext(path), context.temp_allocator)

	switch ext {
	case ".ogg":
		meta, ok = parse_vorbis_metadata(path)
		if ok do return
		meta, ok = parse_opus_metadata(path)
	case ".opus":
		meta, ok = parse_opus_metadata(path)
	case ".mp3":
		meta, ok = parse_mp3_metadata(path)
	case ".flac":
		meta, ok = parse_flac_metadata(path)
	case ".wav":
		meta, ok = parse_wav_metadata(path)
	}

	return
}

parse_tags :: proc(tags: []string, meta: ^Metadata) {
	for comment in tags {
		idx := strings.index_byte(comment, '=')
		if idx <= 0 do continue
		key := strings.to_upper(comment[:idx], context.temp_allocator)
		val := comment[idx+1:]

		switch key {
		case "TITLE":
			meta.title = strings.clone(val, context.temp_allocator)
		case "ALBUMARTIST":
			meta.artist = strings.clone(val, context.temp_allocator)
		case "ARTIST":
			if meta.artist == "" {
				meta.artist = strings.clone(val, context.temp_allocator)
			}
		case "ALBUM":
			meta.album = strings.clone(val, context.temp_allocator)
		case "TRACKNUMBER":
			meta.track = strconv.parse_int(val) or_continue
		case "METADATA_BLOCK_PICTURE":
			if decoded_buf, err := base64.decode(val, allocator = context.temp_allocator); err == nil {
				meta.cover = parse_flac_picture(decoded_buf)
			}
		}
	}
}

parse_vorbis_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	vf := open_vorbis_file(path)
	if vf == nil do return
	ok = true
	defer vorbis.close(vf)

	info := vorbis.get_info(vf)
	if pcm_tot := vorbis.stream_length_in_samples(vf); pcm_tot > 0 && info.sample_rate > 0 {
		meta.duration = f32(pcm_tot) / f32(info.sample_rate)
	}

	vc := vorbis.get_comment(vf)
	tags := make([]string, vc.comment_list_length, context.temp_allocator)

	for i in 0..<vc.comment_list_length {
		tags[i] = string(vc.comment_list[i])
	}

	parse_tags(tags, &meta)

	return
}

parse_opus_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	of := opusfile.open_file(path)
	if of == nil do return
	ok = true
	defer opusfile.free(of)

	if pcm_tot := opusfile.pcm_total(of, -1); pcm_tot > 0 {
		meta.duration = f32(pcm_tot) / 48000.0
	}

    tags := opusfile.tags(of, 0)
    comments := make([]string, tags.comment_count, context.temp_allocator)

    for &c, i in comments {
        len := tags.comment_lengths[i]
        c = string(tags.user_comments[i][:len])
    }

	parse_tags(comments, &meta)

	return
}

parse_mp3_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	mp3 := drmp3.open_file(path)
	if mp3 == nil do return
	meta.duration = f32(drmp3.get_pcm_frame_count(mp3)) / f32(drmp3.get_sampleRate(mp3))
	drmp3.uninit(mp3)
	free(mp3)

	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	ok = true

	decode_text :: proc(data: []byte) -> string {
		if len(data) == 0 do return ""
		encoding := data[0]
		raw := data[1:]
		if len(raw) == 0 do return ""

		buf := make([dynamic]byte, 0, len(raw), context.temp_allocator)
		push :: proc(buf: ^[dynamic]byte, r: rune) {
			bytes, n := utf8.encode_rune(r)
			append(buf, ..bytes[:n])
		}

		switch encoding {
		case 0x00: // ISO-8859-1
			for b in raw {
				if b == 0 do break
				push(&buf, rune(b))
			}
		case 0x01, 0x02:
			byte_order : endian.Byte_Order = encoding == 0x02 ? .Big : .Little
			off := 0
			if encoding == 0x01 && len(raw) >= 2 {
				if raw[0] == 0xFE && raw[1] == 0xFF {
					byte_order, off = .Big, 2
				} else if raw[0] == 0xFF && raw[1] == 0xFE {
					byte_order, off = .Little, 2
				}
			}
			i := off
			for i + 1 < len(raw) {
				code := endian.get_u16(raw[i:], byte_order) or_break
				if code == 0 do break

				if code >= 0xD800 && code <= 0xDBFF && i + 3 < len(raw) {
					next := endian.get_u16(raw[i+2:], byte_order) or_break
					if next >= 0xDC00 && next <= 0xDFFF {
						r := rune(((u32(code) - 0xD800) << 10) + (u32(next) - 0xDC00) + 0x10000)
						push(&buf, r)
						i += 4
						continue
					}
				}
				push(&buf, rune(code))
				i += 2
			}
		case 0x03:
			for b in raw {
				if b == 0 do break
				append(&buf, b)
			}
		case:
			for b in raw {
				if b == 0 do break
				push(&buf, rune(b))
			}
		}

		return strings.trim_space(string(buf[:]))
	}

	header: [10]byte
	n, _ := os.read(f, header[:])
	if n != 10 || string(header[:3]) != "ID3" do return

	version := header[3]
	flags := header[5]
	size := (int(header[6]) << 21) | (int(header[7]) << 14) | (int(header[8]) << 7) | int(header[9])

	idx := 10
	if (flags & 0x40) != 0 {
		ext: [4]byte
		if n, _ := os.read(f, ext[:]); n == 4 {
			if version == 3 {
				ext_size := int(endian.unchecked_get_u32be(ext[:]))
				os.seek(f, i64(ext_size), .Current)
				idx += 4 + ext_size
			} else {
				ext_size := (int(ext[0]) << 21) | (int(ext[1]) << 14) | (int(ext[2]) << 7) | int(ext[3])
				os.seek(f, i64(ext_size - 4), .Current)
				idx += ext_size
			}
		}
	}
	end := 10 + size

	for idx < end {
		frame_id := ""
		frame_size := 0
		frame_unsync := false

		if version == 2 {
			if idx + 6 > end do break
			fh: [6]byte
			if n, _ := os.read(f, fh[:]); n < 6 do break
			frame_id = string(fh[:3])
			if frame_id[0] == 0 do break
			frame_size = int(fh[3])<<16 | int(fh[4])<<8 | int(fh[5])
			idx += 6
		} else {
			if idx + 10 > end do break
			fh: [10]byte
			if n, _ := os.read(f, fh[:]); n < 10 do break
			frame_id = string(fh[:4])
			if frame_id[0] == 0 do break
			if version >= 4 {
				frame_size = (int(fh[4]) << 21) | (int(fh[5]) << 14) | (int(fh[6]) << 7) | int(fh[7])
				if (fh[9] & 0x02) != 0 do frame_unsync = true
			} else {
				frame_size = int(endian.unchecked_get_u32be(fh[4:8]))
			}
			idx += 10
		}

		if frame_size <= 0 || idx + frame_size > end do break

		switch frame_id {
		case "TIT2", "TT2":
			data := make([]byte, frame_size, context.temp_allocator)
			if n, _ := os.read(f, data); n == frame_size {
				meta.title = strings.clone(decode_text(data), context.temp_allocator)
			}
		case "TPE1", "TP1":
			data := make([]byte, frame_size, context.temp_allocator)
			if n, _ := os.read(f, data); n == frame_size {
				meta.artist = strings.clone(decode_text(data), context.temp_allocator)
			}
		case "TALB", "TAL":
			data := make([]byte, frame_size, context.temp_allocator)
			if n, _ := os.read(f, data); n == frame_size {
				meta.album = strings.clone(decode_text(data), context.temp_allocator)
			}
		case "TRCK", "TRK":
			data := make([]byte, frame_size, context.temp_allocator)
			if n, _ := os.read(f, data); n == frame_size {
				txt := decode_text(data)
				if slash := strings.index_byte(txt, '/'); slash > 0 {
					txt = txt[:slash]
				}
				meta.track = strconv.parse_int(strings.trim_space(txt)) or_else 0
			}
		case "APIC", "PIC":
			data := make([]byte, frame_size, context.temp_allocator)
			if n, _ := os.read(f, data); n == frame_size {
				for i in 0 ..< len(data) - 3 {
					is_jpeg := data[i] == 0xFF && data[i+1] == 0xD8 && data[i+2] == 0xFF
					is_png := data[i] == 0x89 && data[i+1] == 0x50 && data[i+2] == 0x4E && data[i+3] == 0x47
					if !is_jpeg && !is_png do continue

					img := data[i:]
					if (flags & 0x80) != 0 || frame_unsync {
						decoded := make([]byte, len(img), context.temp_allocator)
						dn := 0
						for j := 0; j < len(img); j += 1 {
							decoded[dn] = img[j]
							dn += 1
							if img[j] == 0xFF && j + 1 < len(img) && img[j+1] == 0x00 do j += 1
						}
						meta.cover = decoded[:dn]
					} else {
						meta.cover = slice.clone(img, context.temp_allocator)
					}
					break
				}
			}
		case:
			os.seek(f, i64(frame_size), .Current)
		}

		idx += frame_size
	}

	return
}

parse_flac_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	flac := drflac.open_file(path)
	if flac == nil do return
	meta.duration = f32(drflac.get_totalPCMFrameCount(flac)) / f32(drflac.get_sampleRate(flac))
	drflac.close(flac)

	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	ok = true

	header: [4]byte
	if n, _ := os.read(f, header[:]); n < 4 do return
	if string(header[:4]) != "fLaC" do return

	for {
		fh: [4]byte
		if n, _ := os.read(f, fh[:]); n < 4 do break

		is_last := (fh[0] & 0x80) != 0
		block_type := fh[0] & 0x7F
		// 24-bit big-endian; core:encoding/endian has no u24 helper.
		length := int(fh[1])<<16 | int(fh[2])<<8 | int(fh[3])

		if block_type == 4 {
			block_data := make([]byte, length, context.temp_allocator)
			if n, _ := os.read(f, block_data); n < length do break

			if len(block_data) >= 4 {
				vendor_len := int(endian.unchecked_get_u32le(block_data[0:4]))
				offset := 4 + vendor_len
				if offset + 4 <= len(block_data) {
					list_len := int(endian.unchecked_get_u32le(block_data[offset:offset+4]))
					offset += 4

					tags := make([dynamic]string, 0, list_len, context.temp_allocator)
					for _ in 0..<list_len {
						if offset + 4 > len(block_data) do break
						comment_len := int(endian.unchecked_get_u32le(block_data[offset:offset+4]))
						offset += 4

						if offset + comment_len > len(block_data) do break
						comment := string(block_data[offset:offset+comment_len])
						offset += comment_len

						append(&tags, comment)
					}
					parse_tags(tags[:], &meta)
				}
			}
		} else if block_type == 6 {
			block_data := make([]byte, length, context.temp_allocator)
			if n, _ := os.read(f, block_data); n < length do break
			if pic := parse_flac_picture(block_data); pic != nil {
				meta.cover = pic
			}
		} else {
			os.seek(f, i64(length), .Current)
		}

		if is_last do break
	}

	return
}

parse_wav_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	wav := drwav.open_file(path)
	if wav != nil {
		meta.duration = f32(drwav.get_totalPCMFrameCount(wav)) / f32(drwav.get_sampleRate(wav))
		ok = true
		drwav.uninit(wav)
		free(wav)
	}
	return
}

parse_flac_picture :: proc(block_data: []byte) -> []byte {
	if len(block_data) < 32 do return nil

	buf := block_data[4:]
	mime_len := endian.unchecked_get_u32be(buf)
	if len(buf) < int(4 + mime_len) do return nil
	buf = buf[4+mime_len:]

	if len(buf) < 4 do return nil
	desc_len := endian.unchecked_get_u32be(buf)
	if len(buf) < int(4 + desc_len + 16) do return nil
	buf = buf[4+desc_len+16:]

	if len(buf) < 4 do return nil
	pic_len := endian.unchecked_get_u32be(buf)

	if len(buf) < int(4 + pic_len) do return nil

	return slice.clone(buf[4 : 4+pic_len], context.temp_allocator)
}
