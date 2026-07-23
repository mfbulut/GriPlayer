package main

import "core:fmt"

import "fx"

Queue_Section :: enum {None, Queue, Playlist}
Queue_Action :: enum {None, Play, Remove}

Queue_Drag :: struct {
	song:        ^Music,
	section:     Queue_Section,
	index:       int,
	grab_offset: f32,
	row_x:       f32,
	row_w:       f32,
}

queue_drag: Queue_Drag

QUEUE_ROW_HEIGHT     :: f32(56)
QUEUE_ROW_GAP        :: f32(6)
QUEUE_PADDING        :: f32(14)
QUEUE_DIVIDER_HEIGHT :: f32(38)
QUEUE_EMPTY_HEIGHT   :: f32(42)

queue_entry_id :: proc(songs: []^Music, index: int, section: Queue_Section) -> ID {
	song := songs[index]
	occurrence := 0
	for item in songs[:index] {
		if item == song do occurrence += 1
	}
	return id(fmt.tprintf("queue-%d-%s-%d", section, song.fullpath, occurrence))
}

queue_playlist_start :: proc() -> int {
	return clamp(player.cursor + 1, 0, len(player.songs))
}

queue_sync_playlist_order :: proc() {
	clear(&player.playlist)
	for song in player.songs do append(&player.playlist, song)
}

queue_remove_canonical_song :: proc(song: ^Music) {
	for item, index in player.playlist {
		if item == song {
			ordered_remove(&player.playlist, index)
			return
		}
	}
}

queue_insert_canonical_song :: proc(song: ^Music, index: int) {
	inject_at(&player.playlist, clamp(index, 0, len(player.playlist)), song)
}

queue_remove_playlist_song :: proc(index: int) {
	if index < 0 || index >= len(player.songs) do return
	song := player.songs[index]
	if index == player.cursor do player.cursor = index - 1
	else if index < player.cursor do player.cursor -= 1
	ordered_remove(&player.songs, index)
	if len(player.songs) == 0 do player.cursor = -1
	if player.shuffle do queue_remove_canonical_song(song)
	else do queue_sync_playlist_order()
}

queue_insert_playlist_song :: proc(song: ^Music, index: int) {
	insert_index := clamp(index, 0, len(player.songs))
	if len(player.songs) == 0 {
		player.cursor = song == player.music ? insert_index : -1
	} else {
		cursor_has_current := player.cursor >= 0 && player.cursor < len(player.songs) && player.songs[player.cursor] == player.music
		if song == player.music && !cursor_has_current do player.cursor = insert_index
		else if player.cursor >= 0 && insert_index <= player.cursor do player.cursor += 1
	}
	inject_at(&player.songs, insert_index, song)
	if player.shuffle do queue_insert_canonical_song(song, insert_index)
	else do queue_sync_playlist_order()
}

queue_reorder_playlist_song :: proc(from, to: int) {
	if from < 0 || from >= len(player.songs) do return
	target := clamp(to, 0, len(player.songs) - 1)
	if from == target do return
	song := player.songs[from]
	current_moved := from == player.cursor
	if !current_moved && from < player.cursor do player.cursor -= 1
	ordered_remove(&player.songs, from)
	if current_moved do player.cursor = target
	else if player.cursor >= 0 && target <= player.cursor do player.cursor += 1
	inject_at(&player.songs, target, song)
	if !player.shuffle do queue_sync_playlist_order()
}

queue_move_dragged_song :: proc(section: Queue_Section, index: int) {
	if queue_drag.song == nil do return
	old_section, old_index := queue_drag.section, queue_drag.index
	if old_section == section && old_index == index do return
	song := queue_drag.song
	switch old_section {
	case .Queue:
		if old_index < 0 || old_index >= len(player.queue) do return
		ordered_remove(&player.queue, old_index)
	case .Playlist:
		if old_index < 0 || old_index >= len(player.songs) do return
		if section == .Playlist {
			queue_reorder_playlist_song(old_index, index)
			queue_drag.index = clamp(index, 0, len(player.songs) - 1)
			return
		}
		queue_remove_playlist_song(old_index)
	case .None:
		return
	}
	switch section {
	case .Queue:
		target := clamp(index, 0, len(player.queue))
		inject_at(&player.queue, target, song)
		queue_drag.index = target
	case .Playlist:
		target := clamp(index, 0, len(player.songs))
		queue_insert_playlist_song(song, target)
		queue_drag.index = target
	case .None:
		return
	}
	queue_drag.section = section
}

queue_validate_drag :: proc() -> bool {
	if queue_drag.song == nil do return false
	songs := queue_drag.section == .Queue ? player.queue[:] : player.songs[:]
	if queue_drag.index >= 0 && queue_drag.index < len(songs) && songs[queue_drag.index] == queue_drag.song do return true
	for song, index in songs {
		if song == queue_drag.song {
			queue_drag.index = index
			return true
		}
	}
	queue_drag = {}
	return false
}

queue_scroll_state :: proc() -> ^Scroll_State {
	scroll_id := id("scroll", id("queue-list"))
	for &state in ui_ctx.scrolls {
		if state.id == scroll_id do return &state
	}
	return nil
}

queue_update_drag_target :: proc(bounds: fx.Rect, scroll: f32) {
	if !queue_validate_drag() do return
	queue_count := len(player.queue)
	playlist_start := queue_playlist_start()
	playlist_count := len(player.songs) - playlist_start
	if queue_drag.section == .Queue do queue_count -= 1
	if queue_drag.section == .Playlist do playlist_count -= 1
	content_top := bounds.y + QUEUE_PADDING - scroll
	drag_center := fx.mouse_pos().y - queue_drag.grab_offset + QUEUE_ROW_HEIGHT * .5
	best_distance := f32(1e30)
	best_section := Queue_Section.Queue
	best_index := 0
	for index := 0; index <= queue_count; index += 1 {
		center := content_top + QUEUE_ROW_HEIGHT * .5 + f32(index) * (QUEUE_ROW_HEIGHT + QUEUE_ROW_GAP)
		if distance := abs(drag_center - center); distance < best_distance {
			best_distance, best_section, best_index = distance, .Queue, index
		}
	}
	queue_height := f32(queue_count) * (QUEUE_ROW_HEIGHT + QUEUE_ROW_GAP)
	playlist_top := content_top + queue_height + QUEUE_DIVIDER_HEIGHT + QUEUE_ROW_GAP
	for index := 0; index <= playlist_count; index += 1 {
		center := playlist_top + QUEUE_ROW_HEIGHT * .5 + f32(index) * (QUEUE_ROW_HEIGHT + QUEUE_ROW_GAP)
		if distance := abs(drag_center - center); distance < best_distance {
			best_distance, best_section, best_index = distance, .Playlist, playlist_start + index
		}
	}
	queue_move_dragged_song(best_section, best_index)
}

queue_begin_drag :: proc(song: ^Music, section: Queue_Section, index: int, row: fx.Rect) {
	queue_drag = {song = song, section = section, index = index, grab_offset = fx.mouse_pos().y - row.y, row_x = row.x, row_w = row.w}
}

queue_finish_drag :: proc() {
	if queue_drag.song == nil do return
	songs := queue_drag.section == .Queue ? player.queue[:] : player.songs[:]
	if queue_drag.index >= 0 && queue_drag.index < len(songs) {
		entry_id := queue_entry_id(songs, queue_drag.index, queue_drag.section)
		_ = animate(id("y", entry_id), fx.mouse_pos().y - queue_drag.grab_offset, 0, .Quadratic_Out)
	}
	queue_drag = {}
}

queue_play_song :: proc(section: Queue_Section, index: int) {
	switch section {
	case .Queue:
		if index < 0 || index >= len(player.queue) do return
		player_play_music(player.queue[index])
		for _ in 0 ..< index + 1 do ordered_remove(&player.queue, 0)
	case .Playlist:
		if index < 0 || index >= len(player.songs) do return
		player.cursor = index
		player_play_music(player.songs[index])
	case .None:
	}
}

draw_queue_handle :: proc(bounds: fx.Rect, color: fx.Color) {
	width := f32(15)
	x := bounds.x + (bounds.w - width) * .5
	y := bounds.y + bounds.h * .5 - 6.5
	for index in 0 ..< 3 do fx.draw_rect({x, y + f32(index) * 5, width, 3}, color, 1.5)
}

draw_queue_song :: proc(song: ^Music, row: fx.Rect, section: Queue_Section, index: int, entry_id: ID, overlay := false) -> Queue_Action {
	hovered := !overlay && queue_drag.song == nil && mouse_visible(row)
	background := overlay ? COLOR_HOVER : animate(id("background", entry_id), hovered ? COLOR_HOVER : fx.Color{}, ANIM_DURATION, .Sine_In_Out)
	if overlay {
		fx.draw_rect({row.x + 2, row.y + 5, row.w, row.h}, fx.color_opacity(COLOR_BACKGROUND, .55), 8)
		fx.draw_rect(fx.rect_expand(row, 1, 1), fx.color_opacity(COLOR_ACCENT_BRIGHT, .72), 8)
	}
	if background.a > 0 do fx.draw_rect(row, background, 7)

	handle := fx.Rect{row.x + 3, row.y, 38, row.h}
	remove := fx.Rect{row.x + row.w - 36, row.y + 10, 30, 36}
	handle_hit, remove_hit, body_hit: Interaction
	if !overlay {
		handle_hit = interact(id("handle", entry_id), handle)
		remove_hit = interact(id("remove", entry_id), remove)
		body_hit = interact(id("play", entry_id), {handle.x + handle.w, row.y, max(remove.x - handle.x - handle.w, 0), row.h})
		if handle_hit.pressed do queue_begin_drag(song, section, index, row)
	}
	draw_queue_handle(handle, handle_hit.hovered || overlay ? COLOR_TEXT : COLOR_MUTED)
	if handle_hit.hovered do fx.set_cursor(.SizeAll)

	cover := fx.Rect{handle.x + handle.w + 3, row.y + 7, 42, 42}
	draw_cover(song.thumbnail, cover, 6)
	if remove_hit.hovered do fx.draw_rect(remove, fx.color_opacity(COLOR_BORDER, .55), 6)
	draw_icon(.Cross, remove, remove_hit.hovered || overlay ? COLOR_TEXT : COLOR_MUTED, 8.5)
	if remove_hit.hovered do fx.set_cursor(.Hand)

	text_x := cover.x + cover.w + 11
	text_width := max(remove.x - text_x - 7, 0)
	title_color := player.music == song || overlay ? COLOR_TEXT : hovered ? COLOR_TEXT : COLOR_MUTED
	label({text_x, row.y + 6, text_width, 25}, song.title, 13, text_style(title_color))
	secondary := song.artist
	if secondary == "" do secondary = song.album
	label({text_x, row.y + 29, text_width, 18}, secondary, 10, text_style(COLOR_MUTED))
	if body_hit.hovered {
		fx.set_cursor(.Hand)
		if fx.key_is_pressed(.Mouse_Right) do open_context_menu(song)
	}
	if remove_hit.clicked do return .Remove
	if body_hit.clicked do return .Play
	return .None
}

draw_queue_divider :: proc(bounds: fx.Rect) {
	text_width := fx.measure_text("Playlist", 11).x + 18
	center := bounds.x + bounds.w * .5
	line_y := bounds.y + bounds.h * .5
	fx.draw_rect({bounds.x + 5, line_y, max(center - text_width * .5 - bounds.x - 5, 0), 1}, COLOR_BORDER)
	fx.draw_rect({center + text_width * .5, line_y, max(bounds.x + bounds.w - center - text_width * .5 - 5, 0), 1}, COLOR_BORDER)
	label({center - text_width * .5, bounds.y, text_width, bounds.h}, "Playlist", 11, text_style(COLOR_MUTED), center_x = true)
}

draw_queue :: proc(bounds: fx.Rect) {
	if queue_drag.song != nil {
		if state := queue_scroll_state(); state != nil {
			edge := f32(42)
			mouse_y := fx.mouse_pos().y
			if mouse_y < bounds.y + edge do state.target -= (bounds.y + edge - mouse_y) / edge * 480 * fx.frame_time()
			else if mouse_y > bounds.y + bounds.h - edge do state.target += (mouse_y - bounds.y - bounds.h + edge) / edge * 480 * fx.frame_time()
		}
	}
	action := Queue_Action.None
	action_section := Queue_Section.None
	action_index := -1
	if layout(bounds, .Col, pad = pad_all(QUEUE_PADDING), gap = QUEUE_ROW_GAP, can_scroll = true, layout_id = id("queue-list")) {
		if queue_drag.song != nil {
			if state := queue_scroll_state(); state != nil do queue_update_drag_target(bounds, state.current)
		}
		for song, index in player.queue {
			target := next_size(px(QUEUE_ROW_HEIGHT))
			if queue_drag.song != nil && queue_drag.section == .Queue && queue_drag.index == index do continue
			entry_id := queue_entry_id(player.queue[:], index, .Queue)
			row := target
			row.y = animate(id("y", entry_id), target.y, ANIM_DURATION, .Quadratic_Out)
			if !is_visible(row) do continue
			if row_action := draw_queue_song(song, row, .Queue, index, entry_id); row_action != .None {
				action, action_section, action_index = row_action, .Queue, index
			}
		}
		divider_target := next_size(px(QUEUE_DIVIDER_HEIGHT))
		divider := divider_target
		divider.y = animate(id("queue-divider-y"), divider_target.y, ANIM_DURATION, .Quadratic_Out)
		if is_visible(divider) do draw_queue_divider(divider)
		playlist_start := queue_playlist_start()
		if playlist_start >= len(player.songs) {
			label(next_size(px(QUEUE_EMPTY_HEIGHT)), "No upcoming songs", 11, text_style(fx.color_opacity(COLOR_MUTED, .72)), center_x = true)
		} else {
			for song, offset in player.songs[playlist_start:] {
				index := playlist_start + offset
				target := next_size(px(QUEUE_ROW_HEIGHT))
				if queue_drag.song != nil && queue_drag.section == .Playlist && queue_drag.index == index do continue
				entry_id := queue_entry_id(player.songs[:], index, .Playlist)
				row := target
				row.y = animate(id("y", entry_id), target.y, ANIM_DURATION, .Quadratic_Out)
				if !is_visible(row) do continue
				if row_action := draw_queue_song(song, row, .Playlist, index, entry_id); row_action != .None {
					action, action_section, action_index = row_action, .Playlist, index
				}
			}
		}
	}
	if action_index >= 0 {
		switch action {
		case .Play: queue_play_song(action_section, action_index)
		case .Remove:
			if action_section == .Queue do ordered_remove(&player.queue, action_index)
			else if action_section == .Playlist do queue_remove_playlist_song(action_index)
		case .None:
		}
	}
	if queue_drag.song != nil {
		overlay := fx.Rect{queue_drag.row_x, fx.mouse_pos().y - queue_drag.grab_offset, queue_drag.row_w, QUEUE_ROW_HEIGHT}
		_ = draw_queue_song(queue_drag.song, overlay, queue_drag.section, queue_drag.index, ID_NONE, true)
		if fx.key_is_released(.Mouse_Left) do queue_finish_drag()
	}
}
