package drmp3

import "core:c"

foreign import dr_libs "../libs/dr_libs.lib"

File :: struct {
    data: [32376]u8,
}

@(link_prefix="drmp3_", default_calling_convention="c")
foreign dr_libs {
    init_file :: proc(pMP3: ^File, pFilePath: cstring, pAllocationCallbacks: rawptr) -> b32 ---
    read_pcm_frames_f32 :: proc(pMP3: ^File, framesToRead: u64, pBufferOut: [^]f32) -> u64 ---
    seek_to_pcm_frame :: proc(pMP3: ^File, frameIndex: u64) -> b32 ---
    uninit :: proc(pMP3: ^File) ---
    get_pcm_frame_count :: proc(pMP3: ^File) -> u64 ---
    get_channels :: proc(pMP3: ^File) -> u32 ---
    get_sampleRate :: proc(pMP3: ^File) -> u32 ---
    get_currentPCMFrame :: proc(pMP3: ^File) -> u64 ---
}
