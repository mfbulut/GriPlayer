package drmp3

import "core:sys/windows"

foreign import dr_libs "../libs/dr_libs.lib"

File :: struct {
    data: [32376]u8,
}

open_file :: proc(path: string) -> ^File {
    wpath := windows.utf8_to_wstring(path, context.temp_allocator)
    file := new(File)
    if init_file_w(file, cast([^]u16)wpath, nil) {
        return file
    }
    free(file)
    return nil
}

@(link_prefix="drmp3_", default_calling_convention="c")
foreign dr_libs {
    init_file_w :: proc(pMP3: ^File, pFilePath: [^]u16, pAllocationCallbacks: rawptr) -> b32 ---
    read_pcm_frames_f32 :: proc(pMP3: ^File, framesToRead: u64, pBufferOut: [^]f32) -> u64 ---
    seek_to_pcm_frame :: proc(pMP3: ^File, frameIndex: u64) -> b32 ---
    uninit :: proc(pMP3: ^File) ---
    get_pcm_frame_count :: proc(pMP3: ^File) -> u64 ---
    get_channels :: proc(pMP3: ^File) -> u32 ---
    get_sampleRate :: proc(pMP3: ^File) -> u32 ---
    get_currentPCMFrame :: proc(pMP3: ^File) -> u64 ---
}
