#+build windows
package audio

import "core:c"
import "core:sys/windows"

foreign import ucrt "system:libucrt.lib"

foreign ucrt {
	_wfopen :: proc(filename, mode: cstring16) -> ^c.FILE ---
}

// Win32's narrow fopen mangles non-ASCII paths; go through _wfopen instead.
vorbis_fopen :: proc(path: string) -> ^c.FILE {
	path_w := windows.utf8_to_wstring(path, context.temp_allocator)
	return _wfopen(path_w, "rb")
}
