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
					// Dropped in same position, nothing to do
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

		action_remove: Queue_Item = {false, -1, nil}
		action_play: Queue_Item = {false, -1, nil}

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

			hovered := mouse_hover(visual_rect)
			handle_rect := fx.Rect{visual_rect.x, visual_rect.y, 48, visual_rect.h}
			handle_hovered := mouse_hover(handle_rect)

			if hovered && drag_id == 0 {
				if fx.key_is_pressed(.Mouse_Right) {
					action_remove = loc
				} else if fx.key_is_pressed(.Mouse_Left) {
					if handle_hovered {
						drag_id = item_id
						queue_drag_idx = i
						queue_drag_offset_y = mouse.y - item_rect.y
					} else {
						action_play = loc
					}
				}
			}

			anim_t := animate(item_id, hovered)
			if anim_t > 0 {
				bg_color := fx.color_lerp(BACKGROUND_COLOR, HOVER_COLOR, anim_t)
				fx.draw_rect(visual_rect, bg_color, 6)
			}

			c1 := hovered ? TEXT_PRIMARY : TEXT_SECONDARY
			c2 := hovered ? TEXT_SECONDARY : fx.color_brightness(TEXT_SECONDARY, 0.6)

			if layout_start({rect.x + 14, visual_rect.y, visual_rect.w - 28, visual_rect.h}) {
				if layout({48, 36, GROW, 36}, .Row, gap = 12) {
					layout_next()

					handle_color := handle_hovered ? TEXT_PRIMARY : TEXT_SECONDARY
					fx.draw_rect({handle_rect.x + 16, handle_rect.y + 18, 16, 2}, handle_color, 1)
					fx.draw_rect({handle_rect.x + 16, handle_rect.y + 23, 16, 2}, handle_color, 1)
					fx.draw_rect({handle_rect.x + 16, handle_rect.y + 28, 16, 2}, handle_color, 1)
					if handle_hovered do fx.set_cursor(.Hand)

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
						time_str := format_time(song.duration)
						fx.draw_text(font, time_str, time_rect, 13, c2, false, true)
					}
				}
			}
		}

		if action_remove.song != nil {
			if action_remove.is_queue {
				ordered_remove(&player.queue, action_remove.index)
			} else {
				ordered_remove(&player.songs, action_remove.index)
			}
		}

		if action_play.song != nil {
			if action_play.is_queue {
				player_play_music(action_play.song, false)
				ordered_remove(&player.queue, action_play.index)
			} else {
				for s, idx in player.songs {
					if s == action_play.song {
						player.cursor = idx
						break
					}
				}
				player_play_music(action_play.song, false)
			}
		}

		ui_gradients(rect, queue_scroll.current, queue_scroll.content_size, 60, BACKGROUND_COLOR)

		if dragged_song != nil {
			dragged_rect.y = mouse.y - queue_drag_offset_y

			fx.draw_rect(dragged_rect, PRIMARY_BRIGHT, 8)
			fx.draw_rect(fx.rect_expand(dragged_rect, -1, -1), PRIMARY_DARK, 7)

			if layout_start({rect.x + 14, dragged_rect.y, dragged_rect.w - 28, dragged_rect.h}) {
				if layout({48, 36, GROW, 36}, .Row, gap = 12) {
					layout_next()

					fx.draw_rect({dragged_rect.x + 16, dragged_rect.y + 18, 16, 2}, TEXT_PRIMARY, 1)
					fx.draw_rect({dragged_rect.x + 16, dragged_rect.y + 23, 16, 2}, TEXT_PRIMARY, 1)
					fx.draw_rect({dragged_rect.x + 16, dragged_rect.y + 28, 16, 2}, TEXT_PRIMARY, 1)

					if layout({GROW, 36, GROW}, .Col) {
						layout_next()
						ui_cover(dragged_song.thumbnail, 4)
					}

					if layout({GROW, 20, 20, GROW}, .Col) {
						layout_next()
						title_rect := layout_next()
						artist_rect := layout_next()
						fx.draw_text_faded(font, dragged_song.title, title_rect, 16, TEXT_PRIMARY, true)
						fx.draw_text_faded(font, dragged_song.artist, artist_rect, 13, TEXT_SECONDARY, true)
					}

					if layout({GROW, 38, GROW}, .Col) {
						layout_next()
						time_rect := layout_next()
						time_str := format_time(dragged_song.duration)
						fx.draw_text(font, time_str, time_rect, 13, TEXT_SECONDARY, false, true)
					}
				}
			}
		}
	}
}