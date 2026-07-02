package opusfile

foreign import lib "opusfile.lib"

OggOpusFile  :: struct {}
OpusTags :: struct {}

TRACK_GAIN :: 3008

@(link_prefix = "op_", default_calling_convention = "c")
foreign lib {
    open_file         :: proc(path: cstring, error: ^i32) -> ^OggOpusFile  ---
    free              :: proc(file: ^OggOpusFile ) ---
    read_float_stereo :: proc(file: ^OggOpusFile , samples: [^]f32, sample_count: i32) -> i32 ---
    set_gain_offset   :: proc(file: ^OggOpusFile , gain_type: i32, gain_offset_q8: i32) -> i32 ---
    pcm_total         :: proc(file: ^OggOpusFile , link_index: i32) -> i64 ---
    pcm_seek          :: proc(file: ^OggOpusFile , pcm_offset: i64) -> i32 ---
    pcm_tell          :: proc(file: ^OggOpusFile ) -> i64 ---
    tags              :: proc(file: ^OggOpusFile , link_index: i32) -> ^OpusTags ---

    @(link_name = "opus_tags_query")
    tags_query :: proc(tags: ^OpusTags, key: cstring, index: i32) -> cstring ---
}
