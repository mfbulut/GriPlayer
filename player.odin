package main

import "core:math/rand"

import "fx"
import "fx/audio"
import "fx/smtc"

player: struct {
	songs:    [dynamic]^Music,
	playlist: [dynamic]^Music,
	queue:    [dynamic]^Music,
	cover:    fx.Texture,
	music:    ^Music,
	playing:  bool,
	shuffle:  bool,
	cursor:   int,
	session:  int,
}

player_start_playlist :: proc(songs: []^Music, song_index: int) {
	if len(songs) == 0 || song_index < 0 || song_index >= len(songs) {
		return
	}
	clear(&player.songs)
	clear(&player.playlist)
	for song in songs {
		append(&player.songs, song)
		append(&player.playlist, song)
	}
	player.cursor = song_index
	player_play_music(player.songs[player.cursor])
	if player.shuffle {
		player_shuffle()
	}
}

player_play_music :: proc(song: ^Music, gapless := false, paused := false) {
	if song == nil || !audio.open(song.fullpath, gapless) {
		player.playing = false
		player.music = nil
		return
	}

	if paused do audio.pause()
	else do audio.resume()
	player.session += 1
	player.music = song
	player.playing = !paused
	lyrics_synced = true
	scrub_time = -1
	record_listen(song)
	visualizer_create_palette(song.thumbnail_pixels)

	fx.texture_free(&player.cover)
	cover_bytes := audio.cover(song.fullpath)
	defer delete(cover_bytes)
	if len(cover_bytes) > 0 {
		player.cover = fx.texture_load(cover_bytes)
	}

	smtc.update_metadata(song.title, song.artist, cover_bytes)
	smtc.update_status(paused ? 2 : 1)
}

player_next :: proc(gapless := false) {
	if len(player.queue) > 0 {
		player_play_music(player.queue[0], gapless)
		ordered_remove(&player.queue, 0)
		return
	}
	if len(player.songs) == 0 {
		player.playing = false
		audio.pause()
		smtc.update_status(2)
		return
	}
	player.cursor = (player.cursor + 1) %% len(player.songs)
	player_play_music(player.songs[player.cursor], gapless)
}

player_prev :: proc() {
	if audio.position() > 3 {
		player_seek(0)
		return
	}
	if len(player.songs) == 0 {
		return
	}
	player.cursor = (player.cursor - 1) %% len(player.songs)
	player_play_music(player.songs[player.cursor])
}

player_shuffle :: proc() {
	rand.shuffle(player.songs[:])
	for song, index in player.songs {
		if song == player.music {
			player.cursor = index
			break
		}
	}
}

player_toggle_shuffle :: proc() {
	player.shuffle = !player.shuffle
	if player.shuffle {
		player_shuffle()
		return
	}
	clear(&player.songs)
	for song in player.playlist {
		append(&player.songs, song)
	}
	for song, index in player.songs {
		if song == player.music {
			player.cursor = index
			break
		}
	}
}

player_toggle_pause :: proc() {
	if player.music == nil {
		return
	}
	player.playing = !player.playing
	if player.playing {
		audio.resume()
		smtc.update_status(1)
	} else {
		audio.pause()
		smtc.update_status(2)
	}
}

player_seek :: proc(position: f32) {
	audio.seek(position)
	if !player.playing {
		audio.pause()
	}
}

player_queue_add :: proc(song: ^Music, next := false) {
	if song == nil do return
	if player.music == nil && len(player.queue) == 0 {
		player_play_music(song, paused = true)
		return
	}
	if next {
		inject_at(&player.queue, 0, song)
	} else {
		append(&player.queue, song)
	}
}

current_lyric :: proc() -> (index: int, found: bool) {
	if player.music == nil || len(player.music.lyrics) == 0 do return
	position := scrub_time >= 0 ? scrub_time : audio.position()
	if position < player.music.lyrics[0].time do return 0, false
	for lyric, lyric_index in player.music.lyrics {
		if position < lyric.time do break
		index = lyric_index
	}
	return index, true
}

player_update :: proc() {
	if player.music == nil {
		return
	}
	
	switch smtc.poll_action() {
	case 0:
		player_toggle_pause()
	case 1:
		player_next()
	case 2:
		player_prev()
	}
	if fx.key_is_pressed(.Play_Pause) do player_toggle_pause()
	if fx.key_is_pressed(.Next_Track) do player_next()
	if fx.key_is_pressed(.Prev_Track) do player_prev()

	if audio.update(visualizer_push) {
		player_next(true)
		return
	}

	visualizer_update()
}
