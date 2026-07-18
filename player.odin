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
}

player_start_playlist :: proc(songs: []^Music, song_idx: int) {
	clear(&player.songs)
	clear(&player.playlist)

	for song in songs {
		append(&player.songs, song)
		append(&player.playlist, song)
	}

	player.cursor = song_idx
	player_play_music(player.songs[player.cursor])

	if player.shuffle {
		player_shuffle()
	}
}

player_play_music :: proc(song: ^Music, gapless := false) {
	if !audio.open(song.fullpath, gapless) {
		player.playing = false
		player.music = nil
		return
	}
	audio.resume()
	player.music = song
	player.playing = true
	record_listen(song)
	lyrics_scroll = {}
	lyrics_synced = true
	visualizer_create_palette(song.thumbnail_pixels)

	//-----------------------------------
	fx.texture_free(&player.cover)
	cover_bytes := audio.cover(song.fullpath)
	defer delete(cover_bytes)
	if cover_bytes != nil {
		player.cover = fx.texture_load(cover_bytes)
	} else {
		player.cover = {}
	}

	smtc.update_metadata(song.title, song.artist, cover_bytes)
	smtc.update_status(1)
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
	if audio.position() > 3.0 {
		player_seek(0)
		return
	}
	if len(player.songs) == 0 do return

	player.cursor = (player.cursor - 1) %% len(player.songs)
	player_play_music(player.songs[player.cursor])
}

player_shuffle :: proc() {
	rand.shuffle(player.songs[:])

	for song, i in player.songs {
		if song == player.music {
			player.cursor = i
			break
		}
	}
}

player_unshuffle :: proc() {
	clear(&player.songs)
	for song in player.playlist {
		append(&player.songs, song)
	}

	for song, i in player.songs {
		if song == player.music {
			player.cursor = i
			break
		}
	}
}

player_toggle_shuffle :: proc() {
	player.shuffle = !player.shuffle

	if player.shuffle {
		player_shuffle()
	} else {
		player_unshuffle()
	}
}

player_toggle_pause :: proc() {
	player.playing = !player.playing
	if !player.playing {
		audio.pause()
		smtc.update_status(2)
	} else {
		audio.resume()
		smtc.update_status(1)
	}
}

player_seek :: proc(pos: f32) {
	audio.seek(pos)
	if !player.playing {
		audio.pause()
	}
}

current_lyric :: proc() -> (index: int, found: bool) {
	if player.music == nil || len(player.music.lyrics) == 0 do return
	t := scrub_time >= 0 ? scrub_time : audio.position()
	if t < player.music.lyrics[0].time do return 0, false

	for lyric, i in player.music.lyrics {
		if t < lyric.time do break
		index = i
	}
	
	return index, true
}

player_update :: proc() {
	if player.music == nil do return

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
