package main

import "core:fmt"
import "core:time"
import "core:time/timezone"
import "core:strings"
import "core:text/edit"

import "fx"
import "fx/audio"
import "fx/smtc"

utc_offset: i64
queue_active := false
lyrics_synced := true
selected_playlist := 0
scrub_time := f32(-1)

current_tab: enum {
	Both,
	Player,
	Library,
}

context_menu: struct {
	song: ^Music,
	bounds: fx.Rect,
}

main :: proc() {
	loader_start()

	fx.init("GriPlayer")
	audio.initialize()
	smtc.init(fx.window.hwnd)

	builder: strings.Builder
	edit.init(&textbox, context.allocator, context.allocator)
	edit.setup_once(&textbox, &builder)
	textbox.set_clipboard = proc(user_data: rawptr, text: string) -> (ok: bool) { return fx.set_clipboard(text) }
	textbox.get_clipboard = proc(user_data: rawptr) -> (text: string, ok: bool) { return fx.get_clipboard() }
	icon_atlas = fx.texture_load(#load("assets/Icons.png"))

	if region, ok := timezone.region_load("local", context.allocator); ok {
		utc_offset = region.rrule.has_dst ? region.rrule.dst_offset : region.rrule.std_offset
		utc_offset *= 1000000000
		timezone.region_destroy(region, context.allocator)
	}

	fft_init()
	fx.run(frame)
	cache_save()
}

frame :: proc() {
	loader_poll()
	handle_keyboard_input()
	player_update()
	animation_update_all()
	update_ui()

	if player.playing && player.music != nil {
		player.music.playtime += fx.frame_time()
	}

	if fx.window_is_minimized() {
		time.sleep(6 * time.Millisecond)
		return
	}

	fx.clear_window(COLOR_BACKGROUND)

	if fx.window_size().x < 700 {
		if current_tab == .Both {
			if player.music != nil {
				current_tab = .Player
			} else {
				current_tab = .Library
			}
		}
	} else {
		current_tab = .Both
	}

	size := fx.window_size()
	if begin("root", {{0, 0}, size}, pad = 8, gap = 8) {
		if current_tab == .Both {
			library_width := clamp(size.x * 0.45, f32(460), size.x)
			layout_row({library_width, -1}, -1)
		} else {
			layout_row({-1}, 42)
			if begin("Tabs", bg = COLOR_SURFACE, pad = 4, gap = 6) {
				layout_row({-1, -1}, -1)

				if .SUBMIT in button("Library", active = current_tab == .Library) {
					current_tab = .Library
				}

				if .SUBMIT in button("Player", active = current_tab == .Player) {
					current_tab = .Player
				}
			}

			layout_row({-1}, -1)
		}

		if current_tab == .Both || current_tab == .Library {
			if begin("Library", gap = 8) {
				layout_row({-1}, 42)
				draw_search_box()

				if search.active {
					layout_row({-1}, -1)
				} else {
					layout_row({170, -1}, -1)

					if begin("PlaylistsArea", bg = COLOR_SURFACE) {
						layout_row({-1}, 42)
						if begin("PlaylistsHeader", pad = 8) {
							layout_row({-1}, 30)
							label("Playlists", font_size = 16)
						}

						layout_row({-1}, -1)
						if begin("Playlists", scroll = true, bg = COLOR_SURFACE, pad = 8, gap = 4) {
							for &playlist, i in playlists {
								layout_row({-1}, 30)
								if .SUBMIT in playlist_row(&playlist, i, selected_playlist == i) {
									selected_playlist = i
									if i == LIKED_PLAYLIST_INDEX {
										refresh_liked_playlist()
									}
								}
							}
						}
					}
				}

				if begin("SongsArea", bg = COLOR_SURFACE) {
					if len(playlists) > 0 {
						selected_playlist = clamp(selected_playlist, 0, len(playlists) - 1)
						playlist := &playlists[selected_playlist]

						if !search.active {
							layout_row({-1}, 42)
							if begin("SongsHeader", pad = 8, gap = 4) {
								text := PLAYLIST_SORT_LABELS[playlist.sort]
								text_width := fx.measure_text(text, 12).x
								text_button_width := text_width + 20
								icon_button_width := f32(30)

								layout_row({-1, text_button_width, icon_button_width}, 30)

								name_bounds := layout_next()
								name_bounds.pos.x += 12
								name_bounds.size.x -= 12
								fx.draw_text_faded(playlist.name, name_bounds, 16, COLOR_TEXT)

								sort_btn_res := button(text, font_size = 12)
								if .SUBMIT in sort_btn_res {
									playlist.sort = Playlist_Sort(
										(int(playlist.sort) + 1) % len(PLAYLIST_SORT_LABELS),
									)
									playlist_sort(playlist)
								} else if .SECONDARY in sort_btn_res {
									playlist.sort = Playlist_Sort(
										(int(playlist.sort) - 1) %% len(PLAYLIST_SORT_LABELS),
									)
									playlist_sort(playlist)
								}

								sort_icon := sort_icons[playlist.sort_reversed ? 1 : 0][playlist.sort]
								if .SUBMIT in icon_button("sort_dir", sort_icon) {
									playlist.sort_reversed = !playlist.sort_reversed
									playlist_sort(playlist)
								}
							}
						}

						layout_row({-1}, -1)
						active_marker := f32(-1)
						songs := search.active ? search.results[:] : playlist.songs[:]
						for song, i in songs {
							if song == player.music {
								active_marker = (f32(i) + 0.5) / f32(len(songs))
								break
							}
						}

						if begin("SongsList", scroll = true, bg = COLOR_SURFACE, pad = 8, gap = 4, marker = active_marker) {
							for song, i in songs {
								layout_row({-1}, 50)
								if .SUBMIT in song_row(song, i, player.music == song, search.active ? .Title : playlist.sort) {
									player_start_playlist(songs, i)
								}
							}
						}
					} else {
						layout_row({-1}, 42)
						label("Loading music...")
					}
				}
			}
		}

		if current_tab == .Both || current_tab == .Player {
			if begin("Player", bg = COLOR_SURFACE) {
				if len(visualizer_palette) > 0 {
					bounds := get_layout().rect
					tint_height := min(bounds.size.y, f32(280))
					top := visualizer_color_at(0)
					bottom := visualizer_color_at(0.65)
					middle := fx.color_lerp(top, bottom, 0.5)
					fx.draw_rect(
						{bounds.pos, {bounds.size.x, tint_height}},
						{fx.color_opacity(top, .10), fx.color_opacity(middle, 0.05), fx.color_opacity(middle, 0), fx.color_opacity(bottom, 0)},
						8,
					)
				}

				layout_row({-1}, 190)
				if begin("NowPlaying", pad = 16, gap = 8) {
					if player.music != nil {
						layout_row({160, -1}, 160)

						cover_region := AtlasRegion {
							texture = player.cover,
							source  = {{0, 0}, fx.Vec2(player.cover.size)},
						}
						draw_cover(cover_region, layout_next(), radius = 8)

						if begin("NowPlayingInfo", pad = 8, gap = 8) {
							layout_row({-1, 32}, 32)
							title_bounds := layout_next()
							fx.draw_text_faded(
								player.music.title,
								title_bounds,
								27,
								COLOR_TEXT,
							)

							if .SUBMIT in icon_button("queue_toggle", .Queue, active = queue_active) {
								queue_active = !queue_active
							}

							artist_w := player.music.artist != "" ? fx.measure_text(player.music.artist, 16).x : 0
							album_w := player.music.album != "" ? fx.measure_text(player.music.album, 16).x : 0
							dot_size := artist_w > 0 && album_w > 0 ? f32(10) : 0
							avail_w := max(title_bounds.size.x + 32 - dot_size, 0)

							if avail_w < artist_w + album_w {
								if dot_size > 0 {
									if avail_w >= min(artist_w, album_w) * 2 {
										if artist_w < album_w {
											album_w = avail_w - artist_w
										} else {
											artist_w = avail_w - album_w
										}
									} else {
										artist_w = avail_w / 2
										album_w = avail_w / 2
									}
								} else {
									artist_w = min(artist_w, avail_w)
									album_w = min(album_w, avail_w)
								}
							}

							layout_row({artist_w, dot_size, album_w}, 24, gap = 4)

							if .SUBMIT in link(get_id("link_artist"), player.music.artist, 16) {
								search_open(player.music.artist, .Artist)
							}

							dot_bounds := layout_next()
							fx.draw_circle(dot_bounds.pos + dot_bounds.size * 0.5 ,2, COLOR_MUTED)

							if .SUBMIT in link(get_id("link_album"), player.music.album, 16) {
								search_open(player.music.album, .Album)
							}

							layout_row({-1}, -1)
							draw_visualizer(layout_next())
						}
					} else {
						layout_row({-1}, -1)
						bounds := layout_next()
						fx.draw_text_rect("No song playing", bounds, 16, COLOR_MUTED, true)
					}
				}

				layout_row({-1}, 90)
				if begin("Controls", pad = 12, gap = 8) {
					duration := audio.duration()
					position := scrub_time >= 0 ? scrub_time : audio.position()
					position_text := format_time(position)
					duration_text := format_time(duration)
					position_width := fx.measure_text(position_text, 10).x + 6
					duration_width := fx.measure_text(duration_text, 10).x + 6

					layout_row({position_width, -1, duration_width, 20, 90}, 20)

					label(position_text, 11)

					prog_res, prog_bounds := slider(get_id("progress"), &position, 0, max(duration, 1), preview = true)

					if .CHANGE in prog_res {
						scrub_time = position
						lyrics_synced = true
					}

					if .SUBMIT in prog_res {
						if scrub_time >= 0 do player_seek(scrub_time)
						scrub_time = -1
					}

					if .ACTIVE in prog_res || .HOVER in prog_res {
						hover_ratio := clamp((fx.mouse_pos().x - prog_bounds.pos.x) / max(prog_bounds.size.x, 1), 0.0, 1.0)
						hover_time := hover_ratio * max(duration, 1)
						draw_slider_tooltip(
							get_id("prog_tooltip"),
							prog_bounds,
							position / max(duration, 1),
							format_time(hover_time),
						)
					}

					label(duration_text, 11)

					if .SUBMIT in icon_button("mute", audio.muted ? .Mute : .Volume, radius = 999, offset = 2, scale = 0.85, bg = false) {
						audio.muted = !audio.muted
						audio.reset()
					}

					vol_color := audio.muted ? LINK_COLOR : SLIDER_FILL_COLOR
					vol_res, vol_bounds := slider(get_id("volume"), &audio.volume, 0, 1, vol_color)
					if .HOVER in vol_res && fx.mouse_scroll().y != 0 {
						audio.volume = clamp(audio.volume + fx.mouse_scroll().y * 0.05, 0, 1)
					}

					if .ACTIVE in vol_res || .HOVER in vol_res {
						draw_slider_tooltip(
							get_id("vol_tooltip"),
							vol_bounds,
							audio.volume,
							fmt.tprintf("%d%%", int(audio.volume * 100 + 0.5)),
							centered = true,
						)
					}

					layout_row({-1, 36, 36, 36, 36, 36, -1}, 36)
					layout_next()

					if .SUBMIT in
					   icon_button("shuffle", .Shuffle, radius = 999, active = player.shuffle) {
						player_toggle_shuffle()
					}

					if .SUBMIT in icon_button("prev", .Previous, radius = 999) {
						player_prev()
					}

					if .SUBMIT in
					   icon_button("play", player.playing ? .Pause : .Play, radius = 999) {
						player_toggle_pause()
					}

					if .SUBMIT in icon_button("next", .Next, radius = 999) {
						player_next()
					}

					liked := player.music != nil && player.music.liked
					if .SUBMIT in icon_button( "like", liked ? .Heart : .Heart_Empty, radius = 999, active = liked) {
						if player.music != nil do toggle_like(player.music)
					}

					layout_next()
				}

				layout_row({-1}, -1)

				active, found := current_lyric()

				if queue_active {
					draw_queue()
				} else {
					lyrics_marker := f32(-1)
					if player.music != nil && len(player.music.lyrics) > 0 {
						if found do lyrics_marker = (f32(active) + 0.5) / f32(len(player.music.lyrics))
					}

					if begin("Lyrics", scroll = true, bg = COLOR_SURFACE, pad = 16, marker = lyrics_marker) {
						if player.music == nil || len(player.music.lyrics) == 0 {
							layout_row({-1}, -1)
							bounds := layout_next()
							icon_size := min(f32(40), bounds.size.x * 0.25)
							draw_icon(.Note, bounds, icon_size, COLOR_MUTED)
						} else {
							lyrics_layout := get_layout()
							lyrics_cnt := get_scroll_state(lyrics_layout.id)

							if mouse_over(lyrics_layout.body) && fx.mouse_scroll().y != 0 {
								lyrics_synced = false
							}

							scrollbar_id := get_id("scrollbar_v")
							thumb_id := child_id(scrollbar_id, "thumb")
							if ctx.focus_id == thumb_id {
								lyrics_synced = false
							}

							if lyrics_synced && !found {
								animated_scroll := animate(get_id("lyrics_sync"), 0, 0.5)
								lyrics_cnt.scroll_target.y = animated_scroll
								lyrics_cnt.scroll.y = animated_scroll
							}

							for lyric, i in player.music.lyrics {
								layout_row({-1}, 60)
								row := layout_next()

								is_active := found && i == active
								if lyrics_synced && is_active {
									row_center := row.pos.y + row.size.y * 0.5
									container_center := lyrics_layout.body.pos.y + lyrics_layout.body.size.y * 0.5
									target_scroll := lyrics_cnt.scroll.y + (row_center - container_center)
									animated_scroll := animate(get_id("lyrics_sync"), target_scroll, 0.5)
									lyrics_cnt.scroll_target.y = animated_scroll
									lyrics_cnt.scroll.y = animated_scroll
								}

								if !fx.rect_overlaps(row, get_clip_rect()) do continue

								row_id := get_id(fmt.tprintf("lyric_%d", i))
								hit := update_control(row_id, row)

								active_amount := animate(
									child_id(row_id, "active"),
									is_active ? f32(1) : f32(0),
								)

								hover_amount := .HOVER in hit ? f32(1) : f32(0)

								base_color := COLOR_MUTED
								hover_color := fx.color_lerp(base_color, COLOR_TEXT, hover_amount)
								color := fx.color_lerp(hover_color, COLOR_TEXT, active_amount)

								if lyric.text == "" {
									icon_size := 24 + 4 * active_amount
									icon_rect := fx.Rect{{row.pos.x + 3, row.pos.y}, {icon_size, row.size.y}}
									draw_icon(.Note, icon_rect, icon_size, color)
								} else {
									fx.draw_text_faded(lyric.text, row, 18 + 4 * active_amount,color)
								}

								if .SUBMIT in hit {
									player_seek(lyric.time)
									lyrics_synced = true
								}

								if .HOVER in hit do fx.set_cursor(.Hand)
							}
						}
					}
				}
			}
		}
	}

	draw_context_menu()
	free_all(context.temp_allocator)
}

draw_cover :: proc(region: AtlasRegion, bounds: fx.Rect, background := COLOR_BORDER, radius := f32(6)) {
	if !fx.rect_overlaps(bounds, get_clip_rect()) do return
	if region.texture.index != 0 {
		size := region.source.size
		crop := min(size.x, size.y)
		source := fx.Rect{region.source.pos + (size - crop) * 0.5, crop}
		fx.draw_texture_ex(region.texture, source, bounds, fx.WHITE, radius)
		return
	}

	fx.draw_rect(bounds, background, radius)
	icon_size := min(bounds.size.x, bounds.size.y) * 0.4
	draw_icon(.Note, bounds, icon_size, COLOR_TEXT)
}

playlist_row :: proc(playlist: ^Playlist, i: int, is_active: bool) -> (res: Result_Set) {
	if begin(playlist.name, pad = 6) {
		layout := get_layout()
		if !fx.rect_overlaps(layout.rect, get_clip_rect()) do return {}

		id := get_id(playlist.name)
		res = update_control(id, layout.rect)

		bg_color := ui_color(is_active ? ACTIVE_ROW_COLOR : ROW_COLOR, res)
		fx.draw_rect(layout.rect, bg_color, 6)

		if .HOVER in res do fx.set_cursor(.Hand)

		count := i == LIKED_PLAYLIST_INDEX ? liked_playlist_count() : len(playlist.songs)
		count_text := fmt.tprintf("%d", count)
		count_width := fx.measure_text(count_text, 10).x + 6

		layout_row({20, -1, count_width}, -1, gap = 8)

		draw_icon(playlist.icon, layout_next(), 20, is_active ? COLOR_TEXT : COLOR_MUTED)
		fx.draw_text_faded(playlist.name, layout_next(), 13, is_active ? COLOR_TEXT : COLOR_MUTED)
		fx.draw_text_faded(count_text, layout_next(), 10, COLOR_MUTED)
	}

	return res
}

song_row :: proc(song: ^Music, i: int, is_active: bool, sort: Playlist_Sort = .Title) -> (res: Result_Set) {
	if begin(song.fullpath, pad = 5, gap = 10) {
		layout := get_layout()
		if !fx.rect_overlaps(layout.rect, get_clip_rect()) do return {}

		id := get_id(song.fullpath)
		res = update_control(id, layout.rect)

		bg_color := ui_color(is_active ? ACTIVE_ROW_COLOR : ROW_COLOR, res)
		fx.draw_rect(layout.rect, bg_color, 6)

		if .HOVER in res do fx.set_cursor(.Hand)

		show_like := false
		right_text := ""
		right_width: f32 = 0

		#partial switch sort {
		case .Track:
			right_text = fmt.tprintf("%d", song.track)
		case .Duration:
			right_text = format_time(song.duration)
		case .Playtime:
			right_text = fmt.tprintf("%dm", int(song.playtime) / 60)
		case .Last_Listened:
			if time.to_unix_nanoseconds(song.listen_timestamp) > 0 {
				local_time := time.Time{ song.listen_timestamp._nsec + utc_offset }

				y1, m1, d1 := time.date(local_time)
				y2, m2, d2 := time.date(time.now())
				if y1 == y2 && m1 == m2 && d1 == d2 {
					h, m, _ := time.clock(local_time)
					right_text = fmt.tprintf("%02d:%02d", h, m)
				} else {
					right_text = fmt.tprintf("%02d/%02d", d1, int(m1))
				}
			}
		case:
			show_like = true
			right_width = 36
		}

		if right_width == 0 {
			right_width = fx.measure_text(right_text, 12).x
		}

		layout_row({40, -1, right_width}, -1)

		cover_bg := is_active || .ACTIVE in res ? fx.Color{72, 80, 94, 255} : COLOR_BORDER
		draw_cover(song.thumbnail, layout_next(), cover_bg)

		text_bounds := layout_next()
		title_bounds := fx.Rect{{text_bounds.pos.x, layout.rect.pos.y + 7}, {text_bounds.size.x, 18}}
		fx.draw_text_faded(song.title, title_bounds, 14, COLOR_TEXT)

		secondary := song.artist
		artist_bounds := fx.Rect{{text_bounds.pos.x, layout.rect.pos.y + 25}, {text_bounds.size.x, 15}}
		fx.draw_text_faded(secondary, artist_bounds, 11, COLOR_MUTED)

		right_bounds := layout_next()

		if show_like {
			like_bounds := fx.Rect {
				{right_bounds.pos.x, right_bounds.pos.y + (right_bounds.size.y - 36) * 0.5},
				{36, 36},
			}
			like_id := child_id(id, "like")
			like_res := update_control(like_id, like_bounds)

			icon_color := ui_color(LINK_COLOR, like_res)
			icon_size := min(like_bounds.size.x, like_bounds.size.y) * 0.6
			draw_icon(song.liked ? .Heart : .Heart_Empty, like_bounds, icon_size, icon_color)

			if .HOVER in like_res do fx.set_cursor(.Hand)
			if .SUBMIT in like_res {
				toggle_like(song)
			}
		} else if right_text != "" {
			fx.draw_text_faded(right_text, right_bounds, 12, COLOR_MUTED)
		}

		if .HOVER in res && fx.key_is_pressed(.Mouse_Right) {
			open_context_menu(song)
		}
	}

	return
}

format_time :: proc(seconds: f32) -> string {
	value := max(int(seconds), 0)
	return fmt.tprintf("%d:%02d", value / 60, value % 60)
}

open_context_menu :: proc(song: ^Music) {
	size := fx.window_size()
	position := fx.mouse_pos()
	width := f32(140)
	height := f32(148)
	position.x = clamp(position.x, 10, max(10, size.x - width - 10))
	position.y = clamp(position.y, 10, max(10, size.y - height - 10))
	context_menu = {
		song   = song,
		bounds = fx.Rect{position, {width, height}},
	}
}

draw_context_menu :: proc() {
	song := context_menu.song
	if song == nil do return

	if (fx.key_is_pressed(.Mouse_Left) || fx.key_is_pressed(.Mouse_Right)) &&
	   !fx.point_in_rect(context_menu.bounds, fx.mouse_pos()) {
		context_menu = {}
	}

	if context_menu.song == nil do return
	fx.set_scissor({{0, 0}, {1e6, 1e6}})

	bounds := context_menu.bounds
	fx.draw_rect(fx.rect_expand(bounds, 1), COLOR_BORDER, 9)

	labels := [5]string{song.liked ? "Unlike" : "Like", "Play next", "Add to queue", "Show artist", "Show album"}
	icons := [5]Icon{song.liked ? .Heart : .Heart_Empty, .Add_Next, .Add_Last, .Artist, .Album}

	if begin("context_menu", bounds, bg = COLOR_SURFACE, pad = 4) {
		for text, i in labels {
			layout_row({-1}, 28)
			if .SUBMIT in menu_button(text, icons[i]) {
				switch i {
				case 0: toggle_like(song)
				case 1: player_queue_add(song, true)
				case 2: player_queue_add(song)
				case 3: search_open(song.artist, .Artist)
				case 4: search_open(song.album, .Album)
				}
				context_menu = {}
			}
		}
	}
}

draw_slider_tooltip :: proc(id: Id, bounds: fx.Rect, value: f32, text: string, centered: bool = false) {
	width := fx.measure_text(text, 12).x + 14
	target_x := centered ? bounds.pos.x + bounds.size.x * 0.5 : fx.mouse_pos().x
	x := clamp(target_x - width * 0.5, bounds.pos.x, bounds.pos.x + bounds.size.x - width)
	tooltip := fx.Rect{{x, bounds.pos.y - 20}, {width, 21}}

	fx.draw_rect(tooltip, ROW_COLOR.focus, 6)
	fx.draw_text_rect(text, tooltip, 12, COLOR_TEXT, true)
}

handle_keyboard_input :: proc() {
	if fx.key_is_pressed(.Esc) && context_menu.song != nil {
		context_menu = {}
		return
	}

	if fx.key_is_down(.Ctrl) && fx.key_is_pressed(.F) {
		if !search.active {
			search_open()
		} else {
			search.focused = true
		}
		return
	}

	if search.focused do return

	if fx.key_is_pressed_repeat(.Up) do audio.volume = clamp(audio.volume + 0.05, 0, 1)
	if fx.key_is_pressed_repeat(.Down) do audio.volume = clamp(audio.volume - 0.05, 0, 1)

	if player.music == nil do return

	if fx.key_is_pressed(.Space) do player_toggle_pause()

	if fx.key_is_down(.Ctrl) && len(player.music.lyrics) > 0 {
		lyric_index, lyric_found := current_lyric()
		position := scrub_time >= 0 ? scrub_time : audio.position()

		if fx.key_is_pressed_repeat(.Left) {
			if !lyric_found && position >= player.music.lyrics[len(player.music.lyrics) - 1].time {
				player_seek(player.music.lyrics[lyric_index].time)
			} else {
				player_seek(lyric_index > 0 ? player.music.lyrics[lyric_index - 1].time : 0)
			}
		}

		if fx.key_is_pressed_repeat(.Right) {
			if !lyric_found && position < player.music.lyrics[0].time {
				player_seek(player.music.lyrics[0].time)
			} else if lyric_index < len(player.music.lyrics) - 1 {
				player_seek(player.music.lyrics[lyric_index + 1].time)
			} else {
				player_next()
			}
		}

		lyrics_synced = true
	} else {
		if fx.key_is_pressed_repeat(.Left) do player_seek(max(audio.position() - 5, 0))
		if fx.key_is_pressed_repeat(.Right) do player_seek(min(audio.position() + 5, audio.duration()))
	}
}