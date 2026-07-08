package audio

import "base:runtime"
import "core:os"
import "core:sys/windows"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:encoding/base64"
import "core:encoding/endian"

import "opusfile"
import "vorbisfile"
import "drmp3"
import "drflac"
import "drwav"

Metadata :: struct {
    title:    string,
    artist:   string,
    album:    string,
    track:    int,
    duration: f32,
}

metadata :: proc(path: string) -> Metadata {
    ext := strings.to_lower(os.ext(path), context.temp_allocator)

    switch ext {
    case ".ogg":
        meta, ok := parse_vorbis_metadata(path)
        if ok do return meta
        meta, ok = parse_opus_metadata(path)
        if ok do return meta
    case ".opus":
        meta, ok := parse_opus_metadata(path)
    case ".mp3":
        meta, ok := parse_mp3_metadata(path)
        if ok do return meta
    case ".flac":
        meta, ok := parse_flac_metadata(path)
        if ok do return meta
    case ".wav":
        meta, ok := parse_wav_metadata(path)
        if ok do return meta
    }

    return {}
}

cover :: proc(path: string) -> (cover: []byte) {
    ext := strings.to_lower(os.ext(path), context.temp_allocator)

    switch ext {
    case ".ogg":
        cover = parse_vorbis_cover(path)
        if cover != nil do return
        cover = parse_opus_cover(path)
    case ".opus":
        cover = parse_opus_cover(path)
    case ".mp3":
        cover = parse_mp3_cover(path)
    case ".flac":
        cover = parse_flac_cover(path)
    case ".wav":
    }

    return
}

parse_vorbis_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
    vf := vorbisfile.open_file(path)
    if vf == nil do return
    ok = true
    defer { vorbisfile.clear(vf); free(vf) }

    if pcm_tot := vorbisfile.pcm_total(vf, -1); pcm_tot > 0 {
        meta.duration = f32(pcm_tot) / 48000.0
    }

    tags := vorbisfile.comment(vf, -1)
    if tags == nil do return

    for i in 0..<tags.comments_count {
        comment := string(tags.comments[i][:tags.comment_lengths[i]])
        idx := strings.index_byte(comment, '=')
        if idx <= 0 do continue

        key := strings.to_upper(comment[:idx], context.temp_allocator)
        val := comment[idx+1:]

        if key == "TITLE" && meta.title == "" {
            meta.title = strings.clone(val)
        } else if key == "ALBUMARTIST" {
            meta.artist = strings.clone(val)
        } else if key == "ARTIST" && meta.artist == "" {
            meta.artist = strings.clone(val)
        } else if key == "ALBUM" && meta.album == "" {
            meta.album = strings.clone(val)
        } else if key == "TRACKNUMBER" && meta.track == 0 {
            if track_val, parsed := strconv.parse_int(val); parsed do meta.track = track_val
        }
    }

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

    tags := opusfile.tags(of, -1)
    if tags == nil do return

    if title := opusfile.tags_query(tags, "TITLE", 0); title != nil {
        meta.title = strings.clone(string(title))
    }
    if album_artist := opusfile.tags_query(tags, "ALBUMARTIST", 0); album_artist != nil {
        meta.artist = strings.clone(string(album_artist))
    } else if artist := opusfile.tags_query(tags, "ARTIST", 0); artist != nil {
        meta.artist = strings.clone(string(artist))
    }
    if album := opusfile.tags_query(tags, "ALBUM", 0); album != nil {
        meta.album = strings.clone(string(album))
    }
    if track_str := opusfile.tags_query(tags, "TRACKNUMBER", 0); track_str != nil {
        if val, parsed := strconv.parse_int(string(track_str)); parsed do meta.track = val
    }

    return
}

parse_vorbis_cover :: proc(path: string) -> []byte {
    vf := vorbisfile.open_file(path)
    if vf == nil do return nil
    defer { vorbisfile.clear(vf); free(vf) }

    tags := vorbisfile.comment(vf, -1)
    if tags == nil do return nil

    for i in 0..<tags.comments_count {
        comment := string(tags.comments[i][:tags.comment_lengths[i]])
        idx := strings.index_byte(comment, '=')
        if idx <= 0 do continue

        key := strings.to_upper(comment[:idx], context.temp_allocator)
        val := comment[idx+1:]

        if key != "METADATA_BLOCK_PICTURE" do continue

        decoded_buf, err := base64.decode(val, allocator = context.temp_allocator)
        if err != nil do return nil

        return parse_flac_picture(decoded_buf)
    }

    return nil
}

parse_opus_cover :: proc(path: string) -> []byte {
    of := opusfile.open_file(path)
    if of == nil do return nil
    defer opusfile.free(of)

    tags := opusfile.tags(of, -1)
    if tags == nil do return nil

    cover_base64 := opusfile.tags_query(tags, "METADATA_BLOCK_PICTURE", 0)
    if cover_base64 == nil do return nil

    decoded_buf, err := base64.decode(string(cover_base64), allocator = context.temp_allocator)
    if err != nil do return nil

    return parse_flac_picture(decoded_buf)
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

    return slice.clone(buf[4 : 4+pic_len])
}

parse_mp3_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil do return
    if len(data) < 10 || string(data[:3]) != "ID3" do return
    ok = true

    mp3 := new(drmp3.File)
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    if drmp3.init_file(mp3, cpath, nil) {
        meta.duration = f32(drmp3.get_pcm_frame_count(mp3)) / f32(drmp3.get_sampleRate(mp3))
        drmp3.uninit(mp3)
    }
    free(mp3)

    flags := data[5]
    size := (int(data[6]) << 21) | (int(data[7]) << 14) | (int(data[8]) << 7) | int(data[9])

    idx := 10
    if (flags & 0x40) != 0 {
        if idx + 4 > len(data) do return
        ext_size := (int(data[idx]) << 21) | (int(data[idx+1]) << 14) | (int(data[idx+2]) << 7) | int(data[idx+3])
        idx += ext_size
    }

    end := 10 + size
    if end > len(data) do end = len(data)

    for idx + 10 <= end {
        frame_id := string(data[idx:idx+4])
        if frame_id[0] == 0 do break

        version := data[3]
        frame_size := 0
        if version >= 4 {
            frame_size = (int(data[idx+4]) << 21) | (int(data[idx+5]) << 14) | (int(data[idx+6]) << 7) | int(data[idx+7])
        } else {
            frame_size = int(data[idx+4])<<24 | int(data[idx+5])<<16 | int(data[idx+6])<<8 | int(data[idx+7])
        }

        idx += 10
        if idx + frame_size > end do break

        frame_data := data[idx:idx+frame_size]

        if frame_id == "TIT2" && meta.title == "" {
            meta.title = parse_id3v2_text(frame_data)
        } else if frame_id == "TPE1" && meta.artist == "" {
            meta.artist = parse_id3v2_text(frame_data)
        } else if frame_id == "TALB" && meta.album == "" {
            meta.album = parse_id3v2_text(frame_data)
        } else if frame_id == "TRCK" && meta.track == 0 {
            trck := parse_id3v2_text(frame_data)
            slash_idx := strings.index_byte(trck, '/')
            if slash_idx > 0 {
                trck = trck[:slash_idx]
            }
            if val, parsed := strconv.parse_int(trck); parsed do meta.track = val
        }

        idx += frame_size
    }

    return
}

parse_mp3_cover :: proc(path: string) -> []byte {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil do return nil
    if len(data) < 10 || string(data[:3]) != "ID3" do return nil

    flags := data[5]
    size := (int(data[6]) << 21) | (int(data[7]) << 14) | (int(data[8]) << 7) | int(data[9])

    idx := 10
    if (flags & 0x40) != 0 {
        if idx + 4 > len(data) do return nil
        ext_size := (int(data[idx]) << 21) | (int(data[idx+1]) << 14) | (int(data[idx+2]) << 7) | int(data[idx+3])
        idx += ext_size
    }

    end := 10 + size
    if end > len(data) do end = len(data)

    for idx + 10 <= end {
        frame_id := string(data[idx:idx+4])
        if frame_id[0] == 0 do break

        version := data[3]
        frame_size := 0
        if version >= 4 {
            frame_size = (int(data[idx+4]) << 21) | (int(data[idx+5]) << 14) | (int(data[idx+6]) << 7) | int(data[idx+7])
        } else {
            frame_size = int(data[idx+4])<<24 | int(data[idx+5])<<16 | int(data[idx+6])<<8 | int(data[idx+7])
        }

        idx += 10
        if idx + frame_size > end do break

        frame_data := data[idx:idx+frame_size]

        if frame_id == "APIC" {
            for i in 0..<len(frame_data)-3 {
                if frame_data[i] == 0xFF && frame_data[i+1] == 0xD8 && frame_data[i+2] == 0xFF {
                    return slice.clone(frame_data[i:])
                }
                if frame_data[i] == 0x89 && frame_data[i+1] == 0x50 && frame_data[i+2] == 0x4E && frame_data[i+3] == 0x47 {
                    return slice.clone(frame_data[i:])
                }
            }
        }

        idx += frame_size
    }

    return nil
}

parse_id3v2_text :: proc(data: []byte) -> string {
    if len(data) < 2 do return ""
    str_data := data[1:]

    res := make([dynamic]byte, 0, len(str_data), context.temp_allocator)
    for b in str_data {
        if b != 0 {
            append(&res, b)
        }
    }
    return strings.clone(string(res[:]))
}

parse_flac_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil do return
    if len(data) < 4 || string(data[:4]) != "fLaC" do return
    ok = true

    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    flac := drflac.open_file(cpath, nil)
    if flac != nil {
        meta.duration = f32(drflac.get_totalPCMFrameCount(flac)) / f32(drflac.get_sampleRate(flac))
        drflac.close(flac)
    }

    idx := 4
    for idx < len(data) {
        header := data[idx]
        is_last := (header & 0x80) != 0
        block_type := header & 0x7F

        if idx + 4 > len(data) do break
        length := int(data[idx+1])<<16 | int(data[idx+2])<<8 | int(data[idx+3])
        idx += 4

        if idx + length > len(data) do break

        block_data := data[idx : idx+length]

        if block_type == 4 { // VORBIS_COMMENT
            if len(block_data) >= 4 {
                vendor_len := int(endian.unchecked_get_u32le(block_data[0:4]))
                offset := 4 + vendor_len
                if offset + 4 <= len(block_data) {
                    list_len := int(endian.unchecked_get_u32le(block_data[offset:offset+4]))
                    offset += 4

                    for _ in 0..<list_len {
                        if offset + 4 > len(block_data) do break
                        comment_len := int(endian.unchecked_get_u32le(block_data[offset:offset+4]))
                        offset += 4

                        if offset + comment_len > len(block_data) do break
                        comment := string(block_data[offset:offset+comment_len])
                        offset += comment_len

                        eq_idx := strings.index_byte(comment, '=')
                        if eq_idx > 0 {
                            key := strings.to_upper(comment[:eq_idx], context.temp_allocator)
                            val := comment[eq_idx+1:]

                            if key == "TITLE" && meta.title == "" {
                                meta.title = strings.clone(val)
                            } else if key == "ALBUMARTIST" {
                                meta.artist = strings.clone(val)
                            } else if key == "ARTIST" && meta.artist == "" {
                                meta.artist = strings.clone(val)
                            } else if key == "ALBUM" && meta.album == "" {
                                meta.album = strings.clone(val)
                            } else if key == "TRACKNUMBER" && meta.track == 0 {
                                if track_val, parsed := strconv.parse_int(val); parsed do meta.track = track_val
                            }
                        }
                    }
                }
            }
        }

        if is_last do break
        idx += length
    }

    return
}

parse_flac_cover :: proc(path: string) -> []byte {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil do return nil
    if len(data) < 4 || string(data[:4]) != "fLaC" do return nil

    idx := 4
    for idx < len(data) {
        header := data[idx]
        is_last := (header & 0x80) != 0
        block_type := header & 0x7F

        if idx + 4 > len(data) do break
        length := int(data[idx+1])<<16 | int(data[idx+2])<<8 | int(data[idx+3])
        idx += 4

        if idx + length > len(data) do break

        block_data := data[idx : idx+length]

        if block_type == 6 { // PICTURE
            return parse_flac_picture(block_data)
        }

        if is_last do break
        idx += length
    }

    return nil
}

parse_wav_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
    wav := new(drwav.File)
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    if drwav.init_file(wav, cpath, nil) {
        meta.duration = f32(drwav.get_totalPCMFrameCount(wav)) / f32(drwav.get_sampleRate(wav))
        ok = true
        drwav.uninit(wav)
    }
    free(wav)

    return
}