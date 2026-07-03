package main

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:hash/xxhash"
import "core:container/bit_array"
import "core:unicode/utf8"
import "core:unicode"

import "fx"
import "fx/audio"

LyricLine :: struct {
    text: string,
    time: f32,
}

Music :: struct {
    fullpath:     string,
    title:        string,
    artist:       string,
    album:        string,
    track:        int,
    playtime:     f32,
    duration:     f32,
    liked:        bool,
    lyrics:       [dynamic]LyricLine,
    lyrics_filter: ^bit_array.Bit_Array,
    thumbnail:    fx.Texture,
}

Playlist :: struct {
    name:  string,
    songs: [dynamic]^Music,
}

playlists : [dynamic]Playlist

load_music :: proc() {
    append(&playlists, Playlist{ name = "Liked" })

    music_dir := os.user_music_dir(context.allocator) or_else panic("Failed to find music dir")

    w := os.walker_create(music_dir)
	defer os.walker_destroy(&w)

	next: for info in os.walker_walk(&w) {
		if strings.starts_with(info.fullpath, ".") {
			os.walker_skip_dir(&w)
			continue
		}

		if os.ext(info.fullpath) != ".opus" {
		   continue
		}

	    fullpath := strings.clone(info.fullpath)
        music := new_clone(Music{ fullpath = fullpath })
        meta := audio.metadata(music.fullpath)
        music.title = meta.title
        music.artist = meta.artist
        music.album = meta.album
        music.track = meta.track
        music.duration = meta.duration
        if music.title == "" {
            music.title = os.stem(music.fullpath)
        }
        load_lrc(music)

        cover_bytes := audio.cover(music.fullpath)
        if cover_bytes != nil {
            music.thumbnail = fx.load_and_resize_texture(cover_bytes, 64)
            delete(cover_bytes)
        }

        playlist_name := os.base(os.dir(fullpath))

	    for &playlist in playlists[1:] {
	        if playlist.name == playlist_name {
               append(&playlist.songs, music)
	           continue next
	        }
	    }

        append(&playlists, Playlist{ name = playlist_name })
        append(&playlists[len(playlists) - 1].songs, music)
	}

    load_music_state()
}

toggle_like :: proc(song: ^Music) {
    liked_playlist := &playlists[0]

    if !song.liked {
        song.liked = true
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

load_lrc :: proc(music: ^Music) {
    stem := os.stem(music.fullpath)
    dir := os.dir(music.fullpath)

    lrc_path := strings.concatenate({dir, "\\", stem, ".lrc"}, context.temp_allocator)
    data, err := os.read_entire_file(lrc_path, context.allocator)
    if err != nil {
        return
    }

    music.lyrics_filter  = bit_array.create(32768)

    it := string(data)
    for line in strings.split_lines_iterator(&it) {
        line := strings.trim_space(line)
        if len(line) == 0 do continue

        open_bracket := strings.index(line, "[")
        close_bracket := strings.index(line, "]")

        if open_bracket == -1 || close_bracket == -1 do break

        tag := line[open_bracket+1 : close_bracket]
        text := line[close_bracket+1:]

        colon_idx := strings.index(tag, ":")

        if colon_idx != -1 {
            mins := strconv.parse_f32(tag[:colon_idx]) or_continue
            secs := strconv.parse_f32(tag[colon_idx+1:]) or_continue
            append(&music.lyrics, LyricLine{text = text, time = mins * 60 + secs})

            lower_text := strings.to_lower(text, context.temp_allocator)
            runes := make([dynamic]rune, 0, len(lower_text), context.temp_allocator)
            for r in lower_text {
                if unicode.is_letter(r) || unicode.is_digit(r) {
                    append(&runes, r)
                }
            }

            for i in 0..=len(runes)-5 {
                bytes := slice.reinterpret([]byte, runes[i : i+5])
                hash := xxhash.XXH32(bytes)
                bit_array.set(music.lyrics_filter, uint(hash & 32767))
            }
        }

    }
}

SongSaveData :: struct #packed {
    hash: u64,
    playtime: f32,
}

save_music_state :: proc() {
    dir, err := os.user_data_dir(context.temp_allocator)
    if err != nil do return

    fmusic_dir := strings.concatenate({dir, "\\fmusic"}, context.temp_allocator)
    os.make_directory(fmusic_dir)
    save_path := strings.concatenate({fmusic_dir, "\\save.bin"}, context.temp_allocator)

    save_file := os.open(save_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC) or_else panic("Failed to save the data")

    liked_hashes: [dynamic]u64
    songs_to_save: [dynamic]SongSaveData

    for m in playlists[0].songs {
        hash := xxhash.XXH3_64(transmute([]byte)fmt.tprintf("%s%s", m.title, m.artist))
        append(&liked_hashes, hash)
    }

    for playlist in playlists[1:] {
        for m in playlist.songs {
            if m.playtime > 0 {
                hash := xxhash.XXH3_64(transmute([]byte)fmt.tprintf("%s%s", m.title, m.artist))
                append(&songs_to_save, SongSaveData{hash = hash, playtime = m.playtime})
            }
        }
    }

    counts := [2]u32{u32(len(songs_to_save)), u32(len(liked_hashes))}
    os.write(save_file, slice.reinterpret([]byte, counts[:]))
    os.write(save_file, slice.reinterpret([]byte, liked_hashes[:]))
    os.write(save_file, slice.reinterpret([]byte, songs_to_save[:]))

    vol_slice := []f32{volume}
    os.write(save_file, slice.reinterpret([]byte, vol_slice))
}

load_music_state :: proc() {
    dir, err := os.user_data_dir(context.temp_allocator)
    if err != nil do return

    save_path := strings.concatenate({dir, "\\fmusic\\save.bin"}, context.temp_allocator)

    data, read_err := os.read_entire_file(save_path, context.temp_allocator)
    if read_err != nil do return

    if len(data) < 2 * size_of(u32) do return

    counts := slice.reinterpret([]u32, data[:8])
    num_songs := counts[0]
    num_liked := counts[1]

    expected_size := 8 + int(num_liked) * size_of(u64) + int(num_songs) * size_of(SongSaveData)
    if len(data) < expected_size do return

    liked_offset := 8
    liked_size := int(num_liked) * size_of(u64)
    liked_slice := slice.reinterpret([]u64, data[liked_offset : liked_offset + liked_size])

    songs_offset := liked_offset + liked_size
    songs_size := int(num_songs) * size_of(SongSaveData)
    songs_slice := slice.reinterpret([]SongSaveData, data[songs_offset : songs_offset + songs_size])

    song_map := make(map[u64]^Music, context.temp_allocator)
    for playlist in playlists[1:] {
        for m in playlist.songs {
            hash := xxhash.XXH3_64(transmute([]byte)fmt.tprintf("%s%s", m.title, m.artist))
            song_map[hash] = m
        }
    }

    for s in songs_slice {
        if m, ok := song_map[s.hash]; ok {
            m.playtime = s.playtime
        }
    }

    for h in liked_slice {
        if m, ok := song_map[h]; ok {
            m.liked = true
            append(&playlists[0].songs, m)
        }
    }

    if len(data) >= expected_size + size_of(f32) {
        vol_slice := slice.reinterpret([]f32, data[expected_size : expected_size + size_of(f32)])
        audio.set_volume(vol_slice[0])
    }
}
