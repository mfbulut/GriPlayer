package main

import "fx"

UI_QUEUE_DRAG :: UI_ID(3)

Queue_Section :: enum {
	None,
	Queue,
	Playlist,
}

Queue_Drag :: struct {
	song:        ^Music,
	section:     Queue_Section,
	index:       int,
	grab_offset: f32,
	row_x:       f32,
	row_w:       f32,
}

queue_active: bool
queue_scroll: Scroll_State
queue_drag: Queue_Drag
queue_row_positions: map[UI_ID]f32
queue_view_bounds: fx.Rect

queue_init :: proc() {
	queue_row_positions = make(map[UI_ID]f32)
}

QUEUE_ROW_HEIGHT   :: f32(56)
QUEUE_ROW_GAP      :: f32(6)
QUEUE_PADDING      :: f32(14)
QUEUE_DIVIDER_HEIGHT :: f32(38)
QUEUE_EMPTY_HEIGHT :: f32(42)

queue_entry_id :: proc(songs: []^Music, index: int, section: Queue_Section) -> UI_ID {
	song := songs[index]
	occurrence := uint(0)
	for i in 0..<index {
		if songs[i] == song do occurrence += 1
	}
	value := uint(uintptr(song)) ~ (uint(section) * 0x9e3779b9) ~ (occurrence * 0x85ebca6b)
	return ui_id(60, value)
}

queue_animate_row_y :: proc(id: UI_ID, target: f32) -> f32 {
	value, found := queue_row_positions[id]
	if !found {
		value = target
	} else {
		value += (target - value) * min(fx.frame_time() * 18, 1)
	}
	queue_row_positions[id] = value
	return value
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
	insert_index := clamp(index, 0, len(player.playlist))
	inject_at(&player.playlist, insert_index, song)
}

queue_remove_playlist_song :: proc(index: int) {
	if index < 0 || index >= len(player.songs) do return
	song := player.songs[index]
	if index == player.cursor {
		player.cursor = index - 1
	} else if index < player.cursor {
		player.cursor -= 1
	}
	ordered_remove(&player.songs, index)
	if len(player.songs) == 0 do player.cursor = -1

	if player.shuffle {
		queue_remove_canonical_song(song)
	} else {
		queue_sync_playlist_order()
	}
}

queue_insert_playlist_song :: proc(song: ^Music, index: int) {
	insert_index := clamp(index, 0, len(player.songs))
	if len(player.songs) == 0 {
		player.cursor = song == player.music ? insert_index : -1
	} else {
		cursor_has_current := player.cursor >= 0 && player.cursor < len(player.songs) && player.songs[player.cursor] == player.music
		if song == player.music && !cursor_has_current {
			player.cursor = insert_index
		} else if player.cursor >= 0 && insert_index <= player.cursor {
			player.cursor += 1
		}
	}
	inject_at(&player.songs, insert_index, song)

	if player.shuffle {
		queue_insert_canonical_song(song, insert_index)
	} else {
		queue_sync_playlist_order()
	}
}

queue_reorder_playlist_song :: proc(from, to: int) {
	if from < 0 || from >= len(player.songs) do return
	target := clamp(to, 0, len(player.songs) - 1)
	if from == target do return

	song := player.songs[from]
	current_moved := from == player.cursor
	if !current_moved && from < player.cursor do player.cursor -= 1
	ordered_remove(&player.songs, from)
	if current_moved {
		player.cursor = target
	} else if player.cursor >= 0 && target <= player.cursor {
		player.cursor += 1
	}
	inject_at(&player.songs, target, song)
	if !player.shuffle do queue_sync_playlist_order()
}

queue_move_dragged_song :: proc(section: Queue_Section, index: int) {
	if queue_drag.song == nil do return
	old_section := queue_drag.section
	old_index := queue_drag.index
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
	if queue_drag.index >= 0 && queue_drag.index < len(songs) && songs[queue_drag.index] == queue_drag.song {
		return true
	}
	for song, index in songs {
		if song == queue_drag.song {
			queue_drag.index = index
			return true
		}
	}
	queue_drag = {}
	ui_active = UI_NONE
	return false
}

queue_update_drag_target :: proc(bounds: fx.Rect) {
	if !queue_validate_drag() do return

	queue_count := len(player.queue)
	playlist_count := len(player.songs)
	if queue_drag.section == .Queue do queue_count -= 1
	if queue_drag.section == .Playlist do playlist_count -= 1

	content_top := bounds.y + QUEUE_PADDING - queue_scroll.current
	drag_center := fx.mouse_pos().y - queue_drag.grab_offset + QUEUE_ROW_HEIGHT * .5
	best_distance := f32(1e30)
	best_section := Queue_Section.Queue
	best_index := 0

	for index := 0; index <= queue_count; index += 1 {
		slot_center := content_top + QUEUE_ROW_HEIGHT * .5 + f32(index) * (QUEUE_ROW_HEIGHT + QUEUE_ROW_GAP)
		distance := abs(drag_center - slot_center)
		if distance < best_distance {
			best_distance = distance
			best_section = .Queue
			best_index = index
		}
	}

	queue_block_height := f32(queue_count) * (QUEUE_ROW_HEIGHT + QUEUE_ROW_GAP)
	divider_y := content_top + queue_block_height
	playlist_top := divider_y + QUEUE_DIVIDER_HEIGHT + QUEUE_ROW_GAP
	for index := 0; index <= playlist_count; index += 1 {
		slot_center := playlist_top + QUEUE_ROW_HEIGHT * .5 + f32(index) * (QUEUE_ROW_HEIGHT + QUEUE_ROW_GAP)
		distance := abs(drag_center - slot_center)
		if distance < best_distance {
			best_distance = distance
			best_section = .Playlist
			best_index = index
		}
	}

	queue_move_dragged_song(best_section, best_index)
}

queue_begin_drag :: proc(song: ^Music, section: Queue_Section, index: int, row: fx.Rect) {
	queue_drag = {
		song = song,
		section = section,
		index = index,
		grab_offset = fx.mouse_pos().y - row.y,
		row_x = row.x,
		row_w = row.w,
	}
	ui_active = UI_QUEUE_DRAG
}

queue_finish_drag :: proc() {
	if queue_drag.song == nil do return
	songs := queue_drag.section == .Queue ? player.queue[:] : player.songs[:]
	if queue_drag.index >= 0 && queue_drag.index < len(songs) {
		id := queue_entry_id(songs, queue_drag.index, queue_drag.section)
		queue_row_positions[id] = fx.mouse_pos().y - queue_drag.grab_offset
	}
	queue_drag = {}
	ui_active = UI_NONE
}

draw_queue_handle :: proc(bounds: fx.Rect, color: fx.Color) {
	width := f32(15)
	x := bounds.x + (bounds.w - width) * .5
	y := bounds.y + bounds.h * .5 - 6.5
	for i in 0..<3 {
		fx.draw_rect({x, y + f32(i) * 5, width, 3}, color, 1.5)
	}
}

draw_queue_song :: proc(song: ^Music, row: fx.Rect, section: Queue_Section, index: int, overlay := false) -> bool {
	visible_hover := !overlay && ui_hover(queue_view_bounds) && ui_hover(row)
	id_value := uint(uintptr(song)) ~ uint(section) * 0x27d4eb2d ~ uint(index)
	hover_anim := ui_animate(ui_id(61, id_value), visible_hover, UI_HOVER_SPEED)
	playing := player.music == song

	background := fx.color_opacity(COLOR_HOVER, hover_anim)
	if overlay {
		fx.draw_rect({row.x + 2, row.y + 5, row.w, row.h}, fx.color_opacity(COLOR_BACKGROUND, .55), 8)
		fx.draw_rect(fx.rect_expand(row, 1, 1), fx.color_opacity(COLOR_ACCENT_BRIGHT, .72), 8)
		background = COLOR_HOVER
	}
	if background.a > 0 do fx.draw_rect(row, background, 7)

	handle := fx.Rect{row.x + 3, row.y, 30, row.h}
	handle_hovered := visible_hover && ui_hover(handle)
	draw_queue_handle(handle, handle_hovered || overlay ? COLOR_TEXT : COLOR_MUTED)
	if handle_hovered {
		fx.set_cursor(.SizeAll)
		if fx.key_is_pressed(.Mouse_Left) && ui_active == UI_NONE {
			queue_begin_drag(song, section, index, row)
		}
	}

	cover := fx.Rect{row.x + 36, row.y + 7, 42, 42}
	draw_cover(song.thumbnail, cover, 6)
	remove := fx.Rect{row.x + row.w - 36, row.y + 10, 30, 36}
	remove_hovered := visible_hover && ui_hover(remove)
	if remove_hovered do fx.set_cursor(.Hand)
	if remove_hovered && hover_anim > .001 do fx.draw_rect(remove, fx.color_opacity(COLOR_BORDER, hover_anim * .55), 6)
	icon_size := f32(13)
	fx.draw_texture(
		icons[.Cross],
		{remove.x + (remove.w - icon_size) * .5, remove.y + (remove.h - icon_size) * .5, icon_size, icon_size},
		remove_hovered || overlay ? COLOR_TEXT : COLOR_MUTED,
	)

	text_x := cover.x + cover.w + 11
	text_width := max(0, remove.x - text_x - 7)
	title_color := playing || overlay ? COLOR_TEXT : fx.color_lerp(COLOR_MUTED, COLOR_TEXT, hover_anim)
	fx.draw_text_faded(song.title, {text_x, row.y + 6, text_width, 25}, 13, title_color, false, true)
	secondary := song.artist
	if secondary == "" do secondary = song.album
	fx.draw_text_faded(secondary, {text_x, row.y + 29, text_width, 18}, 10, COLOR_MUTED, false, true)

	if remove_hovered && fx.key_is_pressed(.Mouse_Left) {
		return true
	}
	if visible_hover && ui_active == UI_NONE && fx.key_is_pressed(.Mouse_Right) {
		open_context_menu(song)
	}
	return false
}

draw_queue_divider :: proc(bounds: fx.Rect) {
	label := "Playlist"
	label_width := fx.measure_text(label, 11).x + 18
	center_x := bounds.x + bounds.w * .5
	line_y := bounds.y + bounds.h * .5
	left_width := max(0, center_x - label_width * .5 - bounds.x - 5)
	right_x := center_x + label_width * .5
	right_width := max(0, bounds.x + bounds.w - right_x - 5)
	fx.draw_rect({bounds.x + 5, line_y, left_width, 1}, COLOR_BORDER)
	fx.draw_rect({right_x, line_y, right_width, 1}, COLOR_BORDER)
	fx.draw_text(label, {center_x - label_width * .5, bounds.y, label_width, bounds.h}, 11, COLOR_MUTED, true, true)
}

draw_queue :: proc(bounds: fx.Rect) {
	queue_view_bounds = bounds
	remove_section := Queue_Section.None
	remove_index := -1
	if queue_drag.song != nil {
		edge := f32(42)
		mouse_y := fx.mouse_pos().y
		if mouse_y < bounds.y + edge {
			queue_scroll.target -= (bounds.y + edge - mouse_y) / edge * 480 * fx.frame_time()
		} else if mouse_y > bounds.y + bounds.h - edge {
			queue_scroll.target += (mouse_y - (bounds.y + bounds.h - edge)) / edge * 480 * fx.frame_time()
		}
	}

	if layout_begin(bounds, padding = QUEUE_PADDING, gap = QUEUE_ROW_GAP, scroll = &queue_scroll, background = COLOR_SURFACE) {
		if queue_drag.song != nil do queue_update_drag_target(bounds)

		for song, index in player.queue {
			target := layout_next(QUEUE_ROW_HEIGHT)
			if queue_drag.song != nil && queue_drag.section == .Queue && queue_drag.index == index do continue
			id := queue_entry_id(player.queue[:], index, .Queue)
			row := target
			row.y = queue_animate_row_y(id, target.y)
			if !fx.rect_overlaps(row, bounds) do continue
			if draw_queue_song(song, row, .Queue, index) {
				remove_section = .Queue
				remove_index = index
			}
		}

		divider_target := layout_next(QUEUE_DIVIDER_HEIGHT)
		divider := divider_target
		divider.y = queue_animate_row_y(ui_id(62, 0), divider_target.y)
		if fx.rect_overlaps(divider, bounds) do draw_queue_divider(divider)

		if len(player.songs) == 0 {
			empty := layout_next(QUEUE_EMPTY_HEIGHT)
			if fx.rect_overlaps(empty, bounds) {
				fx.draw_text("No playlist songs", empty, 11, fx.color_opacity(COLOR_MUTED, .72), true, true)
			}
		} else {
			for song, index in player.songs {
				target := layout_next(QUEUE_ROW_HEIGHT)
				if queue_drag.song != nil && queue_drag.section == .Playlist && queue_drag.index == index do continue
				id := queue_entry_id(player.songs[:], index, .Playlist)
				row := target
				row.y = queue_animate_row_y(id, target.y)
				if !fx.rect_overlaps(row, bounds) do continue
				if draw_queue_song(song, row, .Playlist, index) {
					remove_section = .Playlist
					remove_index = index
				}
			}
		}
	}
	if remove_index >= 0 {
		if remove_section == .Queue {
			ordered_remove(&player.queue, remove_index)
		} else if remove_section == .Playlist {
			queue_remove_playlist_song(remove_index)
		}
	}

	if queue_drag.song != nil {
		overlay := fx.Rect{queue_drag.row_x, fx.mouse_pos().y - queue_drag.grab_offset, queue_drag.row_w, QUEUE_ROW_HEIGHT}
		_ = draw_queue_song(queue_drag.song, overlay, queue_drag.section, queue_drag.index, true)
		if fx.key_is_released(.Mouse_Left) do queue_finish_drag()
	}
}

draw_queue_toggle :: proc(bounds: fx.Rect) {
	button := fx.Rect{bounds.x + bounds.w - 50, bounds.y + 14, 34, 34}
	hovered := ui_active == UI_NONE && ui_hover(button)
	hover_anim := ui_animate(ui_id(31, uint(Icon.Queue)), hovered, UI_HOVER_SPEED)
	background := fx.color_opacity(COLOR_SURFACE, 0)
	if queue_active {
		background = fx.color_opacity(COLOR_ACCENT, .30)
	} else if hover_anim > .001 {
		background = fx.color_opacity(COLOR_HOVER, hover_anim)
	}
	if background.a > 0 do fx.draw_rect(button, background, button.h * .5)
	icon_size := button.h * .46
	tint := queue_active ? COLOR_TEXT : fx.color_lerp(COLOR_MUTED, COLOR_TEXT, hover_anim)
	fx.draw_texture(
		icons[.Queue],
		{button.x + (button.w - icon_size) * .5, button.y + (button.h - icon_size) * .5, icon_size, icon_size},
		tint,
	)
	if hovered {
		fx.set_cursor(.Hand)
		if fx.key_is_pressed(.Mouse_Left) {
			queue_active = !queue_active
			if !queue_active && queue_drag.song != nil {
				queue_drag = {}
				ui_active = UI_NONE
			}
		}
	}
}
