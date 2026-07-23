package main

import "core:container/bit_array"
import "core:encoding/cbor"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode"

import "fx"
import "fx/audio"
import "vendor:stb/image"

Lyric :: struct {
	text: string,
	time: f32,
}

Music :: struct {
	fullpath:        string,
	title:           string,
	artist:          string,
	album:           string,
	track:           int,
	playtime:        f32,
	duration:        f32,
	liked:           bool,
	liked_timestamp: time.Time,
	last_timestamp:  time.Time,
	lyrics:           [dynamic]Lyric,
	lyrics_filter:    bit_array.Bit_Array,
	thumbnail_pixels: []fx.Color,
	thumbnail:        fx.Texture `cbor:"-"`,
}

Playlist :: struct {
	name:          string,
	songs:         [dynamic]^Music,
	icon:          Icon,
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
	.Title = "Title", .Artist = "Artist", .Album = "Album", .Track = "Track Index",
	.Duration = "Duration", .Playtime = "Playtime", .Last_Listened = "Last Listened", .Liked_Time = "Liked",
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
		icon = .Heart,
		sort = .Liked_Time,
	})
	append(&playlists, Playlist{
		name = "History",
		icon = .History,
		sort = .Last_Listened,
	})

	thread.create_and_start(proc() {
		music_dir, directory_error := os.user_music_dir(context.temp_allocator)
		if directory_error != nil {
			sync.lock(&loader_mutex)
			loading_finished = true
			sync.unlock(&loader_mutex)
			return
		}

		cache_load()
		walker := os.walker_create(music_dir)
		defer os.walker_destroy(&walker)

		for info in os.walker_walk(&walker) {
			if strings.starts_with(info.fullpath, ".") {
				os.walker_skip_dir(&walker)
				continue
			}
			extension := strings.to_lower(os.ext(info.fullpath), context.temp_allocator)
			if extension != ".opus" && extension != ".ogg" && extension != ".mp3" &&
			   extension != ".flac" && extension != ".wav" {
				continue
			}
			music := load_music(info.fullpath)
			sync.lock(&loader_mutex)
			append(&loader_queue, music)
			sync.unlock(&loader_mutex)
		}

		sync.lock(&loader_mutex)
		loading_finished = true
		sync.unlock(&loader_mutex)
	}, self_cleanup = true)
}

loader_poll :: proc() {
	sync.lock(&loader_mutex)
	queue := slice.clone(loader_queue[:])
	clear(&loader_queue)
	sync.unlock(&loader_mutex)
	defer delete(queue)
	if len(queue) == 0 do return

	next_music: for music in queue {
		if len(music.thumbnail_pixels) > 0 {
			music.thumbnail = fx.texture_load_raw(music.thumbnail_pixels, 64, 64, false)
		}
		if music.liked {
			append(&playlists[LIKED_PLAYLIST_INDEX].songs, music)
		}
		if time.to_unix_nanoseconds(music.last_timestamp) > 0 {
			append(&playlists[HISTORY_PLAYLIST_INDEX].songs, music)
		}

		playlist_name := os.base(os.dir(music.fullpath))
		for &playlist in playlists[LIBRARY_PLAYLIST_START:] {
			if playlist.name == playlist_name {
				append(&playlist.songs, music)
				playlist_sort(&playlist)
				continue next_music
			}
		}
		append(&playlists, Playlist{name = playlist_name, sort = .Title})
		append(&playlists[len(playlists) - 1].songs, music)
	}

	next_playlist: for &playlist in playlists[LIBRARY_PLAYLIST_START:] {
		if len(playlist.songs) < 2 || playlist.songs[0].album == "" do continue
		album := playlist.songs[0].album
		for song in playlist.songs[1:] {
			if song.album != album do continue next_playlist
		}
		playlist.sort = .Track
	}

	for &playlist in playlists {
		playlist_sort(&playlist)
	}

	search.initialized = false
}

loader_is_finished :: proc() -> bool {
	sync.lock(&loader_mutex)
	finished := loading_finished && len(loader_queue) == 0
	sync.unlock(&loader_mutex)
	return finished
}

load_music :: proc(fullpath: string) -> ^Music {
	music := new(Music)
	music.fullpath = strings.clone(fullpath)
	if cached, found := cache.songs[music.fullpath]; found {
		music^ = cached
	} else {
		if metadata, ok := audio.metadata(music.fullpath); ok {
			music.title = metadata.title
			music.artist = metadata.artist
			music.album = metadata.album
			music.track = metadata.track
			music.duration = metadata.duration
		}

		if music.title == "" {
			music.title = strings.clone(os.stem(music.fullpath))
		}

		load_lrc(music)
		load_thumbnail(music)
	}

	free_all(context.temp_allocator)
	return music
}

load_lrc :: proc(music: ^Music) {
	path := strings.concatenate(
		{os.dir(music.fullpath), "\\", os.stem(music.fullpath), ".lrc"},
		context.temp_allocator,
	)
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil do return
	defer delete(data)

	bit_array.init(&music.lyrics_filter, 32768)
	lines := string(data)
	for line in strings.split_lines_iterator(&lines) {
		text := strings.trim_space(line)
		open := strings.index(text, "[")
		close := strings.index(text, "]")
		if open < 0 || close <= open do continue
		tag := text[open + 1:close]
		colon := strings.index(tag, ":")
		if colon < 0 do continue
		minutes := strconv.parse_f32(tag[:colon]) or_continue
		seconds := strconv.parse_f32(tag[colon + 1:]) or_continue
		lyric := strings.clone(text[close + 1:])
		append(&music.lyrics, Lyric{lyric, minutes * 60 + seconds})

		runes := make([dynamic]rune, 0, len(lyric), context.temp_allocator)
		for character in strings.to_lower(lyric, context.temp_allocator) {
			if unicode.is_letter(character) || unicode.is_digit(character) {
				append(&runes, character)
			}
		}
		if len(runes) >= 5 {
			for index in 0 ..= len(runes) - 5 {
				bytes := slice.reinterpret([]byte, runes[index:index + 5])
				bit_array.set(&music.lyrics_filter, uint(xxhash.XXH32(bytes) & 32767))
			}
		}
	}
}

load_thumbnail :: proc(music: ^Music) {
	cover_bytes := audio.cover(music.fullpath)
	if len(cover_bytes) == 0 do return
	defer delete(cover_bytes)

	w, h, channels: i32
	pixels := image.load_from_memory(raw_data(cover_bytes), i32(len(cover_bytes)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer image.image_free(pixels)

	music.thumbnail_pixels = make([]fx.Color, 64 * 64)
	success := image.resize_uint8(
		pixels,
		w,
		h,
		0,
		cast([^]u8)raw_data(music.thumbnail_pixels),
		64,
		64,
		0,
		4,
	)
	if success == 0 {
		delete(music.thumbnail_pixels)
		music.thumbnail_pixels = nil
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
	if playlist.sort_reversed {
		slice.reverse(playlist.songs[:])
	}
}

liked_playlist_count :: proc() -> int {
	count := 0
	for song in playlists[LIKED_PLAYLIST_INDEX].songs {
		if song.liked do count += 1
	}
	return count
}

liked_playlist_refresh :: proc() {
	liked := &playlists[LIKED_PLAYLIST_INDEX]
	for index := len(liked.songs) - 1; index >= 0; index -= 1 {
		if !liked.songs[index].liked do ordered_remove(&liked.songs, index)
	}
	playlist_sort(liked)
}

toggle_like :: proc(song: ^Music) {
	if song == nil do return
	liked := &playlists[LIKED_PLAYLIST_INDEX]
	song.liked = !song.liked
	if !song.liked do return

	song.liked_timestamp = time.now()
	for item in liked.songs {
		if item == song do return
	}
	append(&liked.songs, song)
	playlist_sort(liked)
}

record_listen :: proc(song: ^Music) {
	history := &playlists[HISTORY_PLAYLIST_INDEX]
	song.last_timestamp = time.now()
	for item, index in history.songs {
		if item == song {
			ordered_remove(&history.songs, index)
			break
		}
	}

	inject_at(&history.songs, 0, song)
	for &playlist in playlists do playlist_sort(&playlist)
}

cache: struct {
	volume: f32,
	songs:  map[string]Music,
}

cache_load :: proc() {
	dir, dir_error := os.user_data_dir(context.temp_allocator)
	if dir_error != nil do return

	path := strings.concatenate({dir, "\\fmusic\\cache.cbor"}, context.temp_allocator)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do return

	if error := cbor.unmarshal(data, &cache, {.Trusted_Input}); error != nil {
		fmt.eprintln("Failed to load cache:", error)
		return
	}

	audio.volume = cache.volume
}

cache_save :: proc() {
	if !loader_is_finished() do return
	dir, dir_error := os.user_data_dir(context.temp_allocator)
	if dir_error != nil do return

	app_dir := strings.concatenate({dir, "\\fmusic"}, context.temp_allocator)
	os.make_directory(app_dir)
	path := strings.concatenate({app_dir, "\\cache.cbor"}, context.temp_allocator)

	cache.volume = audio.volume
	cache.songs = make(map[string]Music, 1024)
	for playlist in playlists[LIBRARY_PLAYLIST_START:] {
		for song in playlist.songs {
			cache.songs[song.fullpath] = song^
		}
	}
	
	bytes, error := cbor.marshal(cache)
	if error == nil {
		_ = os.write_entire_file(path, bytes)
	} else {
		fmt.eprintln("Failed to save cache:", error)
	}
}
