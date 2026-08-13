#+build linux
package audio

import "core:c"
import "core:strings"

foreign import libc "system:c"

foreign libc {
	fopen :: proc(filename, mode: cstring) -> ^c.FILE ---
}

// Linux fopen is UTF-8 native, no wide-char shim needed.
vorbis_fopen :: proc(path: string) -> ^c.FILE {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	return fopen(c_path, "rb")
}
