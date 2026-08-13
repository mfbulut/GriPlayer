package main

import "core:math/rand"

import "fx"
import "audio"
import "smtc"

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

cover_to_free: fx.Texture

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
	if song == nil || !audio.open(song.fullpath) {
		player.playing = false
		player.music = nil
		return
	}

	if !gapless do audio.reset()
	if paused do audio.pause()
	else do audio.resume()

	audio.eq_reset_state()
	player.session += 1
	player.music = song
	player.playing = !paused
	lyrics_synced = true
	lyrics_sync_now = true
	scrub_time = -1

	record_listen(song)
	visualizer_create_palette(song.thumbnail_pixels)

	cover_to_free = player.cover
	meta, _ := audio.metadata(song.fullpath)
	if len(meta.cover) > 0 {
		player.cover = fx.texture_load(meta.cover, mipmaps = true)
	} else {
		player.cover = {}
	}

	smtc.update_metadata(song.title, song.artist, meta.cover)
	smtc.update_status(paused ? .Paused : .Playing)
}

player_next :: proc(gapless := false) {
	if len(player.queue) > 0 {
		song := player.queue[0]
		ordered_remove(&player.queue, 0)
		insert_idx := clamp(player.cursor + 1, 0, len(player.songs))
		inject_at(&player.songs, insert_idx, song)
		player.cursor = insert_idx
		player_play_music(song, gapless)
		return
	}
	if len(player.songs) == 0 {
		player.playing = false
		audio.pause()
		smtc.update_status(.Paused)
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
	player.cursor = 0

	for song, i in player.songs {
		if song == player.music {
			player.songs[0], player.songs[i] = player.songs[i], player.songs[0]
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
	for song, i in player.songs {
		if song == player.music {
			player.cursor = i
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
		smtc.update_status(.Playing)
	} else {
		audio.pause()
		smtc.update_status(.Paused)
	}
}

player_seek :: proc(position: f32) {
	audio.seek(position)
	if !player.playing {
		audio.pause()
	}
	audio.eq_reset_state()
}

player_queue_add :: proc(song: ^Music, next := false) {
	if song == nil do return
	if player.music == nil && len(player.queue) == 0 {
		insert_idx := clamp(player.cursor + 1, 0, len(player.songs))
		inject_at(&player.songs, insert_idx, song)
		player.cursor = insert_idx
		player_play_music(song, paused = true)
		return
	}
	if next {
		inject_at(&player.queue, 0, song)
	} else {
		append(&player.queue, song)
	}
}

current_lyric :: proc() -> (i: int, found: bool) {
	if player.music == nil || len(player.music.lyrics) == 0 do return
	position := scrub_time >= 0 ? scrub_time : audio.position()
	if position < player.music.lyrics[0].time do return 0, false
	for lyric, lyric_index in player.music.lyrics {
		if position < lyric.time do break
		i = lyric_index
	}
	return i, true
}

player_update :: proc() {
	if cover_to_free.index != 0 {
		fx.texture_destroy(&cover_to_free)
	}

	if player.music == nil {
		return
	}

	switch smtc.poll_action() {
	case .None:
	case .Play:
		if !player.playing do player_toggle_pause()
	case .Pause:
		if player.playing do player_toggle_pause()
	case .Next:
		player_next()
	case .Previous:
		player_prev()
	}

	if fx.key_is_pressed(.Play_Pause) do player_toggle_pause()
	if fx.key_is_pressed(.Next_Track) do player_next()
	if fx.key_is_pressed(.Prev_Track) do player_prev()

	if audio.is_finished() {
		player_next(true)
		return
	}

	visualizer_update()
}
