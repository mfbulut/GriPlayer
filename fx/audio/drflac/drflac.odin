package drflac

import "core:sys/windows"

foreign import dr_libs "../libs/dr_libs.lib"

File :: struct {
    data: [4496]u8,
}

open_file :: proc(path: string) -> ^File {
    wpath := windows.utf8_to_wstring(path, context.temp_allocator)
    return open_file_w(cast([^]u16)wpath, nil)
}

@(link_prefix="drflac_", default_calling_convention="c")
foreign dr_libs {
    open_file_w :: proc(pFileName: [^]u16, pAllocationCallbacks: rawptr) -> ^File ---
    read_pcm_frames_f32 :: proc(pFlac: ^File, framesToRead: u64, pBufferOut: [^]f32) -> u64 ---
    seek_to_pcm_frame :: proc(pFlac: ^File, frameIndex: u64) -> b32 ---
    close :: proc(pFlac: ^File) ---
    get_channels :: proc(pFlac: ^File) -> u32 ---
    get_sampleRate :: proc(pFlac: ^File) -> u32 ---
    get_totalPCMFrameCount :: proc(pFlac: ^File) -> u64 ---
    get_currentPCMFrame :: proc(pFlac: ^File) -> u64 ---
}
