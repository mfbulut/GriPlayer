package main

import "core:fmt"

import "fx"
import "fx/audio"
import "fx/smtc"
import "fx/textbox"

Compact_Tab :: enum {Library, Player}

selected_playlist := 0
compact_tab: Compact_Tab
queue_active: bool
lyrics_synced := true
scrub_time := f32(-1)

main :: proc() {
	fx.init("GriPlayer")
	textbox.init(fx.window.hwnd, 16, "Search tracks, artists, lyrics")
	audio.initialize()
	smtc.init(fx.window.hwnd)
	fft_init()
	load_icons()
	loader_start()

	fx.set_frame_callback(frame)
	for fx.update() {
		frame()
	}
	cache_save()
}

frame :: proc() {
	loader_poll()
	handle_keyboard_input()
	update_search()
	player_update()
	if player.playing && player.music != nil {
		player.music.playtime += fx.frame_time()
	}

	begin_frame()
	ui_ctx.overlay = context_menu.song != nil
	size := fx.window_size()
	fx.clear_window(COLOR_BACKGROUND)
	draw_app({0, 0, size.x, size.y})
	draw_context_menu()
	end_frame()
	fx.present()
	free_all(context.temp_allocator)
}

draw_app :: proc(bounds: fx.Rect) {
	if bounds.w < 700 {
		if layout(bounds, .Col, {px(42), fr()}, pad = pad_all(8), gap = 8) {
			tabs := next()
			fx.draw_rect(tabs, COLOR_SURFACE, 8)
			if layout(tabs, .Row, {fr(), fr()}, pad = pad_all(4), gap = 6) {
				if button(id("tab-library"), next(), "Library") do compact_tab = .Library
				if button(id("tab-player"), next(), "Player") do compact_tab = .Player
			}
			if compact_tab == .Library {
				textbox.set_visible(true)
				draw_library_panel(next())
			} else {
				textbox.set_visible(false)
				draw_player(next())
			}
		}
		return
	}

	textbox.set_visible(true)
	left_width := clamp(bounds.w * .42, 460, 540)
	if layout(bounds, .Row, {px(left_width), fr()}, pad = pad_all(8), gap = 8) {
		draw_library_panel(next())
		draw_player(next())
	}
}

draw_library_panel :: proc(bounds: fx.Rect) {
	if layout(bounds, .Col, {px(42), fr()}, gap = 8) {
		draw_search_box(next())
		content := next()
		if search.active {
			draw_songs(content)
		} else if layout(content, .Row, {px(clamp(content.w * .3, 150, 180)), fr()}, gap = 8) {
			draw_playlists(next())
			draw_songs(next())
		}
	}
}

draw_playlists :: proc(bounds: fx.Rect) {
	fx.draw_rect(bounds, COLOR_SURFACE, 9)
	if layout(bounds, .Col, {px(48), fr()}) {
		header := next()
		label(header, "Playlists", 16, text_style(COLOR_TEXT), center_x = true)
		content := next()
		if layout(
			content,
			.Col,
			pad = pad_all(6),
			gap = 5,
			can_scroll = true,
			layout_id = id("playlists"),
		) {
			for playlist, index in playlists {
				row := next_size(px(30))
				if !is_visible(row) do continue
				count := index == LIKED_PLAYLIST_INDEX ? liked_playlist_count() : len(playlist.songs)
				row_id := id(fmt.tprintf("playlist-%d", index))
				hit := interact(row_id, row)
				selected := index == selected_playlist
				row_colors := style_state(ICON_BUTTON_STYLE, hit, selected = selected)
				background := animate(id("background", row_id), row_colors.bg, HOVER_DURATION, .Sine_In_Out)
				text_color := animate(id("text", row_id), row_colors.text, HOVER_DURATION, .Sine_In_Out)
				fx.draw_rect(row, background, 6)
				if hit.clicked && selected_playlist != index {
					liked_playlist_refresh()
					selected_playlist = index
				}
				if hit.hovered {
					fx.set_cursor(.Hand)
				}

				if playlist.icon != nil {
					if layout(row, .Row, {px(16), fr(), px(28)}, pad = pad_all(7), gap = 8) {
						fx.draw_texture(playlist.icon^, square_bounds(next()), text_color)
						label(next(), playlist.name, 13, text_style(text_color))
						count_text := fmt.tprintf("%d", count)
						count_bounds := next()
						count_width := fx.measure_text(count_text, 10).x
						label(
							{count_bounds.x + count_bounds.w - count_width, count_bounds.y, count_width, count_bounds.h},
							count_text,
							10,
							text_style(COLOR_MUTED),
						)
					}
				} else if layout(row, .Row, {fr(), px(28)}, pad = pad_all(7), gap = 8) {
					label(next(), playlist.name, 13, text_style(text_color))
					count_text := fmt.tprintf("%d", count)
					count_bounds := next()
					count_width := fx.measure_text(count_text, 10).x
					label(
						{count_bounds.x + count_bounds.w - count_width, count_bounds.y, count_width, count_bounds.h},
						count_text,
						10,
						text_style(COLOR_MUTED),
					)
				}
			}
		}
	}
}

draw_playlist_header :: proc(bounds: fx.Rect, playlist: ^Playlist) {
	text := PLAYLIST_SORT_LABELS[playlist.sort]
	text_width := fx.measure_text(text, 12).x
	text_button_width := text_width + 20
	icon_button_width := f32(30)

	if layout(bounds, .Row, {fr(), px(text_button_width), px(icon_button_width)}, pad = {left = 16, top = 8, right = 8, bottom = 8}, gap = 6) {
		fx.draw_text_faded(playlist.name, next(), 16, COLOR_TEXT, false, true)
		text_bounds := next()
		if button(id("playlist-sort", id(playlist.name)), text_bounds, text) {
			playlist.sort = Playlist_Sort((int(playlist.sort) + 1) % len(PLAYLIST_SORT_LABELS))
			playlist_sort(playlist)
			scroll_to(id("songs", id(playlist.name)), 0)
		}

		icon_bounds := next()
		sort_icon := sort_icons[playlist.sort_reversed ? 1 : 0][playlist.sort]
		if button(id("playlist-direction", id(playlist.name)), icon_bounds, "") {
			playlist.sort_reversed = !playlist.sort_reversed
			playlist_sort(playlist)
			scroll_to(id("songs", id(playlist.name)), 0)
		}
		icon_color := animate(
			id("playlist-direction-icon", id(playlist.name)),
			mouse_visible(icon_bounds) ? COLOR_TEXT : COLOR_MUTED,
			HOVER_DURATION,
			.Sine_In_Out,
		)
		fx.draw_texture(icons[sort_icon], square_bounds(icon_bounds, 7), icon_color)
	}
}

draw_songs :: proc(bounds: fx.Rect) {
	fx.draw_rect(bounds, COLOR_SURFACE, 9)
	if len(playlists) == 0 {
		label(bounds, "Loading music…", 13, text_style(COLOR_MUTED), center_x = true)
		return
	}
	selected_playlist = clamp(selected_playlist, 0, len(playlists) - 1)
	playlist := &playlists[selected_playlist]
	songs := playlist.songs[:]
	list_id := id(playlist.name)
	if search.active {
		songs = search.results[:]
		list_id = id("search-results")
	}
	active_marker := f32(-1)
	if player.music != nil {
		for song, index in songs {
			if song == player.music {
				active_marker = (f32(index) + .5) / f32(len(songs))
				break
			}
		}
	}

	header_height := search.active ? f32(0) : f32(48)
	if layout(bounds, .Col, {px(header_height), fr()}) {
		header := next()
		if !search.active {
			draw_playlist_header(header, playlist)
		}

		if layout(next(), .Col, pad = pad_xy(8, 8), gap = 5, can_scroll = true, layout_id = id("songs", list_id), scroll_marker = active_marker) {
			if len(songs) == 0 {
				message := loader_is_finished() ? "No tracks" : "Loading music…"
				label(next_size(px(54)), message, 12, text_style(COLOR_MUTED), center_x = true)
			}

			for song, index in songs {
				row := next_size(px(56))
				if is_visible(row) {
					draw_song_row(row, song, index, songs)
				}
			}
		}
	}
}

draw_song_row :: proc(bounds: fx.Rect, song: ^Music, index: int, songs: []^Music) {
	row_id := id("song", id(song.fullpath))
	play_bounds := fx.Rect{bounds.x, bounds.y, max(bounds.w - 55, 0), bounds.h}
	hit := interact(row_id, play_bounds)
	active := player.music == song
	row_style := active ? ACTIVE_BUTTON_STYLE : ICON_BUTTON_STYLE
	row_colors := style_state(row_style, hit)
	background := animate(id("background", row_id), row_colors.bg, HOVER_DURATION, .Sine_In_Out)
	text_color := animate(id("text", row_id), row_colors.text, HOVER_DURATION, .Sine_In_Out)
	fx.draw_rect(bounds, background, 6)
	if hit.clicked do player_start_playlist(songs, index)
	if hit.hovered && fx.key_is_pressed(.Mouse_Right) do open_context_menu(song)
	if hit.hovered do fx.set_cursor(.Hand)

	if layout(bounds, .Row, {px(42), fr(), px(48)}, pad = pad_xy(6, 6), gap = 10) {
		cover := next()
		background := animate(
			id("thumbnail-placeholder-background", row_id),
			active || hit.held ? fx.Color{72, 80, 94, 255} : COLOR_BORDER,
			HOVER_DURATION,
			.Sine_In_Out,
		)
		draw_cover(song.thumbnail, cover, background = background)
		text_bounds := next()
		if layout(text_bounds, .Col, {px(25), px(17)}) {
			label(next(), song.title, 14, text_style(text_color))
			secondary := song.artist
			if secondary == "" {
				secondary = song.album
			}
			label(next(), secondary, 11, text_style(COLOR_MUTED))
		}
		like_icon: Icon = song.liked ? .Heart : .Heart_Empty
		like_style := active ? ACTIVE_ICON_BUTTON_STYLE : LIKE_BUTTON_STYLE
		like_style.normal.text = COLOR_MUTED
		like_style.hover.text = COLOR_MUTED
		like_style.press.text = COLOR_MUTED
		if icon_button(id("like-song", row_id), next(), like_icon, style = like_style) {
			toggle_like(song)
		}
	}
}

draw_cover :: proc(texture: fx.Texture, bounds: fx.Rect,radius := f32(6), background := COLOR_BORDER) {
	if texture.srv != nil {
		size := fx.Vec2(texture.size)
		crop := min(size.x, size.y)
		source := fx.Rect{(size.x - crop) * .5, (size.y - crop) * .5, crop, crop}
		fx.draw_texture_ex(texture, source, bounds, fx.WHITE, radius)
		return
	}

	fx.draw_rect(bounds, background, radius)
	draw_icon(.Note, bounds, COLOR_MUTED, min(bounds.w, bounds.h) * .3)
}

draw_player :: proc(bounds: fx.Rect) {
	fx.draw_rect(bounds, COLOR_SURFACE, 8)
	if len(visualizer_palette) > 0 {
		tint_height := min(bounds.h, f32(278))
		top := visualizer_color_at(0)
		bottom := visualizer_color_at(.65)
		middle := fx.color_lerp(top, bottom, .5)
		fx.draw_rect(
			{bounds.x, bounds.y, bounds.w, tint_height},
			{fx.color_opacity(top, .10), fx.color_opacity(middle, .05), fx.color_opacity(middle, 0), fx.color_opacity(bottom, 0)},
			8,
		)
	}

	if layout(bounds, .Col, {px(190), px(88), fr()}) {
		draw_now_playing(next())
		draw_player_controls(next())
		content := next()
		if queue_active {
			draw_queue(content)
		} else {
			draw_lyrics(content)
		}
	}
}

draw_now_playing :: proc(bounds: fx.Rect) {
	if player.music == nil {
		draw_icon(.Note, bounds, fx.color_opacity(COLOR_MUTED, .35), min(bounds.w, bounds.h) * .38)
		queue_bounds := fx.Rect{bounds.x + bounds.w - 52, bounds.y + 14, 36, 36}
		if icon_button(id("queue"), queue_bounds, .Queue, selected = queue_active) {
			queue_active = !queue_active
			if !queue_active do queue_drag = {}
		}
		return
	}

	if layout(bounds, .Row, {px(160), fr()}, pad = pad_all(16), gap = 18) {
		draw_cover(player.cover, next(), 8)
		info := next()
		if layout(info, .Col, {px(48), px(28), px(10), fr()}) {
			title_row := next()
			if layout(title_row, .Row, {fr(), px(36)}, gap = 10) {
				label(next(), player.music.title, 27, text_style(COLOR_TEXT))
				if icon_button(id("queue"), next(), .Queue, selected = queue_active) {
					queue_active = !queue_active
					if !queue_active do queue_drag = {}
				}
			}

			metadata := next()
			artist_width := player.music.artist != "" ? min(fx.measure_text(player.music.artist, 16).x + 1, metadata.w * .48) : 0
			album_width := player.music.album != "" ? min(fx.measure_text(player.music.album, 16).x + 1, max(metadata.w - artist_width - 20, 0)) : 0
			dot_size := artist_width > 0 && album_width > 0 ? f32(20) : 0

			if artist_width > 0 || album_width > 0 {
				if layout(metadata, .Row, {px(artist_width), px(dot_size), px(album_width)}) {
					if artist_width > 0 {
						if link(id("artist", id(player.music.fullpath)), next(), player.music.artist, 16) {
							search_open(artist = player.music.artist)
						}
					}

					separator := next()
					if dot_size > 0 {
						fx.draw_circle({separator.x + separator.w * .5, separator.y + separator.h * .5}, 2, COLOR_MUTED)
					}

					if album_width > 0 {
						if link(id("album", id(player.music.fullpath)), next(), player.music.album, 16) {
							search_open(album = player.music.album)
						}
					}
				}
			}
			next()
			draw_visualizer(next())
		}
	}
}

draw_player_controls :: proc(bounds: fx.Rect) {
	if layout(bounds, .Col, {px(26), px(36)}, pad = pad_all(5), gap = 8) {
		progress_row := next()
		duration := audio.duration()
		position := audio.position()
		if scrub_time >= 0 do position = scrub_time
		position_text := format_time(position)
		duration_text := format_time(duration)
		position_width := fx.measure_text(position_text, 10).x
		duration_width := fx.measure_text(duration_text, 10).x
		if layout(progress_row, .Row, {px(position_width), fr(), px(duration_width), px(20), px(88)}, pad_xy(8, 0), gap = 12) {
			label(next(), position_text, 10, text_style(COLOR_MUTED), center_x = true)
			progress_bounds := next()
			progress := slider(id("progress"), progress_bounds, &position, 0, max(duration, 1), disabled = player.music == nil)
			if progress.held {
				scrub_time = position
				lyrics_synced = true
			}
			if progress.released {
				if scrub_time >= 0 do player_seek(scrub_time)
				scrub_time = -1
			}
			if progress.held {
				draw_slider_tooltip(progress_bounds, position / max(duration, 1), format_time(position))
			}
			label(next(), duration_text, 10, text_style(COLOR_MUTED), center_x = true)
			volume_icon: Icon = audio.muted ? .Mute : .Volume
			volume_bounds := next()
			volume_bounds.x += 3
			volume_hit := interact(id("mute"), volume_bounds)
			draw_icon(volume_icon, volume_bounds, COLOR_MUTED, 2)
			if volume_hit.clicked {
				audio.muted = !audio.muted
				audio.reset()
			}
			if volume_hit.hovered do fx.set_cursor(.Hand)
			volume_slider_bounds := next()
			volume_style := audio.muted ? MUTED_SLIDER_STYLE : SLIDER_STYLE
			volume_slider := slider(id("volume"), volume_slider_bounds, &audio.volume, 0, 1, volume_style)
			if !ui_ctx.overlay && mouse_visible(volume_slider_bounds) && fx.mouse_scroll().y != 0 {
				audio.volume = clamp(audio.volume + fx.mouse_scroll().y * .05, 0, 1)
			}
			if volume_slider.held {
				draw_slider_tooltip(volume_slider_bounds, audio.volume, fmt.tprintf("%d%%", int(audio.volume * 100 + .5)))
			}
		}

		if layout(next(), .Row, {fr(), px(36), px(36), px(36), px(36), px(36), fr()}, gap = 8) {
			next()
			shuffle_style := player.shuffle ? ACTIVE_ICON_BUTTON_STYLE : ICON_BUTTON_STYLE
			if icon_button(id("shuffle"), next(), .Shuffle, selected = player.shuffle, disabled = player.music == nil, style = shuffle_style) do player_toggle_shuffle()
			if icon_button(id("previous"), next(), .Previous, disabled = player.music == nil) do player_prev()
			play_icon: Icon = player.playing ? .Pause : .Play
			if icon_button(id("play"), next(), play_icon, selected = true, disabled = player.music == nil) do player_toggle_pause()
			if icon_button(id("next"), next(), .Next, disabled = player.music == nil) do player_next()
			liked := player.music != nil && player.music.liked
			like_icon: Icon = liked ? .Heart : .Heart_Empty
			if icon_button(id("like"), next(), like_icon, disabled = player.music == nil, style = LIKE_BUTTON_STYLE) do toggle_like(player.music)
			next()
		}
	}
}

draw_slider_tooltip :: proc(bounds: fx.Rect, value: f32, text: string) {
	width := fx.measure_text(text, 11).x + 14
	thumb_x := bounds.x + bounds.w * clamp(value, 0, 1)
	x := clamp(thumb_x - width * .5, bounds.x, bounds.x + bounds.w - width)
	tooltip := fx.Rect{x, bounds.y - 17, width, 21}
	fx.draw_rect({tooltip.x, tooltip.y + 2, tooltip.w, tooltip.h}, fx.color_opacity(COLOR_BACKGROUND, .72), 6)
	fx.draw_rect(tooltip, COLOR_BORDER, 6)
	fx.draw_rect(fx.rect_shrink(tooltip, 1, 1), COLOR_HOVER, 5)
	label(tooltip, text, 11, text_style(COLOR_TEXT), center_x = true)
}

draw_lyrics :: proc(bounds: fx.Rect) {
	if player.music == nil || len(player.music.lyrics) == 0 {
		icon_size := min(f32(28), bounds.w * .1)
		fx.draw_texture(
			icons[.Note],
			{bounds.x + (bounds.w - icon_size) * .5, bounds.y + (bounds.h - icon_size) * .5, icon_size, icon_size},
			fx.color_opacity(COLOR_MUTED, .25),
		)
		return
	}
	active, found := current_lyric()
	lyrics_id := id("lyrics", id(player.music.fullpath))
	lyrics_scroll_id := id("scroll", lyrics_id)
	for state in ui_ctx.scrolls {
		if state.id == lyrics_scroll_id && state.thumb_held do lyrics_synced = false
	}
	if mouse_visible(bounds) && fx.mouse_scroll().y != 0 do lyrics_synced = false
	if lyrics_synced && found {
		scroll_to(lyrics_id, 20 + f32(active) * 60 + 30 - bounds.h * .5)
	}
	lyric_marker := found ? (f32(active) + .5) / f32(len(player.music.lyrics)) : f32(-1)
	if layout(
		bounds,
		.Col,
		pad = pad_all(20),
		can_scroll = true,
		layout_id = lyrics_id,
		scroll_speed = 8,
		scroll_marker = lyric_marker,
	) {
		for lyric, index in player.music.lyrics {
			row := next_size(px(60))
			if !is_visible(row) do continue
			row_id := id("lyric", id(fmt.tprintf("%s-%d", player.music.fullpath, index)))
			hit := interact(row_id, row)
			is_active := found && index == active
			active_amount := smooth_f32(id("active", row_id), is_active ? f32(1) : f32(0), 15)
			hover_amount := smooth_f32(id("hover", row_id), hit.hovered ? f32(1) : f32(0), 15)
			color := fx.color_lerp(COLOR_MUTED, COLOR_TEXT, max(active_amount, hover_amount))
			if lyric.text == "" {
				icon_size := 24 + 4 * active_amount
				fx.draw_texture(icons[.Note], {row.x + 3, row.y + (row.h - icon_size) * .5, icon_size, icon_size}, color)
			} else {
				fx.draw_text_faded(lyric.text, row, 18 + 4 * active_amount, color)
			}
			if hit.clicked {
				player_seek(lyric.time)
				lyrics_synced = true
			}
			if hit.hovered do fx.set_cursor(.Hand)
		}
	}
}

Context_Menu :: struct {
	song:   ^Music,
	bounds: fx.Rect,
}

context_menu: Context_Menu

open_context_menu :: proc(song: ^Music) {
	size := fx.window_size()
	position := fx.mouse_pos()
	width := f32(190)
	height := f32(148)
	position.x = clamp(position.x, 10, max(10, size.x - width - 10))
	position.y = clamp(position.y, 10, max(10, size.y - height - 10))
	context_menu = {song = song, bounds = {position.x, position.y, width, height}}
}

draw_context_menu :: proc() {
	song := context_menu.song
	if song == nil do return
	ui_ctx.overlay = true
	bounds := context_menu.bounds
	fx.draw_rect(fx.rect_expand(bounds, 1, 1), COLOR_BORDER, 9)
	fx.draw_rect(bounds, COLOR_SURFACE, 8)
	labels := [5]string{song.liked ? "Unlike" : "Like", "Play next", "Add to queue", "Show artist", "Show album"}
	menu_icons := [5]Icon{.Heart, .Add_Next, .Add_Last, .Artist, .Album}
	if layout(bounds, .Col, {px(28), px(28), px(28), px(28), px(28)}, pad = pad_all(4)) {
		for text, index in labels {
			row := next()
			disabled := index == 3 && song.artist == "" || index == 4 && song.album == ""
			hit := interact(id(fmt.tprintf("context-%d", index)), row, disabled, true)
			if hit.hovered do fx.draw_rect(row, COLOR_HOVER, 6)
			tint := disabled ? fx.color_opacity(COLOR_MUTED, .28) : hit.hovered ? COLOR_TEXT : COLOR_MUTED
			draw_icon(menu_icons[index], {row.x + 7, row.y, 20, row.h}, tint, 2)
			label({row.x + 36, row.y, row.w - 45, row.h}, text, 13, text_style(tint))
			if hit.hovered do fx.set_cursor(.Hand)
			if hit.clicked {
				switch index {
				case 0: toggle_like(song)
				case 1: player_queue_add(song, true)
				case 2: player_queue_add(song)
				case 3: search_open(artist = song.artist)
				case 4: search_open(album = song.album)
				}
				context_menu = {}
				return
			}
		}
	}
	if (fx.key_is_pressed(.Mouse_Left) || fx.key_is_pressed(.Mouse_Right)) &&
	   !fx.point_in_rect(fx.mouse_pos(), bounds) {
		context_menu = {}
	}
}

handle_keyboard_input :: proc() {
	if fx.key_is_pressed(.Esc) && context_menu.song != nil {
		context_menu = {}
		return
	}
	if textbox.focused() do return
	if fx.key_is_down(.Ctrl) && fx.key_is_pressed(.F) {
		search_open()
		return
	}
	if fx.key_is_pressed(.Esc) && search.active {
		search_close()
		return
	}
	if fx.key_is_pressed_repeat(.Up) do audio.volume = clamp(audio.volume + .05, 0, 1)
	if fx.key_is_pressed_repeat(.Down) do audio.volume = clamp(audio.volume - .05, 0, 1)
	if player.music == nil do return
	if fx.key_is_pressed(.Space) do player_toggle_pause()
	if fx.key_is_down(.Ctrl) {
		lyric_index, lyric_found := current_lyric()
		position := scrub_time >= 0 ? scrub_time : audio.position()
		if fx.key_is_pressed_repeat(.Left) {
			if !lyric_found && len(player.music.lyrics) > 0 && position >= player.music.lyrics[len(player.music.lyrics) - 1].time {
				player_seek(player.music.lyrics[lyric_index].time)
			} else {
				player_seek(lyric_index > 0 ? player.music.lyrics[lyric_index - 1].time : 0)
			}
		}
		if fx.key_is_pressed_repeat(.Right) {
			if len(player.music.lyrics) == 0 do player_next()
			else if !lyric_found && position < player.music.lyrics[0].time do player_seek(player.music.lyrics[0].time)
			else if lyric_index < len(player.music.lyrics) - 1 do player_seek(player.music.lyrics[lyric_index + 1].time)
			else do player_next()
		}
		lyrics_synced = true
	} else {
		if fx.key_is_pressed_repeat(.Left) do player_seek(max(audio.position() - 5, 0))
		if fx.key_is_pressed_repeat(.Right) do player_seek(min(audio.position() + 5, audio.duration()))
	}
}

format_time :: proc(seconds: f32) -> string {
	value := max(int(seconds), 0)
	return fmt.tprintf("%d:%02d", value / 60, value % 60)
}
