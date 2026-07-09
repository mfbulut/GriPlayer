package vorbisfile

import "core:strings"
import "core:sys/windows"

foreign import lib { "../libs/vorbisfile.lib", "../libs/vorbis.lib", "../libs/ogg.lib" }

File :: struct {
    _pad: [2048]u8,
}

Info :: struct {
    version: i32,
    channels: i32,
    rate: i64,
    bitrate_upper: i64,
    bitrate_nominal: i64,
    bitrate_lower: i64,
    bitrate_window: i64,
    codec_setup: rawptr,
}

Comment :: struct {
    comments: [^][^]u8,
    comment_lengths: [^]i32,
    comments_count: i32,
    vendor: cstring,
}

@(link_prefix = "ov_", default_calling_convention = "c")
foreign lib {
    fopen          :: proc(path: cstring, vf: ^File) -> i32 ---
    clear          :: proc(vf: ^File) -> i32 ---
    read_float     :: proc(vf: ^File, pcm_channels: ^[^][^]f32, samples: i32, bitstream: ^i32) -> i32 ---
    pcm_total      :: proc(vf: ^File, i: i32) -> i64 ---
    pcm_seek       :: proc(vf: ^File, pos: i64) -> i32 ---
    pcm_tell       :: proc(vf: ^File) -> i64 ---
    info           :: proc(vf: ^File, link: i32) -> ^Info ---
    comment        :: proc(vf: ^File, link: i32) -> ^Comment ---
}

open_file :: proc(path: string) -> ^File {
    c_path := strings.clone_to_cstring(path, context.temp_allocator)

    // vorbisfile doesnt support UTF-8 for filepath
    wpath := windows.utf8_to_wstring(path, context.temp_allocator)
    short_path_len := windows.GetShortPathNameW(wpath, nil, 0)
    if short_path_len > 0 {
        short_path_buf := make([]u16, short_path_len, context.temp_allocator)
        windows.GetShortPathNameW(wpath, cast(windows.wstring)raw_data(short_path_buf), short_path_len)
        short_path_utf8, _ := windows.wstring_to_utf8(cast(windows.wstring)raw_data(short_path_buf), int(short_path_len), context.temp_allocator)
        c_path = strings.clone_to_cstring(short_path_utf8, context.temp_allocator)
    }

    vf := new(File)
    if fopen(c_path, vf) != 0 {
        free(vf)
        return nil
    }

    return vf
}
