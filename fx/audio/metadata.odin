package audio

import "core:os"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:encoding/base64"
import "core:encoding/endian"

import "opusfile"
import "vorbisfile"

Metadata :: struct {
    title:    string,
    artist:   string,
    album:    string,
    track:    int,
    duration: f32,
}

metadata :: proc(path: string) -> Metadata {
    ext := strings.to_lower(os.ext(path), context.temp_allocator)

    if ext == ".ogg" {
        meta, ok := parse_vorbis_metadata(path)
        if ok do return meta
        meta, ok = parse_opus_metadata(path)
        return meta
    } else if ext == ".opus" {
        meta, ok := parse_opus_metadata(path)
        return meta
    }

    return {}
}

cover :: proc(path: string) -> []byte {
    ext := strings.to_lower(os.ext(path), context.temp_allocator)

    if ext == ".ogg" {
        if c := parse_vorbis_cover(path); c != nil {
            return c
        }
        return parse_opus_cover(path)
    } else if ext == ".opus" {
        return parse_opus_cover(path)
    }

    return {}
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

        return parse_flac_picture(val)
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

    return parse_flac_picture(string(cover_base64))
}

parse_flac_picture :: proc(base64_str: string) -> []byte {
    decoded_buf, err := base64.decode(base64_str, allocator = context.temp_allocator)
    if err != nil do return nil

    if len(decoded_buf) < 32 do return nil

    buf := decoded_buf[4:]
    mime_len := endian.unchecked_get_u32be(buf)
    buf = buf[4+mime_len:]
    desc_len := endian.unchecked_get_u32be(buf)
    buf = buf[4+desc_len+16:]
    pic_len := endian.unchecked_get_u32be(buf)

    if len(buf) < int(4 + pic_len) do return nil

    return slice.clone(buf[4 : 4+pic_len])
}