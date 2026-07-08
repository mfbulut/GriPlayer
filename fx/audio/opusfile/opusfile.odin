package opusfile

import "core:strings"

foreign import lib { "../libs/opusfile.lib", "../libs/opus.lib", "../libs/ogg.lib" }

File  :: struct {}
Tags :: struct {}

TRACK_GAIN :: 3008

@(link_prefix = "op_", default_calling_convention = "c")
foreign lib {
    @(link_name = "op_open_file")
    _open_file        :: proc(path: cstring, error: ^i32) -> ^File ---
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

open_file :: proc(path: string) -> ^File {
    c_path := strings.clone_to_cstring(path, context.temp_allocator)
    return _open_file(c_path, nil)
}
