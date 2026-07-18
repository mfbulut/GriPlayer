package main

import "core:container/bit_array"
import "core:encoding/cbor"
import "core:hash/xxhash"

import "core:os"
import "core:fmt"
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
	last_timestamp:   time.Time,
	lyrics:           [dynamic]Lyric,
	lyrics_filter:    bit_array.Bit_Array,
	thumbnail_pixels: []fx.Color,
	thumbnail:        fx.Texture `cbor:"-"`,
}

Playlist :: struct {
	name:          string,
	songs:         [dynamic]^Music,
	icon:          ^fx.Texture,
	sort:          Playlist_Sort,
	sort_reversed: bool,
}

Playlist_Sort :: enum {
	Title,
	Artist,
	Album,
	Track,
	Duration,
	Playtime,
	Last_Listened,
	Liked_Time,
}

PLAYLIST_SORT_LABELS := [Playlist_Sort]string{
	.Title = "Title",
	.Artist = "Artist",
	.Album = "Album",
	.Track = "Track Index",
	.Duration = "Duration",
	.Playtime = "Playtime",
	.Last_Listened = "Last Listened",
	.Liked_Time = "Liked",
}

LIKED_PLAYLIST_INDEX   :: 0
HISTORY_PLAYLIST_INDEX :: 1
LIBRARY_PLAYLIST_START :: 2

playlists: [dynamic]Playlist

loader_queue: [dynamic]^Music
loader_mutex: sync.Mutex
loading_finished: bool

loader_start :: proc() {
	append(&playlists, Playlist{
		name = "Liked",
		icon = &icons[.Heart],
		sort = .Liked_Time,
	})

	append(&playlists, Playlist{
		name = "History",
		icon = &icons[.History],
		sort = .Last_Listened,
	})

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

			sync.guard(&loader_mutex)
			append(&loader_queue, music)
		}

		sync.lock(&loader_mutex)
		loading_finished = true
		sync.unlock(&loader_mutex)
	}, self_cleanup = true)
}

loader_is_fully_loaded :: proc() -> bool {
	sync.lock(&loader_mutex)
	fully_loaded := loading_finished && len(loader_queue) == 0
	sync.unlock(&loader_mutex)
	return fully_loaded
}

loader_poll :: proc() {
	sync.lock(&loader_mutex)
	queue := slice.clone(loader_queue[:])
	defer delete(queue)

	clear(&loader_queue)
	sync.unlock(&loader_mutex)

	if len(queue) == 0 {
		return
	}

	next: for music in queue {
		if len(music.thumbnail_pixels) > 0 {
			music.thumbnail = fx.texture_load_raw(music.thumbnail_pixels, 64, 64, false)
		}

		playlist_name := os.base(os.dir(music.fullpath))

		if music.liked {
			append(&playlists[LIKED_PLAYLIST_INDEX].songs, music)
		}
		if time.to_unix_nanoseconds(music.last_timestamp) > 0 {
			append(&playlists[HISTORY_PLAYLIST_INDEX].songs, music)
		}

		for &playlist in playlists[LIBRARY_PLAYLIST_START:] {
			if playlist.name == playlist_name {
				append(&playlist.songs, music)
				continue next
			}
		}

		append(&playlists, Playlist{name = playlist_name, sort = .Title})
		append(&playlists[len(playlists) - 1].songs, music)
	}

	search.initialized = false

	next_playlist: for &playlist in playlists[LIBRARY_PLAYLIST_START:] {
		if len(playlist.songs) < 2 do continue
		album := playlist.songs[0].album
		if album == "" do continue

		for song in playlist.songs[1:] {
			if song.album != album {
				continue next_playlist
			}
		}

		playlist.sort = .Track
	}

	for &playlist in playlists {
		playlist_sort(&playlist)
	}
}

playlist_sort :: proc(playlist: ^Playlist) {
	switch playlist.sort {
	case .Title:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			return strings.compare(a.title, b.title) == -1
		})
	case .Artist:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			return strings.compare(a.artist, b.artist) == -1
		})
	case .Album:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			return strings.compare(a.album, b.album) == -1
		})
	case .Track:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			if a.track == b.track do return strings.compare(a.title, b.title) == -1
			return a.track < b.track
		})
	case .Duration:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			return a.duration < b.duration
		})
	case .Playtime:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			if a.playtime == b.playtime do return strings.compare(a.title, b.title) == -1
			return a.playtime > b.playtime
		})
	case .Last_Listened:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			if a.last_timestamp == b.last_timestamp do return strings.compare(a.title, b.title) == -1
			return time.diff(b.last_timestamp, a.last_timestamp) > 0
		})
	case .Liked_Time:
		slice.sort_by(playlist.songs[:], proc(a, b: ^Music) -> bool {
			if a.liked != b.liked do return a.liked
			if !a.liked || a.liked_timestamp == b.liked_timestamp do return strings.compare(a.title, b.title) == -1
			return time.diff(b.liked_timestamp, a.liked_timestamp) > 0
		})
	}

	if playlist.sort_reversed do slice.reverse(playlist.songs[:])
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
	liked_playlist := &playlists[LIKED_PLAYLIST_INDEX]

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

	playlist_sort(liked_playlist)
}

record_listen :: proc(song: ^Music) {
	history_playlist := &playlists[HISTORY_PLAYLIST_INDEX]
	song.last_timestamp = time.now()

	for history_song, i in history_playlist.songs {
		if history_song == song {
			ordered_remove(&history_playlist.songs, i)
			break
		}
	}
	inject_at(&history_playlist.songs, 0, song)

	for &playlist in playlists {
		playlist_sort(&playlist)
	}
}

cache: struct {
	volume: f32,
	songs: map[string]Music,
}

cache_load :: proc() {
	dir, dir_err := os.user_data_dir(context.temp_allocator)
	if dir_err != nil do return

	save_path := strings.concatenate({dir, "\\fmusic\\cache.cbor"}, context.temp_allocator)

	data, read_err := os.read_entire_file(save_path, context.temp_allocator);
	if read_err != nil do return

	err := cbor.unmarshal(data, &cache, {.Trusted_Input})
	if err != nil {
		fmt.eprintfln("Failed to load cache.cbor", err)
		return
	}

	audio.volume = cache.volume
}

cache_save :: proc() {
	if !loader_is_fully_loaded() do return

	dir, dir_err := os.user_data_dir(context.temp_allocator)
	if dir_err != nil do return

	fmusic_dir := strings.concatenate({dir, "\\fmusic"}, context.temp_allocator)
	os.make_directory(fmusic_dir)
	save_path := strings.concatenate({fmusic_dir, "\\cache.cbor"}, context.temp_allocator)

	cache.volume = audio.volume
	cache.songs = make(map[string]Music, 1024)

	for playlist in playlists[LIBRARY_PLAYLIST_START:] {
		for m in playlist.songs {
			cache.songs[m.fullpath] = m^
		}
	}

	bytes, err := cbor.marshal(cache)
	if err == nil {
		_ = os.write_entire_file(save_path, bytes)
	} else {
		fmt.eprintfln("Failed to save cache.cbor", err)
	}
}
