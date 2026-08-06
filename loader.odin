package main

import "core:bytes"
import "core:container/bit_array"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "fx"
import "fx/audio"
import "vendor:stb/image"

AtlasRegion :: struct {
	texture: fx.Texture,
	source:  fx.Rect,
}

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
	listen_timestamp: time.Time,
	lyrics:           [dynamic]Lyric,
	lyrics_filter:    bit_array.Bit_Array,
	thumbnail_pixels: []fx.Color,
	thumbnail:        AtlasRegion,
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
polling_finished: bool

music_by_id: map[Id]^Music

music_id :: proc(music: ^Music) -> Id {
	ext := os.ext(music.fullpath)
	key := to_string(music.title, music.artist, music.album, music.duration)
	return Id(hash.fnv64a(transmute([]byte)key))
}

loader_start :: proc() {
	load_settings()

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

		cache, cache_err := cache_load()
		cached_by_id: map[Id]^Music
		if cache_err == nil {
			cached_by_id = make(map[Id]^Music, len(cache))
			for _, &song in cache {
				id := music_id(&song)
				cached_by_id[id] = &song
			}
		}

		walker := os.walker_create(music_dir)
		defer os.walker_destroy(&walker)

		for info in os.walker_walk(&walker) {
			if strings.starts_with(info.fullpath, ".") {
				os.walker_skip_dir(&walker)
				continue
			}

			extension := strings.to_lower(os.ext(info.fullpath), context.temp_allocator)
			if extension != ".opus" && extension != ".ogg" && extension != ".flac" {
				continue
			}

			music := new(Music)

			if cache_err == nil {
				if cached, found := cache[info.fullpath]; found {
					music^ = cached
				}
			}

			if music.fullpath == "" {
				music.fullpath = strings.clone(info.fullpath)
				if metadata, ok := audio.metadata(music.fullpath); ok {
					music.title = strings.clone(metadata.title)
					music.artist = strings.clone(metadata.artist)
					music.album = strings.clone(metadata.album)
					music.track = metadata.track
					music.duration = metadata.duration

					if len(metadata.cover) > 0 {
						load_thumbnail(music, metadata.cover)
					}
				}

				if music.title == "" {
					music.title = strings.clone(os.stem(music.fullpath))
				}
			}

			id := music_id(music)
			if cached, found := cached_by_id[id]; found {
				music.playtime = cached.playtime
				music.liked = cached.liked
				music.liked_timestamp = cached.liked_timestamp
				music.listen_timestamp = cached.listen_timestamp
			}

			load_lrc(music)
			free_all(context.temp_allocator)
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
	if polling_finished do return

	sync.lock(&loader_mutex)

	if(loading_finished && len(loader_queue) == 0) {
		polling_finished = true;
		sync.unlock(&loader_mutex)
		return
	}

	queue := slice.clone(loader_queue[:])
	defer delete(queue)
	clear(&loader_queue)

	sync.unlock(&loader_mutex)

	if len(queue) == 0 do return

	@(static) cursor_x: int
	@(static) cursor_y: int
	@(static) atlases: [dynamic]fx.Texture
	ATLAS_SIZE :: 4096

	next_music: for &music in queue {
		id := music_id(music)
		cached, found := music_by_id[id]
		if found {
			playlist_name := os.base(os.dir(music.fullpath))
			for &playlist in playlists[LIBRARY_PLAYLIST_START:] {
				if playlist.name == playlist_name {
					append(&playlist.songs, cached)
					playlist_sort(&playlist)
					continue next_music
				}
			}

			append(&playlists, Playlist{name = playlist_name, sort = .Title, icon = .Note})
			append(&playlists[len(playlists) - 1].songs, cached)
			continue next_music
		} else {
			music_by_id[id] = music
		}

		if len(music.thumbnail_pixels) > 0 {
			if len(atlases) == 0 || cursor_y + 64 > ATLAS_SIZE {
				atlas_tex := fx.texture_create(ATLAS_SIZE, ATLAS_SIZE)
				append(&atlases, atlas_tex)
				cursor_x = 0
				cursor_y = 0
			}

			current_atlas := atlases[len(atlases) - 1]
			fx.texture_upload(current_atlas, music.thumbnail_pixels, cursor_x, cursor_y, 64, 64)

			music.thumbnail = {
				texture = current_atlas,
				source = {{f32(cursor_x), f32(cursor_y)}, {f32(64), f32(64)}},
			}

			cursor_x += 64
			if cursor_x + 64 > ATLAS_SIZE {
				cursor_x = 0
				cursor_y += 64
			}
		}

		if music.liked {
			append(&playlists[LIKED_PLAYLIST_INDEX].songs, music)
		}

		if time.to_unix_nanoseconds(music.listen_timestamp) > 0 {
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

		append(&playlists, Playlist{name = playlist_name, sort = .Title, icon = .Note})
		append(&playlists[len(playlists) - 1].songs, music)
	}

	next_playlist: for &playlist in playlists[LIBRARY_PLAYLIST_START:] {
		if len(playlist.songs) < 2 || playlist.songs[0].album == "" do continue
		album := playlist.songs[0].album
		for song in playlist.songs[1:] {
			if song.album != album do continue next_playlist
		}
		playlist.sort = .Track
		playlist.icon = .Album
	}

	for &playlist in playlists {
		playlist_sort(&playlist)
	}
}

load_lrc :: proc(music: ^Music) -> os.Error {
	if len(music.lyrics) > 0 do return nil
	filename := os.join_filename(os.stem(music.fullpath), "lrc", context.temp_allocator) or_return
	path := os.join_path({os.dir(music.fullpath), filename}, context.temp_allocator) or_return

	data := os.read_entire_file(path, context.allocator) or_return
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
		lyric := strings.clone(strings.trim_space(text[close + 1:]))
		append(&music.lyrics, Lyric{lyric, minutes * 60 + seconds})

		runes := make([dynamic]rune, 0, len(lyric), context.temp_allocator)
		for character in strings.to_lower(lyric, context.temp_allocator) {
			if character != ' ' {
				append(&runes, character)
			}
		}

		if len(runes) >= 5 {
			for index in 0 ..= len(runes) - 5 {
				bytes := slice.reinterpret([]byte, runes[index:index + 5])
				bit_array.set(&music.lyrics_filter, uint(hash.fnv32a(bytes) & 32767))
			}
		}
	}

	return nil
}

load_thumbnail :: proc(music: ^Music, cover_bytes: []byte) {
	if len(cover_bytes) == 0 || len(music.thumbnail_pixels) > 0 do return

	w, h, channels: i32
	pixels := image.load_from_memory(raw_data(cover_bytes), i32(len(cover_bytes)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer image.image_free(pixels)

	crop_size := min(w, h)
	offset_x := (w - crop_size) / 2
	offset_y := (h - crop_size) / 2
	cropped_pixels := cast([^]u8)&pixels[(offset_y * w + offset_x) * 4]

	music.thumbnail_pixels = make([]fx.Color, 64 * 64)
	image.resize_uint8(cropped_pixels, crop_size, crop_size, w * 4, cast([^]u8)raw_data(music.thumbnail_pixels), 64, 64, 0, 4)
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
			if a.listen_timestamp == b.listen_timestamp do return strings.compare(a.title, b.title) == -1
			return time.diff(b.listen_timestamp, a.listen_timestamp) > 0
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

refresh_liked_playlist :: proc() {
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
	song.listen_timestamp = time.now()
	for item, i in history.songs {
		if item == song {
			ordered_remove(&history.songs, i)
			break
		}
	}

	inject_at(&history.songs, 0, song)
	for &playlist in playlists do playlist_sort(&playlist)
}

Settings :: struct {
	volume:     f32,
	pregain_db: f32,
	band_gains: [10]f32,
}

save_settings :: proc() -> os.Error {
	dir := os.user_data_dir(context.temp_allocator) or_return
	app_dir := os.join_path({dir, "GriPlayer"}, context.temp_allocator) or_return
	os.make_directory(app_dir)
	settings_path := os.join_path({app_dir, "settings.bin"}, context.temp_allocator) or_return

	settings := Settings{
		volume     = audio.get_volume(),
		pregain_db = audio.decoder.pregain_db,
	}

	for i in 0..<10 {
		settings.band_gains[i] = audio.eq_get_gain(i)
	}

	os.write_entire_file(settings_path, slice.bytes_from_ptr(&settings, size_of(Settings))) or_return

	return nil
}

load_settings :: proc() -> os.Error {
	dir := os.user_data_dir(context.temp_allocator) or_return
	app_dir := os.join_path({dir, "GriPlayer"}, context.temp_allocator) or_return
	settings_path := os.join_path({app_dir, "settings.bin"}, context.temp_allocator) or_return

	data := os.read_entire_file(settings_path, context.temp_allocator) or_return

	settings := (cast(^Settings)raw_data(data))^
	audio.set_volume(settings.volume)
	audio.decoder.pregain_db = settings.pregain_db
	for i in 0..<10 {
		audio.eq_set_gain(i, settings.band_gains[i])
	}

	return nil
}

// Cache

cache_write :: proc(b: ^bytes.Buffer, val: $T) {
	v := val
	bytes.buffer_write_ptr(b, &v, size_of(T))
}

cache_read :: proc(r: ^bytes.Reader, $T: typeid) -> (v: T, err: os.Error) {
	_, io_err := bytes.reader_read_ptr(r, &v, size_of(T))
	if io_err != nil do return v, io_err
	return v, nil
}

cache_write_string :: proc(b: ^bytes.Buffer, s: string) {
	cache_write(b, i64(len(s)))
	if len(s) > 0 {
		bytes.buffer_write_string(b, s)
	}
}

cache_read_string :: proc(r: ^bytes.Reader, allocator := context.allocator) -> (res: string, err: os.Error) {
	length := cache_read(r, i64) or_return
	buf := make([]byte, int(length), context.temp_allocator)
	_, io_err := bytes.reader_read_ptr(r, raw_data(buf), int(length))
	if io_err != nil do return "", io_err
	return strings.clone(string(buf), allocator), nil
}

cache_load :: proc() -> (songs: map[string]Music, error: os.Error) {
	dir := os.user_data_dir(context.temp_allocator) or_return
	path := os.join_path({dir, "GriPlayer", "cache.bin"}, context.temp_allocator) or_return
	data := os.read_entire_file(path, context.allocator) or_return

	r: bytes.Reader
	bytes.reader_init(&r, data)

	track_count := cache_read(&r, i64) or_return
	if track_count < 0 do return nil, os.General_Error.Invalid_File

	songs = make(map[string]Music, int(track_count))

	for _ in 0..<track_count {
		music: Music

		music.fullpath = cache_read_string(&r) or_return
		music.title    = cache_read_string(&r) or_return
		music.artist   = cache_read_string(&r) or_return
		music.album    = cache_read_string(&r) or_return

		music.track            = int(cache_read(&r, i64) or_return)
		music.playtime         = cache_read(&r, f32) or_return
		music.duration         = cache_read(&r, f32) or_return
		music.liked            = (cache_read(&r, u8) or_return) != 0
		music.liked_timestamp  = time.Time{_nsec = cache_read(&r, i64) or_return}
		music.listen_timestamp = time.Time{_nsec = cache_read(&r, i64) or_return}

		lyric_count := cache_read(&r, i64) or_return
		if lyric_count > 0 {
			music.lyrics = make([dynamic]Lyric, int(lyric_count))
			for j in 0..<lyric_count {
				l_time := cache_read(&r, f32) or_return
				l_text := cache_read_string(&r) or_return
				music.lyrics[j] = Lyric{time = l_time, text = l_text}
			}
		}

		word_count := cache_read(&r, i64) or_return
		if word_count > 0 {
			bit_array.init(&music.lyrics_filter, int(word_count * 64))
			resize(&music.lyrics_filter.bits, int(word_count))
			for j in 0..<word_count {
				music.lyrics_filter.bits[j] = cache_read(&r, u64) or_return
			}
		}

		pixel_count := cache_read(&r, i64) or_return
		if pixel_count > 0 {
			bytes_count := int(pixel_count) * size_of(fx.Color)
			music.thumbnail_pixels = make([]fx.Color, int(pixel_count))
			_, err_px := bytes.reader_read_ptr(&r, raw_data(music.thumbnail_pixels), bytes_count)
			if err_px != nil do return nil, err_px
		}

		songs[music.fullpath] = music
	}

	return
}

cache_save :: proc() -> os.Error {
	if !polling_finished do return nil

	dir := os.user_data_dir(context.allocator) or_return
	app_dir := os.join_path({dir, "GriPlayer"}, context.allocator) or_return
	os.make_directory(app_dir)
	path := os.join_path({app_dir, "cache.bin"}, context.allocator) or_return

	b: bytes.Buffer
	bytes.buffer_init_allocator(&b, 0, 64 * 1024, context.allocator)

	total_tracks := len(music_by_id)
	cache_write(&b, i64(total_tracks))

	saved_set := make(map[string]bool, total_tracks, context.temp_allocator)

	for _, song in music_by_id {
		if song.fullpath in saved_set do continue
		saved_set[song.fullpath] = true

		cache_write_string(&b, song.fullpath)
		cache_write_string(&b, song.title)
		cache_write_string(&b, song.artist)
		cache_write_string(&b, song.album)

		cache_write(&b, i64(song.track))
		cache_write(&b, song.playtime)
		cache_write(&b, song.duration)
		cache_write(&b, u8(song.liked ? 1 : 0))
		cache_write(&b, song.liked_timestamp._nsec)
		cache_write(&b, song.listen_timestamp._nsec)

		cache_write(&b, i64(len(song.lyrics)))
		for lyric in song.lyrics {
			cache_write(&b, lyric.time)
			cache_write_string(&b, lyric.text)
		}

		word_count := len(song.lyrics_filter.bits)
		cache_write(&b, i64(word_count))
		for w in song.lyrics_filter.bits {
			cache_write(&b, w)
		}

		pixel_count := len(song.thumbnail_pixels)
		cache_write(&b, i64(pixel_count))
		if pixel_count > 0 {
			bytes.buffer_write_ptr(&b, raw_data(song.thumbnail_pixels), pixel_count * size_of(fx.Color))
		}
	}

	os.write_entire_file(path, bytes.buffer_to_bytes(&b)) or_return
	return nil
}
