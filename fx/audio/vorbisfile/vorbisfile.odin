package vorbisfile

import "core:os"
import "core:io"
import "core:slice"

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
    user_comments: ^cstring,
    comment_lengths: ^i32,
    comments: i32,
    vendor: cstring,
}

@(link_prefix = "ov_", default_calling_convention = "c")
foreign lib {
    open_callbacks :: proc(datasource: rawptr, vf: ^File, initial: cstring, ibytes: i32, callbacks: Callbacks) -> i32 ---
    clear          :: proc(vf: ^File) -> i32 ---
    read_float     :: proc(vf: ^File, pcm_channels: ^[^][^]f32, samples: i32, bitstream: ^i32) -> i32 ---
    pcm_total      :: proc(vf: ^File, i: i32) -> i64 ---
    pcm_seek       :: proc(vf: ^File, pos: i64) -> i32 ---
    pcm_tell       :: proc(vf: ^File) -> i64 ---
    info           :: proc(vf: ^File, link: i32) -> ^Info ---
    comment        :: proc(vf: ^File, link: i32) -> ^Comment ---
}

Callbacks :: struct {
    read:  proc "c" (ptr: rawptr, size: uint, nmemb: uint, datasource: rawptr) -> uint,
    seek:  proc "c" (datasource: rawptr, offset: i64, whence: i32) -> i32,
    close: proc "c" (datasource: rawptr) -> i32,
    tell:  proc "c" (datasource: rawptr) -> i32,
}

callbacks: Callbacks = {
    read = proc "c" (ptr: rawptr, size: uint, nmemb: uint, datasource: rawptr) -> uint {
        context = {}
        if size == 0 || nmemb == 0 do return 0
        handle := cast(^os.File)datasource
        total_bytes := size * nmemb
        data := slice.from_ptr(cast([^]u8)ptr, int(total_bytes))
        n, err := os.read(handle, data)
        if err != nil do return 0
        return cast(uint)n / size
    },
    seek = proc "c" (datasource: rawptr, offset: i64, whence: i32) -> i32 {
        context = {}
        handle := cast(^os.File)datasource
        _, err := os.seek(handle, offset, io.Seek_From(whence))
        if err != nil do return -1
        return 0
    },
    close = proc "c" (datasource: rawptr) -> i32 {
        context = {}
        handle := cast(^os.File)datasource
        os.close(handle)
        return 0
    },
    tell = proc "c" (datasource: rawptr) -> i32 {
        context = {}
        handle := cast(^os.File)datasource
        pos, err := os.seek(handle, 0, .Current)
        if err != nil do return -1
        return cast(i32)pos
    },
}

open_file :: proc(path: string, vf: ^File) -> bool {
    handle, os_err := os.open(path)
    if os_err != nil do return false
    stream := cast(rawptr)handle

    err := open_callbacks(stream, vf, nil, 0, callbacks)
    if err != 0 {
        os.close(handle)
        return false
    }

    return true
}
