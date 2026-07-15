package main

import "core:fmt"

import "fx"
import "fx/audio"
import "fx/smtc"

UI_ID :: distinct u64

UI_NONE     :: UI_ID(0)
UI_PROGRESS :: UI_ID(1)
UI_VOLUME   :: UI_ID(2)

ui_active: UI_ID

Compact_Tab :: enum {
	Library,
	Player,
}

compact_tab: Compact_Tab
selected_playlist: int
lyrics_synced := true
scrub_time := f32(-1)

main :: proc() {
	fx.init("GriPlayer")
	fx.text_box_init("Search tracks, artists, lyrics")
	audio.initialize()
	smtc.init(fx.window.hwnd)
	fft_init()

	icons = {
		.Album    = fx.texture_load(#load("assets/icons/album.png")),
		.Artist   = fx.texture_load(#load("assets/icons/artist.png")),
		.Heart    = fx.texture_load(#load("assets/icons/heart.png")),
		.Next     = fx.texture_load(#load("assets/icons/next.png")),
		.Note     = fx.texture_load(#load("assets/icons/note.png")),
		.Pause    = fx.texture_load(#load("assets/icons/pause.png")),
		.Play     = fx.texture_load(#load("assets/icons/play.png")),
		.Previous = fx.texture_load(#load("assets/icons/previous.png")),
		.Queue    = fx.texture_load(#load("assets/icons/queue.png")),
		.Add_Last = fx.texture_load(#load("assets/icons/add_last.png")),
		.Add_Next = fx.texture_load(#load("assets/icons/add_next.png")),
		.Search   = fx.texture_load(#load("assets/icons/search.png")),
		.Shuffle  = fx.texture_load(#load("assets/icons/shuffle.png")),
		.Volume   = fx.texture_load(#load("assets/icons/volume.png")),
		.Mute     = fx.texture_load(#load("assets/icons/mute.png")),
		.Cross    = fx.texture_load(#load("assets/icons/cross.png")),
	}

	loader_start()

	fx.set_frame_callback(frame)
	for fx.update() {
		frame()
	}

	cache_save()
}

frame :: proc() {
	loader_poll()
	size := fx.window_size()
	handle_keyboard_input()
	update_search()
	player_update()

	if player.playing && player.music != nil {
		player.music.playtime += fx.frame_time()
	}

	fx.clear_window(COLOR_BACKGROUND)
	if size.x < 800 {
		if layout_begin({0, 0, size.x, size.y}, {42, GROW}, .Vertical, padding = 8, gap = 8) {
			draw_compact_tabs(layout_next())
			content := layout_next()
			if compact_tab == .Library {
				fx.text_box_set_visible(true)
				draw_library_panel(content)
			} else {
				search.focused = false
				fx.text_box_set_visible(false)
				draw_player_panel(content)
			}
		}
	} else {
		fx.text_box_set_visible(true)
		left_width := clamp(size.x * .42, 460, 540)
		if layout_begin({0, 0, size.x, size.y}, {left_width, GROW}, .Horizontal, padding = 8, gap = 8) {
			draw_library_panel(layout_next())
			draw_player_panel(layout_next())
		}
	}

	draw_context_menu()
	fx.present()
	free_all(context.temp_allocator)
}

draw_library_panel :: proc(bounds: fx.Rect) {
	if layout_begin(bounds, {42, GROW}, .Vertical, gap = 8) {
		draw_search_box(layout_next())
		content := layout_next()
		if search.active {
			fx.draw_rect(content, COLOR_SURFACE, 8)
			draw_song_list(content, &search_scroll, search.results[:], "No songs found")
		} else {
			library_width := clamp(content.w * .30, 150, 180)
			if layout_begin(content, {library_width, GROW}, .Horizontal, gap = 8) {
				draw_library(layout_next())
				draw_playlist(layout_next())
			}
		}
	}
}

draw_player_panel :: proc(bounds: fx.Rect) {
	fx.draw_rect(bounds, COLOR_SURFACE, 8)
	tint_height := min(bounds.h, f32(190 + 88))
	draw_player_palette_tint({bounds.x, bounds.y, bounds.w, tint_height})
	if layout_begin(bounds, {190, 88, GROW}, .Vertical) {
		draw_now_playing(layout_next())
		draw_player_controls(layout_next())
		content := layout_next()
		if queue_active {
			draw_queue(content)
		} else {
			draw_lyrics(content)
		}
	}
}

draw_compact_tabs :: proc(bounds: fx.Rect) {
	fx.draw_rect(bounds, COLOR_SURFACE, 8)
	if layout_begin(bounds, {GROW, GROW}, .Horizontal, padding = 4, gap = 4) {
		draw_compact_tab(layout_next(), "Library", .Library)
		draw_compact_tab(layout_next(), "Player", .Player)
	}
}

draw_compact_tab :: proc(bounds: fx.Rect, label: string, tab: Compact_Tab) {
	selected := compact_tab == tab
	hovered := ui_hover(bounds)
	hover_anim := ui_animate(ui_id(70, uint(tab)), hovered)
	if selected {
		fx.draw_rect(bounds, fx.color_lerp(COLOR_SURFACE, COLOR_HOVER, hover_anim), 6)
	} else if hover_anim > .001 {
		fx.draw_rect(bounds, fx.color_opacity(COLOR_HOVER, hover_anim), 6)
	}
	text_anim := selected ? f32(1) : hover_anim
	fx.draw_text(label, bounds, 13, fx.color_lerp(COLOR_MUTED, COLOR_TEXT, text_anim), true, true)
	if selected {
		indicator_width := min(bounds.w * .28, 42)
		fx.draw_rect(
			{bounds.x + (bounds.w - indicator_width) * .5, bounds.y + bounds.h - 3, indicator_width, 2},
			COLOR_ACCENT_BRIGHT,
			1,
		)
	}
	if hovered {
		fx.set_cursor(.Hand)
		if fx.key_is_pressed(.Mouse_Left) do compact_tab = tab
	}
}

handle_keyboard_input :: proc() {
	if fx.key_is_pressed(.Esc) && context_menu.song != nil {
		context_menu = {}
		return
	}
	if search.focused do return
	if fx.key_is_down(.Ctrl) && fx.key_is_pressed(.F) {
		if fx.window_size().x < 720 {
			compact_tab = .Library
			fx.text_box_set_visible(true)
		}
		search_open()
		return
	}
	if fx.key_is_pressed(.Esc) && search.active {
		search_close()
		return
	}
	if fx.key_is_pressed_repeat(.Up) {
		audio.volume = clamp(audio.volume + .05, 0, 1)
	}
	if fx.key_is_pressed_repeat(.Down) {
		audio.volume = clamp(audio.volume - .05, 0, 1)
	}
	if player.music == nil do return

	if fx.key_is_pressed(.Space) do player_toggle_pause()
	if fx.key_is_down(.Ctrl) {
		lyric_index, lyric_found := current_lyric()
		lyric_time := scrub_time >= 0 ? scrub_time : audio.position()
		if fx.key_is_pressed_repeat(.Left) {
			if !lyric_found && len(player.music.lyrics) > 0 && lyric_time >= player.music.lyrics[len(player.music.lyrics) - 1].time {
				player_seek(player.music.lyrics[lyric_index].time)
			} else {
				player_seek(lyric_index > 0 ? player.music.lyrics[lyric_index - 1].time : 0)
			}
		}
		if fx.key_is_pressed_repeat(.Right) {
			if len(player.music.lyrics) == 0 {
				player_next()
			} else if !lyric_found && lyric_time < player.music.lyrics[0].time {
				player_seek(player.music.lyrics[0].time)
			} else if lyric_index < len(player.music.lyrics) - 1 {
				player_seek(player.music.lyrics[lyric_index + 1].time)
			} else {
				player_next()
			}
		}
		lyrics_synced = true
	} else {
		if fx.key_is_pressed_repeat(.Left) do player_seek(max(0, audio.position() - 5))
		if fx.key_is_pressed_repeat(.Right) do player_seek(min(audio.duration(), audio.position() + 5))
	}
}


draw_library :: proc(bounds: fx.Rect) {
	fx.draw_rect(bounds, COLOR_SURFACE, 8)
	if layout_begin(bounds, {48, GROW}, .Vertical) {
		header := layout_next()
		content := layout_next()
		fx.draw_text("Playlists", header, 16, COLOR_TEXT, true, true)
		fx.draw_rect({header.x + 10, header.y + header.h - 1, header.w - 20, 1}, COLOR_BORDER)

		if layout_begin(content, padding = 8, gap = 5, scroll = &library_scroll, background = COLOR_SURFACE) {
			for playlist, index in playlists {
				row := layout_next(30)
				if !fx.rect_overlaps(row, content) do continue
				hovered := ui_hover(content) && ui_hover(row)
				hover_anim := ui_animate(ui_id(10, uint(index)), hovered)
				selected := index == selected_playlist

				if selected {
					fx.draw_rect(row, COLOR_ACCENT_DARK, 6)
				} else if hover_anim > .001 {
					fx.draw_rect(row, fx.color_opacity(COLOR_HOVER, hover_anim), 6)
				}

				if hovered {
					fx.set_cursor(.Hand)
					if fx.key_is_pressed(.Mouse_Left) {
						selected_playlist = index
						playlist_scroll = {}
					}
				}

				count := fmt.tprintf("%d", len(playlist.songs))
				fx.draw_text_faded(playlist.name, {row.x + 10, row.y, row.w - 48, row.h}, 13, selected || hovered ? COLOR_TEXT : COLOR_MUTED)
				fx.draw_text(count, fx.Rect{row.x + row.w - 38, row.y, 28, row.h}, 10, COLOR_MUTED, true, true)
			}
		}
	}
}

draw_playlist :: proc(bounds: fx.Rect) {
	playlist := &playlists[selected_playlist]

	fx.draw_rect(bounds, COLOR_SURFACE, 8)
	if layout_begin(bounds, {48, GROW}, .Vertical) {
		header := layout_next()
		content := layout_next()
		fx.draw_text_faded(playlist.name, header, 16, COLOR_TEXT, true, true)
		fx.draw_rect({header.x + 10, header.y + header.h - 1, header.w - 20, 1}, COLOR_BORDER)
		draw_song_list(content, &playlist_scroll, playlist.songs[:], "No tracks", 14, 11)
	}
}

draw_song_list :: proc(
	bounds: fx.Rect,
	scroll: ^Scroll_State,
	songs: []^Music,
	empty_label: string,
	title_font_size := f32(13),
	artist_font_size := f32(10),
) {
	if layout_begin(bounds, padding = 8, gap = 5, scroll = scroll, background = COLOR_SURFACE) {
		if len(songs) == 0 {
			fx.draw_text(empty_label, layout_next(48), 12, COLOR_MUTED, true, true)
		}

		for song, index in songs {
			row := layout_next(54)
			if !fx.rect_overlaps(row, bounds) do continue
			hovered := ui_hover(bounds) && ui_hover(row)
			hover_anim := ui_animate(ui_id(20, uint(uintptr(song))), hovered)
			playing := player.music == song
			if playing {
				fx.draw_rect(row, COLOR_ACCENT_DARK, 6)
			} else if hover_anim > .001 {
				fx.draw_rect(row, fx.color_opacity(COLOR_HOVER, hover_anim), 6)
			}
			if hovered {
				fx.set_cursor(.Hand)
				if fx.key_is_pressed(.Mouse_Left) {
					player_start_playlist(songs, index)
				}
				if fx.key_is_pressed(.Mouse_Right) {
					open_context_menu(song)
				}
			}

			draw_cover(song.thumbnail, {row.x + 6, row.y + 6, 42, 42}, 6)
			text_width := max(0, row.w - 70 - 48)
			title_color := fx.color_lerp(COLOR_MUTED, COLOR_TEXT, hover_anim)
			if playing do title_color = COLOR_TEXT
			fx.draw_text_faded(song.title, {row.x + 58, row.y + 5, text_width, 25}, title_font_size, title_color, false, true)

			secondary := song.artist
			if secondary == "" do secondary = song.album
			fx.draw_text_faded(secondary, {row.x + 58, row.y + 28, text_width, 18}, artist_font_size, COLOR_MUTED, false, true)
			fx.draw_text(format_time(song.duration), fx.Rect{row.x + row.w - 48, row.y, 40, row.h}, 11, COLOR_MUTED, true, true)
		}
	}
}

draw_now_playing :: proc(bounds: fx.Rect) {
	song := player.music
	if song == nil {
		icon_size := min(f32(42), bounds.w * .12)
		fx.draw_texture(
			icons[.Note],
			{
				bounds.x + (bounds.w - icon_size) * .5,
				bounds.y + (bounds.h - icon_size) * .5,
				icon_size,
				icon_size,
			},
			fx.color_opacity(COLOR_MUTED, .35),
		)
		draw_queue_toggle(bounds)
		return
	}

	cover := fx.Rect{bounds.x + 16, bounds.y + 14, bounds.h - 28, bounds.h - 28}
	draw_cover(player.cover, cover, 8)

	text_x := cover.x + cover.w + 18
	text_width := max(0, bounds.x + bounds.w - 18 - text_x)
	title_width := max(0, text_width - 47)
	fx.draw_text_faded(song.title, {text_x, bounds.y + 23, title_width, 40}, 27, COLOR_TEXT, false, true)
	artist_limit := song.album != "" ? text_width * .48 : text_width
	artist_width := song.artist != "" ? min(fx.measure_text(song.artist, 16).x + 1, artist_limit) : 0
	album_width := song.album != "" ? min(fx.measure_text(song.album, 16).x + 1, max(text_width - artist_width - 20, 0)) : 0
	metadata_slots := make([dynamic]f32, 0, 3, context.temp_allocator)
	if artist_width > 0 do append(&metadata_slots, artist_width)
	if artist_width > 0 && album_width > 0 do append(&metadata_slots, f32(4))
	if album_width > 0 do append(&metadata_slots, album_width)

	metadata := fx.Rect{text_x, bounds.y + 70, text_width, 25}
	if len(metadata_slots) > 0 {
		if layout_begin(metadata, metadata_slots[:], .Horizontal, gap = 8) {
			if artist_width > 0 {
				if draw_label(song.artist, layout_next(), 16) {
					search_open(artist = song.artist)
				}
			}
			if artist_width > 0 && album_width > 0 {
				dot := layout_next()
				fx.draw_circle({dot.x + dot.w * .5, dot.y + dot.h * .5}, 2, COLOR_MUTED)
			}
			if album_width > 0 {
				if draw_label(song.album, layout_next(), 16) {
					search_open(album = song.album)
				}
			}
		}
	}

	draw_visualizer({text_x, bounds.y + bounds.h - 58, text_width, 42})
	draw_queue_toggle(bounds)
}

draw_label :: proc(text: string, bounds: fx.Rect, font_size: f32, idle_color := COLOR_MUTED) -> bool {
	if text == "" || bounds.w <= 0 do return false
	link_width := min(fx.measure_text(text, font_size).x, bounds.w)
	hit_bounds := fx.Rect{bounds.x, bounds.y, link_width, bounds.h}
	hovered := ui_hover(hit_bounds)
	label_value := uint(uintptr(raw_data(text))) ~ uint(int(bounds.x * 16))
	hover_anim := ui_animate(ui_id(32, label_value), hovered)
	text_color := fx.color_lerp(idle_color, COLOR_TEXT, hover_anim)
	fx.draw_text_faded(text, bounds, font_size, text_color, false, true)
	if hovered {
		fx.set_cursor(.Hand)
	}
	if hover_anim > .001 {
		underline_width := hit_bounds.w * hover_anim
		fx.draw_rect(
			{
				hit_bounds.x + (hit_bounds.w - underline_width) * .5,
				hit_bounds.y + hit_bounds.h - 3,
				underline_width,
				1,
			},
			fx.color_opacity(COLOR_TEXT, hover_anim),
		)
	}
	return hovered && fx.key_is_pressed(.Mouse_Left)
}

draw_player_controls :: proc(bounds: fx.Rect) {
	fx.draw_rect({bounds.x + 10, bounds.y + bounds.h - 1, bounds.w - 20, 1}, COLOR_BORDER)

	if layout_begin(bounds, {26, 36}, .Vertical, padding = 5, gap = 8) {
		progress_row := layout_next()
		if layout_begin(progress_row, {40, GROW, 40, 20, 88}, .Horizontal, gap = 5) {
			position := audio.position()
			if scrub_time >= 0 do position = scrub_time
			fx.draw_text(format_time(position), layout_next(), 10, COLOR_MUTED, true, true)
			draw_progress_slider(layout_next())
			fx.draw_text(format_time(audio.duration()), layout_next(), 10, COLOR_MUTED, true, true)
			volume_button := layout_next()
			volume_icon_size := volume_button.h * .6
			fx.draw_texture(
				icons[audio.muted ? .Mute : .Volume],
				{
					volume_button.x + (volume_button.w - volume_icon_size) * .5 - 2,
					volume_button.y + (volume_button.h - volume_icon_size) * .5,
					volume_icon_size,
					volume_icon_size,
				},
				COLOR_MUTED,
			)
			volume_hovered := ui_hover(volume_button)
			if volume_hovered do fx.set_cursor(.Hand)
			if volume_hovered && fx.key_is_pressed(.Mouse_Left) {
				audio.muted = !audio.muted
				audio.reset()
			}
			draw_volume_slider(layout_next())
		}

		liked := player.music != nil && player.music.liked
		button_row := layout_next()
		if layout_begin(button_row, {GROW, 36, 36, 36, 36, 36, GROW}, .Horizontal, gap = 8) {
			layout_next()
			if draw_icon_button(.Shuffle, active = player.shuffle) do player_toggle_shuffle()
			if draw_icon_button(.Previous) do player_prev()
			if draw_icon_button(player.playing ? .Pause : .Play) do player_toggle_pause()
			if draw_icon_button(.Next) do player_next()
			if draw_icon_button(.Heart, active = liked) do toggle_like(player.music)
			layout_next()
		}
	}
}

draw_icon_button :: proc(icon: Icon, active := false) -> bool {
	bounds := layout_next()
	disabled := player.music == nil
	hovered := !disabled && ui_hover(bounds)
	hover_anim := ui_animate(ui_id(30, uint(icon)), hovered)
	if hovered do fx.set_cursor(.Hand)

	background := fx.color_opacity(COLOR_SURFACE, 0)
	if active {
		background = fx.color_opacity(COLOR_ACCENT, .30)
	} else if hover_anim > .001 {
		background = fx.color_opacity(COLOR_HOVER, hover_anim)
	}
	if background.a > 0 do fx.draw_rect(bounds, background, bounds.h * .5)

	icon_size := bounds.h * .45
	tint := disabled ? fx.color_opacity(COLOR_MUTED, .30) : COLOR_MUTED
	if active do tint = COLOR_TEXT
	if !active && !disabled do tint = fx.color_lerp(COLOR_MUTED, COLOR_TEXT, hover_anim)
	fx.draw_texture(
		icons[icon],
		{
			bounds.x + (bounds.w - icon_size) * .5,
			bounds.y + (bounds.h - icon_size) * .5,
			icon_size,
			icon_size,
		},
		tint,
	)
	return hovered && fx.key_is_pressed(.Mouse_Left)
}

draw_slider_tooltip :: proc(bounds: fx.Rect, value: f32, label: string) {
	width := fx.measure_text(label, 11).x + 14
	thumb_x := bounds.x + bounds.w * clamp(value, 0, 1)
	x := clamp(thumb_x - width * .5, bounds.x, bounds.x + bounds.w - width)
	tooltip := fx.Rect{x, bounds.y - 17, width, 21}
	fx.draw_rect({tooltip.x, tooltip.y + 2, tooltip.w, tooltip.h}, fx.color_opacity(COLOR_BACKGROUND, .72), 6)
	fx.draw_rect(tooltip, COLOR_BORDER, 6)
	fx.draw_rect(fx.rect_shrink(tooltip, 1, 1), COLOR_HOVER, 5)
	fx.draw_text(label, tooltip, 11, COLOR_TEXT, true, true)
}

draw_progress_slider :: proc(bounds: fx.Rect) {
	enabled := player.music != nil && audio.duration() > 0
	active := enabled && ui_active == UI_PROGRESS
	hovered := enabled && (ui_active == UI_NONE || active) && ui_hover(bounds)
	if hovered && fx.key_is_pressed(.Mouse_Left) {
		ui_active = UI_PROGRESS
		active = true
	}

	duration := audio.duration()
	value := duration > 0 ? audio.position() / duration : 0
	if scrub_time >= 0 && duration > 0 do value = scrub_time / duration
	if active {
		value = clamp((fx.mouse_pos().x - bounds.x) / max(bounds.w, 1), 0, 1)
		scrub_time = value * duration
		lyrics_synced = true
	}
	if active && fx.key_is_released(.Mouse_Left) {
		player_seek(scrub_time)
		scrub_time = -1
		ui_active = UI_NONE
		active = false
	}

	y := bounds.y + bounds.h * .5
	hover_anim := ui_animate(UI_PROGRESS, hovered || active)
	track_height := 3 + hover_anim
	fx.draw_rect({bounds.x, y - track_height * .5, bounds.w, track_height}, COLOR_BORDER, track_height * .5)
	fx.draw_rect({bounds.x, y - track_height * .5, bounds.w * value, track_height}, COLOR_ACCENT_BRIGHT, track_height * .5)
	fx.draw_circle({bounds.x + bounds.w * value, y}, 3 + hover_anim, COLOR_ACCENT_BRIGHT)
	if hovered || active do fx.set_cursor(.Hand)
	if active do draw_slider_tooltip(bounds, value, format_time(scrub_time))
}

draw_volume_slider :: proc(input_bounds: fx.Rect) {
	bounds := input_bounds
	bounds.w = max(0, bounds.w - 8)
	active := ui_active == UI_VOLUME
	hovered := (ui_active == UI_NONE || active) && ui_hover(bounds)
	if hovered && fx.key_is_pressed(.Mouse_Left) {
		ui_active = UI_VOLUME
		active = true
	}
	if active {
		audio.volume = clamp((fx.mouse_pos().x - bounds.x) / max(bounds.w, 1), 0, 1)
	}
	if hovered && fx.mouse_scroll().y != 0 {
		audio.volume = clamp(audio.volume + fx.mouse_scroll().y * .05, 0, 1)
	}
	if active && fx.key_is_released(.Mouse_Left) {
		ui_active = UI_NONE
		active = false
	}

	color := audio.muted ? COLOR_MUTED : COLOR_ACCENT_BRIGHT
	y := bounds.y + bounds.h * .5
	hover_anim := ui_animate(UI_VOLUME, hovered || active)
	track_height := 3 + hover_anim
	fx.draw_rect({bounds.x, y - track_height * .5, bounds.w, track_height}, COLOR_BORDER, track_height * .5)
	fx.draw_rect({bounds.x, y - track_height * .5, bounds.w * audio.volume, track_height}, color, track_height * .5)
	fx.draw_circle({bounds.x + bounds.w * audio.volume, y}, 3 + hover_anim, color)
	if hovered || active do fx.set_cursor(.Hand)
	if active {
		label := fmt.tprintf("%d%%", int(audio.volume * 100 + .5))
		draw_slider_tooltip(bounds, audio.volume, label)
	}
}

draw_lyrics :: proc(bounds: fx.Rect) {
	song := player.music
	if song == nil || len(song.lyrics) == 0 {
		icon_size := min(f32(28), bounds.w * .1)
		fx.draw_texture(
			icons[.Note],
			{
				bounds.x + (bounds.w - icon_size) * .5,
				bounds.y + (bounds.h - icon_size) * .5,
				icon_size,
				icon_size,
			},
			fx.color_opacity(COLOR_MUTED, .25),
		)
		return
	}

	row_height := f32(60)
	row_gap := f32(0)
	padding := f32(20)
	active, active_found := current_lyric()
	if ui_hover(bounds) && fx.mouse_scroll().y != 0 {
		lyrics_synced = false
	}

	if lyrics_synced {
		content_height := padding * 2 + f32(len(song.lyrics)) * row_height + f32(max(0, len(song.lyrics) - 1)) * row_gap
		max_scroll := max(content_height - bounds.h, 0)
		centered := padding + f32(active) * (row_height + row_gap) + row_height * .5 - bounds.h * .5
		lyrics_scroll.target = clamp(centered, 0, max_scroll)
	}

	if layout_begin(bounds, padding = padding, gap = row_gap, scroll = &lyrics_scroll, background = COLOR_SURFACE, smooth_speed = 8) {
		for lyric, index in song.lyrics {
			row := layout_next(row_height)
			if !fx.rect_overlaps(row, bounds) do continue
			visible_hover := ui_hover(bounds) && ui_hover(row)
			is_active := active_found && index == active
			lyric_value := uint(uintptr(song)) ~ (uint(index) * 0x9e3779b9)
			active_anim := ui_animate(ui_id(40, lyric_value), is_active, 15)
			hover_anim := ui_animate(ui_id(41, lyric_value), visible_hover, 15)

			if visible_hover {
				fx.set_cursor(.Hand)
				if fx.key_is_pressed(.Mouse_Left) {
					player_seek(lyric.time)
					lyrics_synced = true
				}
			}

			text_color := fx.color_lerp(COLOR_MUTED, COLOR_TEXT, max(active_anim, hover_anim))
			if lyric.text == "" {
				icon_size := 24 + 4 * active_anim
				fx.draw_texture(
					icons[.Note],
					{row.x + 3, row.y + (row.h - icon_size) * .5, icon_size, icon_size},
					text_color,
				)
			} else {
				font_size := 18 + 4 * active_anim
				fx.draw_text_faded(lyric.text, row, font_size, text_color)
			}
		}
	}
}
