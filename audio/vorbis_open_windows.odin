#+build windows
package audio

import "core:c"
import "core:sys/windows"
import "vendor:stb/vorbis"

foreign import ucrt "system:libucrt.lib"

foreign ucrt {
	_wfopen :: proc(filename, mode: cstring16) -> ^c.FILE ---
}

// Win32's narrow fopen mangles non-ASCII paths; go through _wfopen instead.
vorbis_fopen :: proc(path: string) -> ^vorbis.vorbis {
	path_w := windows.utf8_to_wstring(path, context.temp_allocator)
	f := _wfopen(path_w, "rb")
	if f == nil do return nil
	return vorbis.open_file(f, true, nil, nil)
}

