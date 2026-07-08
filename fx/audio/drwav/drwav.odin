package drwav

foreign import dr_libs "../libs/dr_libs.lib"

File :: struct {
    data: [408]u8,
}

@(link_prefix="drwav_", default_calling_convention="c")
foreign dr_libs {
    init_file :: proc(pWav: ^File, filename: cstring, pAllocationCallbacks: rawptr) -> b32 ---
    read_pcm_frames_f32 :: proc(pWav: ^File, framesToRead: u64, pBufferOut: [^]f32) -> u64 ---
    seek_to_pcm_frame :: proc(pWav: ^File, frameIndex: u64) -> b32 ---
    uninit :: proc(pWav: ^File) ---
    get_channels :: proc(pWav: ^File) -> u32 ---
    get_sampleRate :: proc(pWav: ^File) -> u32 ---
    get_totalPCMFrameCount :: proc(pWav: ^File) -> u64 ---
    get_currentPCMFrame :: proc(pWav: ^File) -> u64 ---
}
