package main

import "core:container/bit_array"
import "core:encoding/cbor"
import "core:hash/xxhash"

import "core:os"
import "core:time"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode"

import "core:thread"
import "core:sync"

import "fx"
import "fx/audio"
import "vendor:stb/image"

Lyric :: struct {
	text: string,
	time: f32,
}

Music :: struct {
	fullpath:         string,
	title:            string,
	artist:           string,
	album:            string,
	track:            int,
	playtime:         f32,
	duration:         f32,
	liked:            bool,
	liked_timestamp:  time.Time,
	lyrics:           [dynamic]Lyric,
	lyrics_filter:    bit_array.Bit_Array,
	thumbnail_pixels: []fx.Color,
	thumbnail:        fx.Texture `cbor:"-"`,
}

Playlist :: struct {
	name:  string,
	songs: [dynamic]^Music,
}

playlists: [dynamic]Playlist

loading_mutex: sync.Mutex
loaded_songs_queue: [dynamic]^Music

loader_start :: proc() {
	append(&playlists, Playlist{ name = "Liked" })

	thread.create_and_start(proc() {
		music_dir := os.user_music_dir(context.temp_allocator) or_else panic("Failed to find music dir")

		cache_load()

		w := os.walker_create(music_dir)
		defer os.walker_destroy(&w)

		for info in os.walker_walk(&w) {
			if strings.starts_with(info.fullpath, ".") {
				os.walker_skip_dir(&w)
				continue
			}

			ext := strings.to_lower(os.ext(info.fullpath), context.temp_allocator)
			if ext != ".opus" && ext != ".ogg" && ext != ".mp3" && ext != ".flac" && ext != ".wav" {
				continue
			}

			music := load_music(info.fullpath)

			sync.guard(&loading_mutex)
			append(&loaded_songs_queue, music)
		}
	}, self_cleanup = true)
}

loader_poll :: proc() {
	sync.lock(&loading_mutex)
	queue := slice.clone(loaded_songs_queue[:])
	clear(&loaded_songs_queue)
	sync.unlock(&loading_mutex)

	if len(queue) == 0 do return

	next: for music in queue {
		if len(music.thumbnail_pixels) > 0 {
			music.thumbnail = fx.texture_load_raw(music.thumbnail_pixels, 64, 64, false)
		}

		playlist_name := os.base(os.dir(music.fullpath))

		if music.liked {
			append(&playlists[0].songs, music)
		}

		for &playlist in playlists[1:] {
			if playlist.name == playlist_name {
				append(&playlist.songs, music)
				continue next
			}
		}

		append(&playlists, Playlist{name = playlist_name})
		append(&playlists[len(playlists) - 1].songs, music)
	}

	slice.sort_by(playlists[0].songs[:], proc(i, j: ^Music) -> bool {
		return time.diff(j.liked_timestamp, i.liked_timestamp) > 0
	})

	search.initialized = false

	delete(queue)
}

load_music :: proc(fullpath: string) -> ^Music {
	music := new(Music)
	music.fullpath = strings.clone(fullpath)

	if cached, found := cache.songs[music.fullpath]; found {
		music^ = cached
	} else {
		if meta, ok := audio.metadata(music.fullpath); ok {
			music.title = meta.title
			music.artist = meta.artist
			music.album = meta.album
			music.track = meta.track
			music.duration = meta.duration
		}

		if music.title == "" {
			music.title = os.stem(music.fullpath)
		}

		load_lrc(music)
		load_thumbnail(music)
	}

	free_all(context.temp_allocator)

	return music
}

load_lrc :: proc(music: ^Music) {
	stem := os.stem(music.fullpath)
	dir := os.dir(music.fullpath)

	lrc_path := strings.concatenate({dir, "\\", stem, ".lrc"}, context.temp_allocator)
	data, err := os.read_entire_file(lrc_path, context.allocator)
	if err != nil {
		return
	}

	bit_array.init(&music.lyrics_filter, 32768)

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		text := strings.trim_space(line)
		(len(text) > 0) or_continue

		open_bracket := strings.index(text, "[")
		(open_bracket != -1) or_continue
		close_bracket := strings.index(text, "]")
		(close_bracket != -1) or_continue

		tag := text[open_bracket + 1:close_bracket]
		lyric := text[close_bracket + 1:]

		colon_index := strings.index(tag, ":")
		(colon_index != -1) or_continue

		mins := strconv.parse_f32(tag[:colon_index]) or_continue
		secs := strconv.parse_f32(tag[colon_index + 1:]) or_continue
		append(&music.lyrics, Lyric{text = lyric, time = mins * 60 + secs})

		lower_lyric := strings.to_lower(text, context.temp_allocator)
		runes := make([dynamic]rune, 0, len(lyric), context.temp_allocator)
		for r in lower_lyric {
			if unicode.is_letter(r) || unicode.is_digit(r) {
				append(&runes, r)
			}
		}

		for i in 0..=len(runes)-5 {
			bytes := slice.reinterpret([]byte, runes[i:i + 5])
			hash := xxhash.XXH32(bytes)
			bit_array.set(&music.lyrics_filter, uint(hash & 32767))
		}
	}
}

load_thumbnail :: proc(music: ^Music) {
	cover_bytes := audio.cover(music.fullpath)
	if cover_bytes == nil do return
	defer delete(cover_bytes)

	if len(cover_bytes) == 0 do return

	w, h, channels: i32
	pixels := image.load_from_memory(raw_data(cover_bytes), cast(i32)len(cover_bytes), &w, &h, &channels, 4)

	if pixels == nil do return
	defer image.image_free(pixels)

	music.thumbnail_pixels = make([]fx.Color, 64 * 64)
	success := image.resize_uint8(pixels, w, h, 0, cast([^]u8)raw_data(music.thumbnail_pixels), 64, 64, 0, 4)

	if success == 0 {
		delete(music.thumbnail_pixels)
		music.thumbnail_pixels = nil
		return
	}
}

toggle_like :: proc(song: ^Music) {
	liked_playlist := &playlists[0]

	if !song.liked {
		song.liked = true
		song.liked_timestamp = time.now()
		inject_at(&liked_playlist.songs, 0, song)
	} else {
		song.liked = false
		for unliked_song, i in liked_playlist.songs {
			if unliked_song == song {
				ordered_remove(&liked_playlist.songs, i)
				break
			}
		}
	}
}

cache: struct {
	volume: f32,
	songs: map[string]Music,
}

cache_load :: proc() {
	dir, err := os.user_data_dir(context.temp_allocator)
	if err != nil do return

	save_path := strings.concatenate({dir, "\\fmusic\\cache.cbor"}, context.temp_allocator)

	data, read_err := os.read_entire_file(save_path, context.temp_allocator);
	if read_err != nil do return

	unmarshal_err := cbor.unmarshal(data, &cache, {.Trusted_Input})
	if unmarshal_err != nil do return

	audio.volume = cache.volume
}

cache_save :: proc() {
	dir, err := os.user_data_dir(context.temp_allocator)
	if err != nil do return

	fmusic_dir := strings.concatenate({dir, "\\fmusic"})
	os.make_directory(fmusic_dir)
	save_path := strings.concatenate({fmusic_dir, "\\cache.cbor"})

	cache.volume = audio.volume
	cache.songs = make(map[string]Music, 1024)

	for playlist in playlists[1:] {
		for m in playlist.songs {
			cache.songs[m.fullpath] = m^
		}
	}

	bytes, marshal_err := cbor.marshal(cache)
	if marshal_err == nil {
		_ = os.write_entire_file(save_path, bytes)
	}
}