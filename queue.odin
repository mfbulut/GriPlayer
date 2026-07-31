package main

import "core:fmt"
import "fx"

queue_drag: struct {
	song:         ^Music,
	target_arr:   ^[dynamic]^Music,
	target_index: int,
	grab_offset:  f32,
	row_x:        f32,
	row_w:        f32,
	needs_remove: bool,
}

shift_animation :: proc(old_id, new_id: Id) {
	if state, ok := animations[old_id]; ok {
		animations[new_id] = state
		delete_key(&animations, old_id)
	} else {
		delete_key(&animations, new_id)
	}
}

shift_row_animations :: proc(prefix: string, old_index, new_index: int) {
	old_id := get_id(fmt.tprintf("%s_%d", prefix, old_index))
	new_id := get_id(fmt.tprintf("%s_%d", prefix, new_index))
	shift_animation(old_id, new_id)
}

draw_queue :: proc() {
	if begin("Queue", scroll = true, bg = COLOR_SURFACE, pad = 16) {
		layout := get_layout()
		state := get_scroll_state(layout.id)

		if queue_drag.song != nil {
			edge := f32(42)
			mouse_y := fx.mouse_pos().y

			if mouse_y < layout.rect.pos.y + edge {
				speed := (layout.rect.pos.y + edge - mouse_y) / edge * 480 * fx.frame_time()
				state.scroll_target.y -= speed
				state.scroll.y -= speed
			} else if mouse_y > layout.rect.pos.y + layout.rect.size.y - edge {
				speed := (mouse_y - layout.rect.pos.y - layout.rect.size.y + edge) / edge * 480 * fx.frame_time()
				state.scroll_target.y += speed
				state.scroll.y += speed
			}

			max_scroll := max(state.content_size.y - layout.body.size.y, 0)
			state.scroll_target.y = clamp(state.scroll_target.y, 0, max_scroll)
			state.scroll.y = clamp(state.scroll.y, 0, max_scroll)

			queue_update_drag_target(layout)
		}

		// Explicit Queue
		for song, i in player.queue {
			if queue_drag.song != nil && queue_drag.target_arr == &player.queue && queue_drag.target_index == i {
				layout_row({-1}, 56)
				layout_next()
			}

			layout_row({-1}, 56)
			bounds := layout_next()

			row_id := get_id(fmt.tprintf("queue_%d", i))
			local_y := bounds.pos.y - layout.body.pos.y
			bounds.pos.y = animate(row_id, local_y) + layout.body.pos.y

			draw_queue_row(song, "queue", i, &player.queue, bounds)
		}

		if queue_drag.song != nil && queue_drag.target_arr == &player.queue && queue_drag.target_index == len(player.queue) {
			layout_row({-1}, 56)
			layout_next()
		}

		// Divider
		layout_row({-1}, 42)
		divider_bounds := layout_next()

		divider_id := get_id("queue_divider")
		local_divider_y := divider_bounds.pos.y - layout.body.pos.y
		divider_bounds.pos.y = animate(divider_id, local_divider_y) + layout.body.pos.y

		if fx.rect_visible(divider_bounds) {
			text_width := fx.measure_text("Playlist", 11).x + 18
			center := divider_bounds.pos.x + divider_bounds.size.x * 0.5
			line_y := divider_bounds.pos.y + divider_bounds.size.y * 0.5

			fx.draw_rect({{divider_bounds.pos.x + 5, line_y}, {max(center - text_width * 0.5 - divider_bounds.pos.x - 5, 0), 1}}, COLOR_BORDER)
			fx.draw_rect({{center + text_width * 0.5, line_y}, {max(divider_bounds.pos.x + divider_bounds.size.x - center - text_width * 0.5 - 5, 0), 1}}, COLOR_BORDER)

			text_bounds := fx.Rect{{center - text_width * 0.5, divider_bounds.pos.y + (divider_bounds.size.y - 11) * 0.5}, {text_width, 11}}
			fx.draw_text_rect("Playlist", text_bounds, 11, COLOR_MUTED, true)
		}

		// Playlist
		playlist_start := clamp(player.cursor + 1, 0, len(player.songs))
		for i := playlist_start; i < len(player.songs); i += 1 {
			song := player.songs[i]

			if queue_drag.song != nil && queue_drag.target_arr == &player.songs && queue_drag.target_index == i {
				layout_row({-1}, 56)
				layout_next()
			}

			layout_row({-1}, 56)
			bounds := layout_next()

			row_id := get_id(fmt.tprintf("playlist_%d", i))
			local_y := bounds.pos.y - layout.body.pos.y
			bounds.pos.y = animate(row_id, local_y) + layout.body.pos.y

			draw_queue_row(song, "playlist", i, &player.songs, bounds)
		}

		if queue_drag.song != nil && queue_drag.target_arr == &player.songs && queue_drag.target_index == len(player.songs) {
			layout_row({-1}, 56)
			layout_next()
		}
	}

	if queue_drag.song != nil {
		overlay_bounds := fx.Rect {
			{queue_drag.row_x, fx.mouse_pos().y - queue_drag.grab_offset},
			{queue_drag.row_w, 56}
		}

		fx.draw_rect(fx.rect_expand(overlay_bounds, 1), COLOR_ACCENT, 7)
		draw_queue_row(queue_drag.song, "", -1, nil, overlay_bounds, true)
	}
}

draw_queue_row :: proc(song: ^Music, prefix: string, index: int, arr: ^[dynamic]^Music, bounds: fx.Rect, is_overlay := false) {
	if !fx.rect_visible(bounds) && !is_overlay do return

	row_id := is_overlay ? get_id(song.fullpath) : get_id(fmt.tprintf("%s_%d", prefix, index))

	pad := f32(6)
	handle_bounds := fx.Rect{bounds.pos, {38, bounds.size.y}}
	remove_bounds := fx.Rect{{bounds.pos.x + bounds.size.x - 36 - pad, bounds.pos.y + 10}, {36, 36}}
	body_bounds   := fx.Rect{
		{handle_bounds.pos.x + handle_bounds.size.x, bounds.pos.y},
		{max(remove_bounds.pos.x - handle_bounds.pos.x - handle_bounds.size.x, 0), bounds.size.y}
	}

	handle_res := update_control(child_id(row_id, "handle"), handle_bounds)
	remove_res := update_control(child_id(row_id, "remove"), remove_bounds)
	body_res   := update_control(child_id(row_id, "body"), body_bounds)

	if .ACTIVE in handle_res && queue_drag.song == nil {
		queue_drag = {
			song = song,
			target_arr = arr,
			target_index = index,
			grab_offset = fx.mouse_pos().y - bounds.pos.y,
			row_x = bounds.pos.x,
			row_w = bounds.size.x,
			needs_remove = true,
		}
		ctx.focus_id = child_id(get_id(song.fullpath), "handle")
	}

	res := handle_res + remove_res + body_res
	if queue_drag.song != nil && !is_overlay do res = {}
	if is_overlay do res = {.ACTIVE}

	bg_color := ui_color(ROW_COLOR, res)
	fx.draw_rect(bounds, bg_color, 6)

	handle_color := ui_color(LINK_COLOR, handle_res)
	draw_queue_handle(handle_bounds, is_overlay ? COLOR_TEXT : handle_color)

	if .HOVER in handle_res || .ACTIVE in handle_res do fx.set_cursor(.SizeAll)

	if .HOVER in remove_res do fx.set_cursor(.Hand)
	if .SUBMIT in remove_res {
		if arr == &player.queue {
			ordered_remove(&player.queue, index)
			for i in 0..=len(player.queue) {
				shift_row_animations("queue", i, i - 1)
			}
		} else if arr == &player.songs {
			current_moved := index == player.cursor
			if !current_moved && index < player.cursor do player.cursor -= 1
			ordered_remove(&player.songs, index)
			for i in 0..=len(player.songs) {
				shift_row_animations("playlist", i, i - 1)
			}
			if current_moved do player.cursor = -1
		}
	}

	if .HOVER in body_res {
		fx.set_cursor(.Hand)
		if fx.key_is_pressed(.Mouse_Right) do open_context_menu(song)
	}
	if .SUBMIT in body_res {
		if arr == &player.songs {
			player.cursor = index
			player_play_music(song)
		} else if arr == &player.queue {
			player_play_music(song)
			for _ in 0..<index+1 do ordered_remove(&player.queue, 0)
			for i in 0..=len(player.queue) {
				shift_row_animations("queue", i, i - (i + 1))
			}
		}
	}

	cover_size := f32(40)
	cover_bounds := fx.Rect {
		{handle_bounds.pos.x + handle_bounds.size.x + pad, bounds.pos.y + (bounds.size.y - cover_size) * 0.5},
		{cover_size, cover_size},
	}

	cover_bg := .ACTIVE in res ? fx.Color{72, 80, 94, 255} : COLOR_BORDER
	draw_cover(song.thumbnail, cover_bounds, cover_bg)

	text_x := cover_bounds.pos.x + cover_bounds.size.x + 10
	text_w := max(remove_bounds.pos.x - text_x - pad, 0)

	title_bounds := fx.Rect{{text_x, bounds.pos.y + 10}, {text_w, 18}}
	fx.draw_text_faded(song.title, title_bounds, 14, COLOR_TEXT)

	secondary := song.artist
	if secondary == "" do secondary = song.album
	artist_bounds := fx.Rect{{text_x, bounds.pos.y + 28}, {text_w, 15}}
	fx.draw_text_faded(secondary, artist_bounds, 11, COLOR_MUTED)

	cross_color := ui_color(LINK_COLOR, remove_res)
	draw_icon(.Cross, remove_bounds, 24, is_overlay ? COLOR_TEXT : cross_color)
}

draw_queue_handle :: proc(bounds: fx.Rect, color: fx.Color) {
	width := f32(15)
	x := bounds.pos.x + (bounds.size.x - width) * 0.5
	y := bounds.pos.y + bounds.size.y * 0.5 - 6.5
	for i in 0 ..< 3 do fx.draw_rect({{x, y + f32(i) * 5}, {width, 3}}, color, 1.5)
}

queue_update_drag_target :: proc(layout: ^Layout) {
	if queue_drag.song == nil do return

	content_top := layout.body.pos.y
	drag_center := fx.mouse_pos().y - queue_drag.grab_offset + 56.0 * 0.5

	best_distance := f32(1e30)
	best_arr := queue_drag.target_arr
	best_index := queue_drag.target_index

	// Queue slots
	for i in 0..=len(player.queue) {
		center := content_top + 56.0 * 0.5 + f32(i) * 56.0
		if distance := abs(drag_center - center); distance < best_distance {
			best_distance, best_arr, best_index = distance, &player.queue, i
		}
	}

	// Playlist slots
	playlist_start := clamp(player.cursor + 1, 0, len(player.songs))
	playlist_count := len(player.songs) - playlist_start

	playlist_top := content_top + f32(len(player.queue)) * 56.0 + 42.0

	for i in 0..=playlist_count {
		center := playlist_top + 56.0 * 0.5 + f32(i) * 56.0
		if distance := abs(drag_center - center); distance < best_distance {
			best_distance, best_arr, best_index = distance, &player.songs, playlist_start + i
		}
	}

	queue_drag.target_arr = best_arr
	queue_drag.target_index = best_index

	if !fx.key_is_down(.Mouse_Left) {
		if queue_drag.needs_remove {
			queue_drag = {}
			ctx.focus_id = 0
			return
		}

		song := queue_drag.song
		prefix := queue_drag.target_arr == &player.queue ? "queue" : "playlist"

		for i := len(queue_drag.target_arr) - 1; i >= queue_drag.target_index; i -= 1 {
			shift_row_animations(prefix, i, i + 1)
		}

		inject_at(queue_drag.target_arr, queue_drag.target_index, song)

		row_id := get_id(fmt.tprintf("%s_%d", prefix, queue_drag.target_index))
		layout := get_layout()
		start_local_y := fx.mouse_pos().y - queue_drag.grab_offset - layout.body.pos.y

		animation_cancel(row_id)
		animate(row_id, start_local_y)

		queue_drag = {}
		ctx.focus_id = 0
		return
	}

	if queue_drag.needs_remove {
		prefix := queue_drag.target_arr == &player.queue ? "queue" : "playlist"
		ordered_remove(queue_drag.target_arr, queue_drag.target_index)
		for i in queue_drag.target_index + 1..=len(queue_drag.target_arr) {
			shift_row_animations(prefix, i, i - 1)
		}
		queue_drag.needs_remove = false
	}
}