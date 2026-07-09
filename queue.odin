package main

import "fx"
import "core:math"
import "core:math/ease"

show_queue := false
queue_scroll: Scroll_State

queue_drag_idx := -1
queue_drag_offset_y: f32

y_animation_state: map[u64]f32

animate_y :: proc(id: u64, target: f32, speed: f32 = 12.0) -> f32 {
	dt := fx.frame_time()
	if id not_in y_animation_state {
		y_animation_state[id] = target
		return target
	}

	current := y_animation_state[id]
	current = math.lerp(current, target, ease.cubic_out(speed * dt))
	y_animation_state[id] = current
	return current
}

Queue_Item :: struct {
	is_queue: bool,
	index:    int,
	song:     ^Music,
}

get_queue_item :: proc(combined_index: int, playlist_start: int) -> Queue_Item {
	if combined_index < playlist_start {
		return {true, combined_index, player.queue[combined_index]}
	} else {
		actual_idx := player.cursor + 1 + (combined_index - playlist_start)
		return {false, actual_idx, player.songs[actual_idx]}
	}
}

ui_queue_item :: proc(loc: Queue_Item, item_rect, visual_rect: fx.Rect, item_id, index: int, is_dragged: bool, rect: fx.Rect) -> bool {
	song := loc.song
	hovered := !is_dragged && mouse_hover(visual_rect)

	if anim_t := animate(item_id, hovered); anim_t > 0 {
		fx.draw_rect(visual_rect, fx.color_lerp(BACKGROUND_COLOR, HOVER_COLOR, anim_t), 6)
	}

	c1 := hovered || is_dragged ? TEXT_PRIMARY : TEXT_SECONDARY
	c2 := hovered || is_dragged ? TEXT_SECONDARY : fx.color_brightness(TEXT_SECONDARY, 0.6)

	action_taken := false

	if layout_start({rect.x + 14, visual_rect.y, visual_rect.w - 28, visual_rect.h}) {
		if layout({36, 36, GROW, 36, 16}, .Row, gap = 12) {

			h_rect := layout_next()
			h_hover := !is_dragged && mouse_hover({h_rect.x, visual_rect.y, 48, visual_rect.h})
			h_col := h_hover || is_dragged ? TEXT_PRIMARY : TEXT_SECONDARY
			h_pos := fx.rect_center(h_rect)

			for i in -1..=1 {
				fx.draw_rect({h_pos.x - 8, h_pos.y + f32(i * 5), 16, 2}, h_col, 1)
			}
			if h_hover do fx.set_cursor(.Hand)

			if layout({GROW, 36, GROW}, .Col) {
				layout_next()
				ui_cover(song.thumbnail, 4)
			}

			if layout({GROW, 20, 20, GROW}, .Col) {
				layout_next()
				title_rect := layout_next()
				artist_rect := layout_next()
				fx.draw_text_faded(font, song.title, title_rect, 16, c1, true)
				fx.draw_text_faded(font, song.artist, artist_rect, 13, c2, true)
			}

			if layout({GROW, 38, GROW}, .Col) {
				layout_next()
				time_rect := layout_next()
				fx.draw_text(font, format_time(song.duration), time_rect, 13, c2, false, true)
			}

			c_rect := layout_next()
			c_hover := !is_dragged && mouse_hover({c_rect.x - 16, visual_rect.y, 48, visual_rect.h})
			c_col := c_hover || is_dragged ? TEXT_PRIMARY : TEXT_SECONDARY
			c_pos := fx.rect_center(c_rect)

			fx.draw_texture(icons[.Cross], {c_pos.x - 7, c_pos.y - 7, 14, 14}, c_col)
			if c_hover do fx.set_cursor(.Hand)

			if hovered && !is_dragged {
				if fx.key_is_pressed(.Mouse_Right) {
					open_context_menu(song)
				} else if fx.key_is_pressed(.Mouse_Left) {
					if h_hover {
						drag_id = item_id
						queue_drag_idx = index
						queue_drag_offset_y = fx.mouse_pos().y - item_rect.y
					} else if c_hover {
						if loc.is_queue do ordered_remove(&player.queue, loc.index)
						else do ordered_remove(&player.songs, loc.index)
						action_taken = true
					} else {
						if loc.is_queue {
							player_play_music(song, false)
							ordered_remove(&player.queue, loc.index)
						} else {
							for s, idx in player.songs {
								if s == song {
									player.cursor = idx
									break
								}
							}
							player_play_music(song, false)
						}
						action_taken = true
					}
				}
			}
		}
	}

	return action_taken
}

ui_queue :: proc() {
	rect := layout_next()

	playlist_start := len(player.queue)
	combined_len := playlist_start
	if player.music != nil && len(player.songs) > 0 {
		combined_len += max(0, len(player.songs) - (player.cursor + 1))
	}

	if layout_start(rect, &queue_scroll, padding = 8) {
		mouse := fx.mouse_pos()

		drop_idx := -1
		drop_is_queue := false

		if queue_drag_idx >= 0 {
			closest_dist: f32 = 1000000.0
			cur_y: f32 = rect.y + 16 - queue_scroll.current
			gray_line_y: f32 = cur_y

			dragged_visual_y := mouse.y - queue_drag_offset_y

			for i := 0; i < combined_len; i += 1 {
				if i == playlist_start && playlist_start > 0 {
					gray_line_y = cur_y + 8
					cur_y += 16
				}

				dist := abs(dragged_visual_y - cur_y)
				if dist < closest_dist {
					closest_dist = dist
					drop_idx = i
				}
				cur_y += 48
			}

			if playlist_start == combined_len && playlist_start > 0 {
				gray_line_y = cur_y + 8
			}

			drag_center_y := dragged_visual_y + 24
			drop_is_queue = drag_center_y < gray_line_y
		}

		is_dragging_item := drag_id >= int(UI_ID.Queue_Item) && drag_id < int(UI_ID.Queue_Item) + 100000
		if is_dragging_item && !fx.key_is_down(.Mouse_Left) {
			if queue_drag_idx >= 0 {
				source := get_queue_item(queue_drag_idx, playlist_start)

				if source.is_queue == drop_is_queue && drop_idx == queue_drag_idx {
				} else if drop_idx >= 0 {
					if source.is_queue {
						ordered_remove(&player.queue, source.index)
					} else {
						ordered_remove(&player.songs, source.index)
					}

					if drop_is_queue {
						target_idx := clamp(drop_idx, 0, len(player.queue))
						inject_at(&player.queue, target_idx, source.song)
					} else {
						new_playlist_start := len(player.queue)
						target_idx := clamp(drop_idx - new_playlist_start, 0, len(player.songs) - (player.cursor + 1))

						actual_playlist_idx := player.cursor + 1 + target_idx
						if actual_playlist_idx > len(player.songs) {
							actual_playlist_idx = len(player.songs)
						}
						inject_at(&player.songs, actual_playlist_idx, source.song)
					}
				}
			}

			drag_id = 0
			queue_drag_idx = -1

			for k in animation_state {
				if k >= int(UI_ID.Queue_Item) {
					delete_key(&animation_state, k)
				}
			}

			playlist_start = len(player.queue)
			combined_len = playlist_start
			if player.music != nil && len(player.songs) > 0 {
				combined_len += max(0, len(player.songs) - (player.cursor + 1))
			}
		}

		dragged_rect: fx.Rect
		dragged_song: ^Music = nil

		used_ids := make([dynamic]u64, context.temp_allocator)

		for i := 0; i < combined_len; i += 1 {
			loc := get_queue_item(i, playlist_start)
			song := loc.song

			stable_id := cast(u64)cast(uintptr)song
			for true {
				found := false
				for uid in used_ids {
					if uid == stable_id { found = true; break }
				}
				if !found do break
				stable_id += 1
			}
			append(&used_ids, stable_id)

			if i == playlist_start && playlist_start > 0 {
				header_rect := layout_next(16)

				is_divider_shift_down := queue_drag_idx >= 0 && queue_drag_idx >= playlist_start && drop_is_queue
				is_divider_shift_up := queue_drag_idx >= 0 && queue_drag_idx < playlist_start && !drop_is_queue

				div_shift_down_t := animate(int(UI_ID.Queue_Item) + 300000, is_divider_shift_down, 15.0)
				div_shift_up_t := animate(int(UI_ID.Queue_Item) + 400000, is_divider_shift_up, 15.0)

				div_y := header_rect.y + (48 * div_shift_down_t) - (48 * div_shift_up_t)
				fx.draw_rect({rect.x + 14, div_y + 7, rect.w - 28, 2}, PRIMARY_BRIGHT, 1)
			}

			item_id := int(UI_ID.Queue_Item) + i
			item_rect := layout_next(48)

			if drag_id == item_id {
				dragged_rect = item_rect
				dragged_song = song
				y_animation_state[stable_id] = mouse.y - queue_drag_offset_y
				continue
			}

			target_y := item_rect.y
			should_shift_down := queue_drag_idx >= 0 && i != queue_drag_idx && i >= drop_idx && i < queue_drag_idx
			should_shift_up := queue_drag_idx >= 0 && i != queue_drag_idx && i <= drop_idx && i > queue_drag_idx

			if should_shift_down do target_y += 48
			if should_shift_up do target_y -= 48

			visual_y := animate_y(stable_id, target_y, 15.0)
			visual_rect := item_rect
			visual_rect.y = visual_y

			if !fx.rect_overlapping(rect, visual_rect) && !fx.rect_overlapping(rect, item_rect) {
				continue
			}

			if ui_queue_item(loc, item_rect, visual_rect, item_id, i, false, rect) {
				break
			}
		}

		ui_gradients(rect, queue_scroll.current, queue_scroll.content_size, 60, BACKGROUND_COLOR)

		if dragged_song != nil {
			dragged_rect.y = mouse.y - queue_drag_offset_y

			fx.draw_rect(dragged_rect, PRIMARY_BRIGHT, 8)
			fx.draw_rect(fx.rect_expand(dragged_rect, -1, -1), PRIMARY_DARK, 7)

			if layout_start({rect.x + 14, dragged_rect.y, dragged_rect.w - 28, dragged_rect.h}) {
				ui_queue_item(Queue_Item{false, -1, dragged_song}, dragged_rect, dragged_rect, 0, -1, true, rect)
			}
		}
	}
}