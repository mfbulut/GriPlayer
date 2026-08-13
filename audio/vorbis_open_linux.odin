#+build linux
package audio

import "core:c"
import "core:strings"
import "vendor:stb/vorbis"

foreign import libc "system:c"

foreign libc {
	fopen :: proc(filename, mode: cstring) -> ^c.FILE ---
}

// Linux fopen is UTF-8 native, no wide-char shim needed.
vorbis_fopen :: proc(path: string) -> ^vorbis.vorbis {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	f := fopen(c_path, "rb")
	if f == nil do return nil
	return vorbis.open_file(f, true, nil, nil)
}

