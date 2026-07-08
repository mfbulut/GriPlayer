package audio

import "core:slice"
import "core:strings"
import "core:strconv"
import "core:encoding/base64"
import "core:encoding/endian"

import "opusfile"
import "vorbisfile"

Metadata :: struct {
    title: string,
    artist: string,
    album: string,
    track: int,
    duration: f32,
}

metadata :: proc(path: string) -> (meta: Metadata) {
    if strings.has_suffix(path, ".ogg") {
        if vf := vorbisfile.open_file(path); vf != nil {
            defer { vorbisfile.clear(vf); free(vf) }

            tags := vorbisfile.comment(vf, -1)
            if tags != nil {
                comments_arr := cast([^]cstring)tags.user_comments
                lengths_arr := cast([^]i32)tags.comment_lengths

                album_artist_found := false

                for i in 0..<tags.comments {
                    comment_str := string(slice.from_ptr(cast(^u8)comments_arr[i], int(lengths_arr[i])))
                    idx := strings.index_byte(comment_str, '=')
                    if idx > 0 {
                        key := strings.to_upper(comment_str[:idx], context.temp_allocator)
                        val := comment_str[idx+1:]

                        if key == "TITLE" && meta.title == "" {
                            meta.title = strings.clone(val)
                        } else if key == "ALBUMARTIST" {
                            meta.artist = strings.clone(val)
                            album_artist_found = true
                        } else if key == "ARTIST" && !album_artist_found {
                            meta.artist = strings.clone(val)
                        } else if key == "ALBUM" && meta.album == "" {
                            meta.album = strings.clone(val)
                        } else if key == "TRACKNUMBER" && meta.track == 0 {
                            if track_val, parsed := strconv.parse_int(val); parsed do meta.track = track_val
                        }
                    }
                }
            }

            if pcm_tot := vorbisfile.pcm_total(vf, -1); pcm_tot > 0 {
                meta.duration = f32(pcm_tot) / 48000.0
            }
            return
        }
    }

    of := opusfile.open_file(path)
    if of == nil {
        return
    }
    defer opusfile.free(of)

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

    if pcm_tot := opusfile.pcm_total(of, -1); pcm_tot > 0 {
        meta.duration = f32(pcm_tot) / 48000.0
    }

    return
}

cover :: proc(path: string) -> []byte {
    if strings.has_suffix(path, ".ogg") {
        if vf := vorbisfile.open_file(path); vf != nil {
            defer { vorbisfile.clear(vf); free(vf) }

            tags := vorbisfile.comment(vf, -1)
            if tags != nil {
                comments_arr := cast([^]cstring)tags.user_comments
                lengths_arr := cast([^]i32)tags.comment_lengths

                for i in 0..<tags.comments {
                    comment_str := string(slice.from_ptr(cast(^u8)comments_arr[i], int(lengths_arr[i])))
                    idx := strings.index_byte(comment_str, '=')
                    if idx > 0 {
                        key := strings.to_upper(comment_str[:idx], context.temp_allocator)
                        if key == "METADATA_BLOCK_PICTURE" {
                            val := comment_str[idx+1:]
                            decoded_buf, err := base64.decode(val, allocator = context.temp_allocator)
                            if err == nil {
                                buf := decoded_buf[4:]
                                mime_len := endian.unchecked_get_u32be(buf)
                                buf = buf[4+mime_len:]
                                desc_len := endian.unchecked_get_u32be(buf)
                                buf = buf[4+desc_len+16:]
                                pic_len := endian.unchecked_get_u32be(buf)
                                return slice.clone(buf[4 : 4+pic_len])
                            }
                        }
                    }
                }
            }
            return nil
        }
    }

    of := opusfile.open_file(path)
    if of == nil {
        return nil
    }
    defer opusfile.free(of)

    tags := opusfile.tags(of, -1)
    if tags == nil do return nil

    cover_base64 := opusfile.tags_query(tags, "METADATA_BLOCK_PICTURE", 0)
    if cover_base64 == nil do return nil

    decoded_buf, base64_err := base64.decode(string(cover_base64), allocator = context.temp_allocator)
    if base64_err != nil do return nil

    buf := decoded_buf[4:]
    mime_len := endian.unchecked_get_u32be(buf)
    buf = buf[4+mime_len:]
    desc_len := endian.unchecked_get_u32be(buf)
    buf = buf[4+desc_len+16:]
    pic_len := endian.unchecked_get_u32be(buf)
    return slice.clone(buf[4 : 4+pic_len])
}