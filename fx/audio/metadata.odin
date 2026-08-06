package audio

import "core:os"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:encoding/base64"
import "core:encoding/endian"

import "flac"
import "opusfile"
import "vendor:stb/vorbis"

Metadata :: struct {
	title:    string,
	artist:   string,
	album:    string,
	track:    int,
	duration: f32,
	cover:    []byte,
}

metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
    ext := strings.to_lower(os.ext(path), context.temp_allocator)

	switch ext {
	case ".ogg":
		meta, ok = parse_vorbis_metadata(path)
		if ok do return
		meta, ok = parse_opus_metadata(path)
	case ".opus":
		meta, ok = parse_opus_metadata(path)
	case ".flac":
		meta, ok = parse_flac_metadata(path)
	}

	return
}

parse_tags :: proc(tags: []string, meta: ^Metadata) {
	for comment in tags {
		idx := strings.index_byte(comment, '=')
		if idx <= 0 do continue
		key := strings.to_upper(comment[:idx], context.temp_allocator)
		val := comment[idx+1:]

		switch key {
		case "TITLE":
			meta.title = strings.clone(val, context.temp_allocator)
		case "ALBUMARTIST":
			meta.artist = strings.clone(val, context.temp_allocator)
		case "ARTIST":
			if meta.artist == "" {
				meta.artist = strings.clone(val, context.temp_allocator)
			}
		case "ALBUM":
			meta.album = strings.clone(val, context.temp_allocator)
		case "TRACKNUMBER", "TRACK":
			meta.track = strconv.parse_int(val) or_continue
		case "METADATA_BLOCK_PICTURE":
			clean_val := strings.trim_space(val)
			if decoded_buf, err := base64.decode(clean_val, allocator = context.temp_allocator); err == nil {
				fake_file := flac.File{data = decoded_buf}
				if flac.parse_picture(&fake_file) {
					meta.cover = fake_file.cover
				}
			}
		}
	}
}

parse_vorbis_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	vf := open_vorbis_file(path)
	if vf == nil do return
	defer vorbis.close(vf)
	ok = true

	info := vorbis.get_info(vf)
	if pcm_tot := vorbis.stream_length_in_samples(vf); pcm_tot > 0 && info.sample_rate > 0 {
		meta.duration = f32(pcm_tot) / f32(info.sample_rate)
	}

	vc := vorbis.get_comment(vf)
	tags := make([]string, vc.comment_list_length, context.temp_allocator)

	for i in 0..<vc.comment_list_length {
		tags[i] = string(vc.comment_list[i])
	}

	parse_tags(tags, &meta)

	return
}

parse_opus_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	of := opusfile.open_file(path)
	if of == nil do return
	defer opusfile.free(of)
	ok = true

	if pcm_tot := opusfile.pcm_total(of, -1); pcm_tot > 0 {
		meta.duration = f32(pcm_tot) / 48000.0
	}

    tags := opusfile.tags(of, 0)
    comments := make([]string, tags.comment_count, context.temp_allocator)

    for &c, i in comments {
        len := tags.comment_lengths[i]
        c = string(tags.user_comments[i][:len])
    }

	parse_tags(comments, &meta)

	return
}

parse_flac_metadata :: proc(path: string) -> (meta: Metadata, ok: bool) {
	f := flac.open_file(path)
	if f == nil do return
	defer flac.destroy(f)

	ok = true
	if f.info.sample_rate > 0 {
		meta.duration = f32(f.info.sample_count) / f32(f.info.sample_rate)
	}

	parse_tags(f.tags.comments, &meta)

	if len(f.cover) > 0 {
		meta.cover = slice.clone(f.cover, context.temp_allocator)
	}

	return
}

parse_flac_picture :: proc(block_data: []byte) -> []byte {
	if len(block_data) < 32 do return nil

	buf := block_data[4:]
	mime_len := endian.unchecked_get_u32be(buf)
	if len(buf) < int(4 + mime_len) do return nil
	buf = buf[4+mime_len:]

	if len(buf) < 4 do return nil
	desc_len := endian.unchecked_get_u32be(buf)
	if len(buf) < int(4 + desc_len + 16) do return nil
	buf = buf[4+desc_len+16:]

	if len(buf) < 4 do return nil
	pic_len := endian.unchecked_get_u32be(buf)
	if len(buf) < int(4 + pic_len) do return nil

	return slice.clone(buf[4 : 4+pic_len], context.temp_allocator)
}