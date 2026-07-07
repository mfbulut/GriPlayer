package opusfile

import "core:os"
import "core:io"
import "core:slice"

foreign import lib { "../libs/opusfile.lib", "../libs/opus.lib", "../libs/ogg.lib" }

File  :: struct {}
Tags :: struct {}

TRACK_GAIN :: 3008

@(link_prefix = "op_", default_calling_convention = "c")
foreign lib {
    open_callbacks :: proc(stream: rawptr, cb: ^Callbacks, initial_data: [^]u8, initial_bytes: uint, error: ^i32) -> ^File ---
    free              :: proc(file: ^File ) ---
    read_float_stereo :: proc(file: ^File , samples: [^]f32, sample_count: i32) -> i32 ---
    set_gain_offset   :: proc(file: ^File , gain_type: i32, gain_offset_q8: i32) -> i32 ---
    pcm_total         :: proc(file: ^File , link_index: i32) -> i64 ---
    pcm_seek          :: proc(file: ^File , pcm_offset: i64) -> i32 ---
    pcm_tell          :: proc(file: ^File ) -> i64 ---
    tags              :: proc(file: ^File , link_index: i32) -> ^Tags ---

    @(link_name = "opus_tags_query")
    tags_query :: proc(tags: ^Tags, key: cstring, index: i32) -> cstring ---
}

Callbacks :: struct {
    read:  proc "c" (stream: rawptr, ptr: [^]u8, nbytes: i32) -> i32,
    seek:  proc "c" (stream: rawptr, offset: i64, whence: i32) -> i32,
    tell:  proc "c" (stream: rawptr) -> i64,
    close: proc "c" (stream: rawptr) -> i32,
}

callbacks: Callbacks = {
    read = proc "c" (stream: rawptr, ptr: [^]u8, nbytes: i32) -> i32 {
        context = {}
        handle := cast(^os.File)stream
        data := slice.from_ptr(ptr, int(nbytes))
        n, err := os.read(handle, data)
        if err != nil do return -1
        return cast(i32)n
    },
    seek = proc "c" (stream: rawptr, offset: i64, whence: i32) -> i32 {
        context = {}
        handle := cast(^os.File)stream
        _, err := os.seek(handle, offset, io.Seek_From(whence))
        if err != nil do return -1
        return 0
    },
    tell = proc "c" (stream: rawptr) -> i64 {
        context = {}
        handle := cast(^os.File)stream
        pos, err := os.seek(handle, 0, .Current)
        if err != nil do return -1
        return pos
    },
    close = proc "c" (stream: rawptr) -> i32 {
        context = {}
        handle := cast(^os.File)stream
        os.close(handle)
        return 0
    },
}

open_file :: proc(path: string) -> ^File {
    handle, err := os.open(path)
    if err != nil do return nil
    stream := cast(rawptr)handle

    of := open_callbacks(stream, &callbacks, nil, 0, nil)
    if of == nil {
        os.close(handle)
        return nil
    }

    return of
}
