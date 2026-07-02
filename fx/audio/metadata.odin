package audio

import "core:slice"
import "core:strings"
import "core:strconv"
import "core:encoding/base64"
import "core:encoding/endian"

import "opusfile"

Metadata :: struct {
    title: string,
    artist: string,
    album: string,
    track: int,
    duration: f32,
}

metadata :: proc(path: string) -> (meta: Metadata) {
    c_str := strings.clone_to_cstring(path, context.temp_allocator)
    of := opusfile.open_file(c_str, nil)
    if of == nil do return
    defer opusfile.free(of)

    tags := opusfile.tags(of, -1)

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

    if pcm_tot := opusfile.pcm_total(of, -1); pcm_tot > 0 {
        meta.duration = f32(pcm_tot) / 48000.0
    }

    return
}

cover :: proc(path: string) -> []byte {
    c_str := strings.clone_to_cstring(path, context.temp_allocator)
    of := opusfile.open_file(c_str, nil)
    if of == nil do return nil
    defer opusfile.free(of)

    tags := opusfile.tags(of, -1)
    if tags == nil do return nil

    cover_base64 := opusfile.tags_query(tags, "METADATA_BLOCK_PICTURE", 0)
    if cover_base64 == nil do return nil

    decoded_buf, err := base64.decode(string(cover_base64), allocator = context.temp_allocator)
    if err != nil do return nil

    buf := decoded_buf[4:]
    mime_len := endian.unchecked_get_u32be(buf)
    buf = buf[4+mime_len:]
    desc_len := endian.unchecked_get_u32be(buf)
    buf = buf[4+desc_len+16:]
    pic_len := endian.unchecked_get_u32be(buf)
    return slice.clone(buf[4 : 4+pic_len])
}