package main

import "core:fmt"
import "core:math"
import "core:time"
import "core:strings"
import "core:text/edit"

import "fx"
import "fx/audio"
import "fx/smtc"

drag_id: int
playlist_id: int
lyrics_synced := true
scrub_time := f32(-1)
volume := f32(0.5)

lyrics_scroll: Scroll_State
playlist_scroll: Scroll_State
songs_scroll: Scroll_State

context_menu : struct {
	selection: ^Music,
	rect: fx.Rect,
}

main :: proc() {
	fx.init("GriPlayer")
	audio.initialize()
	smtc.init(fx.window.hwnd)
	fft_init()

	edit.init(&search.box, context.allocator, context.allocator)
	edit.setup_once(&search.box, &search.builder)

	search.box.set_clipboard = proc(user_data: rawptr, text: string) -> (ok: bool) {
		return fx.set_clipboard(text)
	}
	search.box.get_clipboard = proc(user_data: rawptr) -> (text: string, ok: bool) {
		contents := fx.get_clipboard(context.temp_allocator) or_return
		contents, _ = strings.remove_all(contents, "\n", context.temp_allocator)
		contents, _ = strings.remove_all(contents, "\r", context.temp_allocator)
		return contents, true
	}

	font = fx.load_font(#load("assets/Inter.json"), #load("assets/Inter.png"))
	icons[.Shuffle]  = fx.load_texture(#load("assets/shuffle.png"))
	icons[.Previous] = fx.load_texture(#load("assets/previous.png"))
	icons[.Pause]    = fx.load_texture(#load("assets/pause.png"))
	icons[.Play]     = fx.load_texture(#load("assets/play.png"))
	icons[.Next]     = fx.load_texture(#load("assets/next.png"))
	icons[.Heart]    = fx.load_texture(#load("assets/heart.png"))
	icons[.Volume]   = fx.load_texture(#load("assets/volume.png"))
	icons[.Note]     = fx.load_texture(#load("assets/note.png"))
	icons[.Search]   = fx.load_texture(#load("assets/search.png"))
	icons[.Cross]    = fx.load_texture(#load("assets/cross.png"))

	audio.set_volume(volume)
	load_music()
	fx.set_frame_callback(frame)
	for fx.update() {
		frame()
	}
	save_music_state()
}

frame :: proc() {
	free_all(context.temp_allocator)
	handle_input()
	player_update()

	if player.playing && player.music != nil {
		player.music.playtime += fx.frame_time()
	}

	if fx.window_is_minimized() {
		time.sleep(10 * time.Millisecond)
		return
	}

	fx.clear_window(BACKGROUND_COLOR)

	window_size := fx.window_size()

	if layout_start({0, 0, window_size.x, window_size.y}) {
		panel_size := clamp(window_size.x - 300, 0, 450)

		if layout({panel_size, GROW}, .Row, padding = 8, gap = 8) {
			if layout({48, GROW}, .Col, gap = 8) {
				draw_search_bar()

				if search.active {
					update_search()
					draw_songs_panel(search.results[:])
				} else {
					if layout({min(160, panel_size), GROW}, .Row, gap = 8) {
						draw_playlists_panel()
						draw_songs_panel(playlists[playlist_id].songs[:])
					}
				}
			}

			draw_detail_panel()
		}
	}

	draw_context_menu()

	fx.present()
}

handle_input :: proc() {
	if search.focused do return

	if fx.key_is_pressed(.Esc) && search.active do close_search()

	ctrl := fx.key_is_down(.Ctrl)

	if ctrl && fx.key_is_pressed(.F) {
		search.focused = true
		search.active = true
	}

	if fx.key_is_pressed_repeat(.Up) {
		volume = clamp(volume + 0.05, 0, 1)
		audio.set_volume(volume)
	}
	if fx.key_is_pressed_repeat(.Down) {
		volume = clamp(volume - 0.05, 0, 1)
		audio.set_volume(volume)
	}

	if player.music == nil do return

	if fx.key_is_pressed(.Space) do player_toggle_pause()

	if !ctrl && fx.key_is_pressed_repeat(.Left) {
		player_seek(max(0, audio.position() - 5.0))
	}

	if !ctrl && fx.key_is_pressed_repeat(.Right) {
		player_seek(min(audio.duration(), audio.position() + 5.0))
	}

	lyric_index := current_lyric()

	if ctrl {
		if fx.key_is_pressed_repeat(.Left)  {
			if lyric_index > 0 {
				player_seek(player.music.lyrics[lyric_index - 1].time)
			} else {
				player_seek(0)
			}
		}

		if fx.key_is_pressed_repeat(.Right) {
			if lyric_index < len(player.music.lyrics) - 1 {
				player_seek(player.music.lyrics[lyric_index + 1].time)
			} else {
				player_next()
			}
		}

		lyrics_synced = true
	}
}

draw_context_menu :: proc() {
	rect := context_menu.rect
	song := context_menu.selection
	if song == nil do return

	if fx.mouse_is_pressed(.Left) || fx.mouse_is_pressed(.Right) {
		if !fx.mouse_in_rect(rect) {
			context_menu.selection = nil
			return
		}
	}

	fx.rect(fx.rect_expand(rect, 4, 4), PRIMARY_BRIGHT, 8)
	fx.rect(fx.rect_expand(rect, 2, 2), PRIMARY_DARK, 6)

	if layout_start(rect) {
		if layout({GROW, GROW, GROW, GROW}, .Col) {
			if ui_button(int(UI_ID.Context_Menu) + 1, layout_next(), "Add to Queue", false) {
				append(&player.queue, song)
				context_menu.selection = nil
			}

			if ui_button(int(UI_ID.Context_Menu) + 2, layout_next(), "Play Next", false) {
				inject_at(&player.queue, 0, song)
				context_menu.selection = nil
			}

			if ui_button(int(UI_ID.Context_Menu) + 3, layout_next(), "Show Artist", false) {
				open_search_filtered_by(artist = song.artist)
				context_menu.selection = nil
			}

			if ui_button(int(UI_ID.Context_Menu) + 4, layout_next(), "Show Album", false) {
				open_search_filtered_by(album = song.album)
				context_menu.selection = nil
			}
		}
	}
}

draw_playlists_panel :: proc() {
	rect := layout_next()

	if layout_start(rect, &playlist_scroll, padding = 8, gap = 8) {

		for playlist, i in playlists {
			item_rect := layout_next(42)

			if !fx.rect_overlapping(rect, item_rect) {
				continue
			}

			is_selected := i == playlist_id

			if ui_button(int(UI_ID.Playlist) + i, item_rect, active = is_selected) && playlist_id != i {
				playlist_id = i
				songs_scroll = {}
			}

			count_str := fmt.tprintf("%d", len(playlist.songs))
			badge_w := max(fx.text_size(font, count_str, 11).x + 14, 22)

			if layout_start(item_rect) {
				if layout({GROW, badge_w}, .Row, padding = 16) {
					text_rect := layout_next()
					badge_area := fx.rect_expand(layout_next(), 0, 4)

					fx.text_faded(font, playlist.name, text_rect, 14, is_selected ? TEXT_PRIMARY : TEXT_SECONDARY, true)
					fx.rect(badge_area, is_selected ? ACCENT_BRIGHT : PRIMARY_COLOR, 6)
					fx.text(font, count_str, badge_area, 11, is_selected ? TEXT_PRIMARY : TEXT_SECONDARY, true, true)
				}
			}
		}

		ui_draw_gradients(rect, playlist_scroll.current, playlist_scroll.content_size, 30, BACKGROUND_COLOR, 6)
	}
}

draw_songs_panel :: proc(songs: []^Music) {
	rect := layout_next()

	if layout_start(rect, &songs_scroll, padding = 8, gap = 8) {
		fx.rect(rect, PRIMARY_DARK, 12)

		for song, i in songs {
			item_rect := layout_next(46)

			if !fx.rect_overlapping(rect, item_rect) {
				continue
			}

			id := int(uintptr(song))
			is_playing := player.music == song

			if ui_button(id, item_rect, active = is_playing) {
				player_start_playlist(songs, i)
			}

			item_rect.x += 8
			item_rect.w -= 16
			item_rect.w = max(item_rect.w, 0)

			if fx.mouse_in_rect(item_rect) && fx.mouse_is_pressed(.Right) {
				if is_blocker_active() || !fx.mouse_in_rect(context_menu.rect) {
					window_size := fx.window_size()
					menu_w := f32(160)
					menu_h := 4 * f32(32)
					pos := fx.mouse_pos()
					if pos.x + menu_w + 2 > window_size.x do pos.x = window_size.x - menu_w - 2
					if pos.y + menu_h + 2 > window_size.y do pos.y = window_size.y - menu_h - 2
					context_menu.rect = {pos.x, pos.y, menu_w, menu_h}
					context_menu.selection = song
				}
			}

			hovered := fx.mouse_in_rect(item_rect)
			if is_blocker_active() do hovered = false

			c1 := (hovered || is_playing) ? TEXT_PRIMARY : TEXT_SECONDARY
			c2 := (hovered || is_playing) ? TEXT_SECONDARY : fx.color_brightness(TEXT_SECONDARY, 0.6)

			if layout_start({rect.x + 14, item_rect.y, rect.w - 28, item_rect.h}) {
				if layout({36, GROW, 36}, .Row, gap = 12) {
					if layout({GROW, 36, GROW}, .Col) {
						layout_next()
						ui_cover(song.thumbnail, 4)
					}

					if layout({GROW, 20, 20, GROW}, .Col) {
						layout_next()
						title_rect := layout_next()
						artist_rect := layout_next()
						fx.text_faded(font, song.title, title_rect, 16, c1, true)
						fx.text_faded(font, song.artist, artist_rect, 13, c2, true)
					}

					if layout({GROW, 38, GROW}, .Col) {
						layout_next()
						time_rect := layout_next()
						time_str := format_time(song.duration)
						fx.text(font, time_str, time_rect, 13, c2, false, true)
					}
				}
			}
		}

		ui_draw_gradients(rect, songs_scroll.current, songs_scroll.content_size, 40, PRIMARY_DARK, 6)
	}
}

draw_detail_panel :: proc() {
	song := player.music
	if song == nil do return

	if layout({128, 8, 56, 24, 36, 8, GROW}, .Col, padding = 8, gap = 8) {
		if layout({128, GROW}, .Row, gap = 8) {
			ui_cover(player.cover, 6)

			if layout({30, 26, 20, 20}, .Col, padding = 12, gap = 4) {
				fx.text(font, song.title, layout_next(), 26, TEXT_PRIMARY, false, true)

				artist_size := fx.text_size(font, song.artist, 16).x
				dot_size := song.artist != "" && song.album != "" ? f32(2) : 0
				album_size := fx.text_size(font, song.album, 16).x

				if layout({artist_size, dot_size, album_size}, .Row, gap = 8) {
					if ui_label(song.artist, 16) {
						open_search_filtered_by(artist = song.artist)
					}
					fx.circle(fx.rect_center(layout_next()), dot_size, TEXT_SECONDARY)
					if ui_label(song.album, 16) {
						open_search_filtered_by(album = song.album)
					}
				}

				if play_count := int(song.playtime / song.duration); play_count > 0 {
					play_count_str := fmt.tprintf("%d plays", play_count)
					fx.text(font, play_count_str, layout_next(), 14, TEXT_SECONDARY)
				}

				if len(player.queue) > 0 {
					queue_str := fmt.tprintf("Next: %s", player.queue[0].title)
					fx.text(font, queue_str, layout_next(), 14, ACCENT_BRIGHT)
				}
			}
		}

		layout_next()
		draw_visualizer()
		draw_progress()
		if layout({GROW, 40, 40, 40, 40, 40, GROW}, .Row, gap = 8) {
			layout_next()
			if ui_icon(int(UI_ID.Shuffle), .Shuffle, player.shuffle) do player_toggle_shuffle()
			if ui_icon(int(UI_ID.Previous), .Previous) do player_prev()
			if ui_icon(int(UI_ID.Play_Pause), player.playing ? .Pause : .Play) do player_toggle_pause()
			if ui_icon(int(UI_ID.Next), .Next) do player_next()
			if ui_icon(int(UI_ID.Heart), .Heart, song.liked) do toggle_like(song)
			layout_next()
		}
		layout_next()
		draw_lyrics()
	}
}

draw_progress :: proc() {
	mouse := fx.mouse_pos()
	scroll := fx.mouse_scroll()

	cur_time := format_time(audio.position())
	tot_time := format_time(audio.duration())
	cur_w := fx.text_size(font, cur_time, 13).x
	tot_w := fx.text_size(font, tot_time, 13).x

	if layout({cur_w, GROW, tot_w, 24, 80}, .Row, gap = 8) {
		fx.text(font, cur_time, layout_next(), 13, TEXT_SECONDARY, false, true)

		progress: f32
		if scrub_time >= 0 {
			progress = scrub_time / audio.duration()
		} else if audio.duration() > 0 {
			progress = audio.position() / audio.duration()
		}

		prog_rect := layout_next()
		prog_changed := ui_slider(int(UI_ID.Progress), prog_rect, &progress)

		if prog_changed || drag_id == int(UI_ID.Progress) {
			scrub_time = progress * audio.duration()
			lyrics_synced = true
			tooltip_x := clamp(mouse.x, prog_rect.x, prog_rect.x + prog_rect.w)
			ui_tooltip(format_time(scrub_time), {tooltip_x, prog_rect.y + prog_rect.h * 0.5})
		}

		if prog_changed && fx.mouse_is_released(.Left) {
			player_seek(progress * audio.duration())
			lyrics_synced = true
			scrub_time = -1
		}

		fx.text(font, tot_time, layout_next(), 13, TEXT_SECONDARY, false, true)

		vol_icon_rect := fx.rect_shrink(layout_next(), 3, 3)
		fx.sprite(icons[.Volume], vol_icon_rect)

		vol_rect := layout_next()
		vol_changed := ui_slider(int(UI_ID.Volume), vol_rect, &volume)

		if fx.mouse_in_rect(vol_rect) && scroll.y != 0 {
			volume = clamp(volume + scroll.y * 0.05, 0, 1)
			audio.set_volume(volume)
		}

		if vol_changed || drag_id == int(UI_ID.Volume) {
			audio.set_volume(volume)
			hover_vol := clamp((mouse.x - vol_rect.x) / vol_rect.w, 0, 1)
			tooltip_x := clamp(mouse.x, vol_rect.x, vol_rect.x + vol_rect.w)
			ui_tooltip(fmt.tprintf("%d%%", int(hover_vol * 100)), {tooltip_x, vol_rect.y + vol_rect.h * 0.5})
		}
	}
}

draw_lyrics :: proc() {
	rect := layout_next()

	if layout_start(rect, &lyrics_scroll, padding = 16) {
		active_idx := current_lyric()

		if fx.mouse_in_rect(rect) && fx.mouse_scroll().y != 0 {
			lyrics_synced = false
		}

		for lyric, i in player.music.lyrics {
			item_rect := layout_next(48)

			if lyrics_synced && i == active_idx {
				content_y := item_rect.y - rect.y + lyrics_scroll.current
				lyrics_scroll.target = max(content_y - rect.h * 0.5 + item_rect.h * 0.5, 0)
			}

			if !fx.rect_overlapping(rect, item_rect) {
				continue
			}

			is_hover := fx.mouse_in_rect(item_rect) && fx.mouse_pos().y >= rect.y
			if is_blocker_active() do is_hover = false
			anim_hover := animate(int(UI_ID.Lyric_Hover) + i, is_hover)

			if is_hover && fx.mouse_is_pressed(.Left) {
				player_seek(lyric.time)
				lyrics_synced = true
			}

			anim_act := animate(int(UI_ID.Lyric_Active) + i, i == active_idx, 8.0)
			color := fx.color_lerp(fx.color_lerp(TEXT_SECONDARY, TEXT_PRIMARY, anim_hover), fx.WHITE, anim_act)

			if strings.trim_space(lyric.text) == "" {
				fx.sprite(icons[.Note], {item_rect.x, item_rect.y + (item_rect.h - 18) * 0.5, 18, 18}, color)
			} else {
				fx.text_faded(font, lyric.text, item_rect, math.lerp(f32(18), f32(22), anim_act), color, true)
			}
		}

		ui_draw_gradients(rect, lyrics_scroll.current, lyrics_scroll.content_size, 60, BACKGROUND_COLOR)
	}
}

ui_draw_gradients :: proc(rect: fx.Rect, current_scroll, content_h, grad_h_in: f32, bg_color: fx.Color, radius := f32(0)) {
	if rect.h <= 0 do return
	grad_h := min(grad_h_in, rect.h * 0.5)
	max_scroll := max(content_h - rect.h, 0)
	top_t := clamp(current_scroll / grad_h, 0, 1) * 0.9
	bot_t := clamp((max_scroll - current_scroll) / grad_h, 0, 1) * 0.9
	trans := fx.color_opacity(bg_color, 0)

	if top_t > 0 {
		top_opaque := fx.color_opacity(bg_color, top_t)
		fx.rect({rect.x, rect.y, rect.w, grad_h}, [4]fx.Color{top_opaque, top_opaque, trans, trans}, radius)
	}
	if bot_t > 0 {
		bot_opaque := fx.color_opacity(bg_color, bot_t)
		fx.rect({rect.x, rect.y + rect.h - grad_h, rect.w, grad_h}, [4]fx.Color{trans, trans, bot_opaque, bot_opaque}, radius)
	}
}

ui_button :: proc(id: int, rect: fx.Rect, text := "", active := false) -> bool {
	hovered := fx.mouse_in_rect(rect)
	is_context_menu := id > int(UI_ID.Context_Menu) && id < int(UI_ID.Playlist)
	if drag_id != 0 || (is_blocker_active() && !is_context_menu) do hovered = false

	anim_t := animate(id, hovered)
	color := fx.color_lerp(PRIMARY_DARK, HOVER_COLOR, anim_t)

	if active {
		color = fx.color_lerp(ACCENT_DARK, ACCENT_COLOR, anim_t)
	}

	if active || anim_t > 0 {
		fx.rect(rect, color, 6)
	}

	text_color := hovered ? TEXT_PRIMARY : TEXT_SECONDARY
	fx.text(font, text, rect, 14, text_color, true, true)

	if hovered && fx.mouse_is_pressed(.Left) {
		return true
	}

	return false
}

ui_icon :: proc(id: int, icon: Icon, active: bool = false) -> bool {
	rect := layout_next()

	pos := fx.rect_center(rect)
	radius := min(rect.w, rect.h) * 0.5
	icon_size := radius * 0.88
	hovered := fx.mouse_in_rect({pos.x - radius, pos.y - radius, radius * 2, radius * 2})
	if drag_id != 0 || is_blocker_active() do hovered = false
	anim := animate(id, hovered)

	base_color, hover_color := HOVER_COLOR, PRIMARY_BRIGHT
	if active {
		base_color, hover_color = ACCENT_BRIGHT, ACCENT_BRIGHT
	}

	fx.circle(pos, radius, fx.color_lerp(base_color, hover_color, anim))
	fx.sprite(icons[icon], {pos.x - icon_size * 0.5, pos.y - icon_size * 0.5, icon_size, icon_size}, TEXT_PRIMARY)

	if hovered {
		fx.set_cursor(.Hand)
		if fx.mouse_is_pressed(.Left) do return true
	}

	return false
}

ui_label :: proc(text_str: string, font_size: f32) -> bool {
	rect := layout_next()
	full_w := fx.text_size(font, text_str, font_size).x
	draw_w := min(full_w, rect.w)
	hovered := fx.mouse_in_rect({rect.x, rect.y, draw_w, rect.h})
	if is_blocker_active() do hovered = false

	color := hovered ? TEXT_PRIMARY : TEXT_SECONDARY
	fx.text(font, text_str, rect, font_size, color, false, true)

	if hovered {
		fx.set_cursor(.Hand)
		if fx.mouse_is_pressed(.Left) do return true
	}

	return false
}

ui_cover :: proc(tex: fx.Texture, radius: f32 = 6) {
	rect := layout_next()

	if tex.srv == nil {
		fx.rect(rect, PRIMARY_BRIGHT, radius)
		shrink := min(rect.w, rect.h) * 0.25
		fx.sprite(icons[.Note], fx.rect_shrink(rect, shrink, shrink), TEXT_SECONDARY)
		return
	}

	dest_size := min(rect.w, rect.h)
	dst_rect := fx.Rect{rect.x, rect.y, dest_size, dest_size}

	pos := fx.Vec2{0, 0}
	size := fx.Vec2{f32(tex.size.x), f32(tex.size.y)}
	if size.x != size.y {
		min_dim := min(size.x, size.y)
		pos = {(size.x - min_dim) * 0.5, (size.y - min_dim) * 0.5}
		size = min_dim
	}

	src_rect := fx.Rect{pos.x, pos.y, size.x, size.y}
	fx.sprite_ex(tex, src_rect, dst_rect, fx.WHITE, radius)
}

ui_tooltip :: proc(label: string, pos: fx.Vec2) {
	tip_w := fx.text_size(font, label, 12).x + 16
	rect := fx.Rect{pos.x - tip_w * 0.5,  pos.y - 30, tip_w, 22}
	fx.rect(fx.rect_expand(rect, 2, 2), PRIMARY_BRIGHT, 4)
	fx.rect(rect, PRIMARY_COLOR, 4)
	fx.text(font, label, {rect.x, rect.y, tip_w, 22}, 12, fx.WHITE, true, true)
}

ui_slider :: proc(id: int, rect: fx.Rect, value: ^f32, height: f32 = 4, pad: f32 = 12) -> (changed: bool) {
	mouse := fx.mouse_pos()

	x, w, h := rect.x, rect.w, height
	y := rect.y + (rect.h - h) * 0.5

	hovered := fx.mouse_in_rect({x, rect.y - pad, w, rect.h + pad * 2})
	if is_blocker_active() do hovered = false

	if hovered && fx.mouse_is_pressed(.Left) && drag_id == 0 {
		drag_id = id
	}

	active := drag_id == id
	anim := animate(id, hovered || active)

	if active {
		value^ = clamp((mouse.x - x) / w, 0, 1)
		changed = true
	}

	if active && !fx.mouse_is_down(.Left) {
		drag_id = 0
		active = false
	}

	fx.rect({x, y, w, h}, PRIMARY_BRIGHT, 2)
	fill_w := w * value^
	fx.rect({x, y, fill_w, h}, ACCENT_BRIGHT, 2)
	fx.circle({x + fill_w, y + h * 0.5}, 4 + 1 * anim, ACCENT_BRIGHT)

	if active || hovered {
		fx.set_cursor(.Hand)
	}

	return
}

current_lyric :: proc() -> (index: int) {
	cur_time := audio.position()

	if scrub_time >= 0 {
		cur_time = scrub_time
	}

	for lyric, i in player.music.lyrics {
		if cur_time >= lyric.time {
			index = i
		} else {
			break
		}
	}

	return
}

format_time :: proc(seconds: f32) -> string {
	return fmt.tprintf("%d:%02d", int(seconds) / 60, int(seconds) % 60)
}
