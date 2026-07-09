package main

import "core:math"
import "core:math/ease"

import "fx"

show_queue := false
queue_scroll: Scroll_State

QUEUE_ITEM_H :: f32(46)
QUEUE_SEPARATOR_H :: f32(28)
QUEUE_GAP :: f32(8)
QUEUE_PADDING :: f32(8)

Queue_List :: enum {
	Queue,
	Songs,
}

Queue_Drag :: struct {
	active:       bool,
	song:         ^Music,
	source:       Queue_List,
	source_index: int,
	target:       Queue_List,
	target_index: int,
	grab_y:       f32,
	last_y:       f32,
}

queue_drag: Queue_Drag
queue_row_y: map[int]f32

ui_queue :: proc() {
	rect := layout_next()

	queue_update_drag(rect)

	if layout_start(rect, &queue_scroll, padding = QUEUE_PADDING, gap = QUEUE_GAP) {
		fx.draw_rect(rect, PRIMARY_DARK, 12)

		action_taken := false
		for song, i in player.queue {
			item_rect := layout_next(QUEUE_ITEM_H)
			if queue_draw_item(.Queue, i, song, item_rect, rect) {
				action_taken = true
				break
			}
		}

		if !action_taken {
			separator_rect := queue_visual_separator_rect(layout_next(QUEUE_SEPARATOR_H), rect)
			queue_draw_separator(separator_rect)

			for song, i in player.songs {
				item_rect := layout_next(QUEUE_ITEM_H)
				if queue_draw_item(.Songs, i, song, item_rect, rect) {
					action_taken = true
					break
				}
			}
		}

		queue_draw_dragged_item(rect)

		ui_gradients(rect, queue_scroll.current, queue_scroll.content_size, 40, PRIMARY_DARK, 6)
	}
}

queue_update_drag :: proc(rect: fx.Rect) {
	if !queue_drag.active do return

	queue_auto_scroll(rect)
	queue_drag.target, queue_drag.target_index = queue_target_from_mouse(rect)
	queue_drag.last_y = fx.mouse_pos().y - queue_drag.grab_y

	if fx.key_is_down(.Mouse_Left) {
		fx.set_cursor(.SizeAll)
		return
	}

	queue_finish_drag()
}

queue_auto_scroll :: proc(rect: fx.Rect) {
	mouse := fx.mouse_pos()
	edge := min(f32(56), rect.h * 0.35)
	dt := fx.frame_time()

	speed: f32
	if mouse.y < rect.y + edge {
		speed = -math.pow((rect.y + edge - mouse.y) / edge, 2) * 620
	} else if mouse.y > rect.y + rect.h - edge {
		speed = math.pow((mouse.y - (rect.y + rect.h - edge)) / edge, 2) * 620
	}

	if speed == 0 do return

	max_scroll := max(queue_scroll.content_size + QUEUE_PADDING * 2 - rect.h, 0)
	queue_scroll.target = clamp(queue_scroll.target + speed * dt, 0, max_scroll)
}

queue_target_from_mouse :: proc(rect: fx.Rect) -> (Queue_List, int) {
	content_y := fx.mouse_pos().y - rect.y + queue_scroll.current - QUEUE_PADDING
	queue_count := len(player.queue)

	for i in 0..<queue_count {
		row_y := f32(i) * (QUEUE_ITEM_H + QUEUE_GAP)
		if content_y < row_y + QUEUE_ITEM_H * 0.5 {
			return .Queue, i
		}
	}

	separator_y := f32(queue_count) * (QUEUE_ITEM_H + QUEUE_GAP)
	if content_y < separator_y + QUEUE_SEPARATOR_H * 0.5 {
		return .Queue, queue_count
	}

	songs_y := separator_y + QUEUE_SEPARATOR_H + QUEUE_GAP
	if content_y < songs_y {
		return .Songs, 0
	}

	for i in 0..<len(player.songs) {
		row_y := songs_y + f32(i) * (QUEUE_ITEM_H + QUEUE_GAP)
		if content_y < row_y + QUEUE_ITEM_H * 0.5 {
			return .Songs, i
		}
	}

	return .Songs, len(player.songs)
}

queue_finish_drag :: proc() {
	defer {
		queue_drag = {}
		if drag_id == int(UI_ID.Queue_Item) {
			drag_id = 0
		}
	}

	if queue_drag.song == nil do return
	if !queue_index_matches(queue_drag.source, queue_drag.source_index, queue_drag.song) do return

	destination := queue_drag.target
	destination_index := queue_drag.target_index

	if queue_drag.source == destination {
		if destination_index == queue_drag.source_index || destination_index == queue_drag.source_index + 1 {
			return
		}
	}

	if queue_drag.source == .Songs && destination == .Queue && len(player.songs) <= 1 {
		return
	}

	queue_move_song(queue_drag.source, queue_drag.source_index, destination, destination_index, queue_drag.last_y)
}

queue_move_song :: proc(source: Queue_List, source_index: int, destination: Queue_List, destination_index: int, seed_y: f32) {
	song := queue_song_at(source, source_index)
	if song == nil do return

	insert_index := queue_adjusted_target_index_for(source, source_index, destination, destination_index)
	queue_remove_at(source, source_index)
	insert_index = clamp(insert_index, 0, queue_list_len(destination))
	queue_insert_at(destination, insert_index, song)
	queue_sync_cursor()

	key := queue_item_key(destination, insert_index, song)
	if queue_row_y == nil {
		queue_row_y = make(map[int]f32)
	}
	queue_row_y[key] = seed_y
}

queue_draw_item :: proc(list: Queue_List, index: int, song: ^Music, target_rect, panel_rect: fx.Rect) -> (action_taken: bool) {
	key := queue_item_key(list, index, song)
	is_dragged := queue_drag.active && queue_drag.source == list && queue_drag.source_index == index && queue_drag.song == song
	rect := is_dragged ? queue_placeholder_rect(panel_rect, target_rect) : queue_visual_item_rect(list, index, key, target_rect, panel_rect)

	if is_dragged {
		if fx.rect_overlapping(panel_rect, rect) {
			ghost := fx.rect_shrink(rect, 1, 4)
			fx.draw_rect(ghost, fx.color_opacity(PRIMARY_BRIGHT, 0.25), 6)
		}
		return
	}

	if !fx.rect_overlapping(panel_rect, rect) do return false

	hovered := mouse_hover(rect)
	is_playing := player.music == song
	hover_anim := animate(key, hovered || is_playing)

	base := is_playing ? ACCENT_DARK : PRIMARY_DARK
	hot := is_playing ? ACCENT_COLOR : HOVER_COLOR
	if hover_anim > 0 || is_playing {
		fx.draw_rect(rect, fx.color_lerp(base, hot, hover_anim), 6)
	}

	if hovered && fx.key_is_pressed(.Mouse_Right) {
		open_context_menu(song)
	}

	handle_rect := fx.Rect{rect.x + 8, rect.y + 8, 24, rect.h - 16}
	handle_hover := mouse_hover(handle_rect)
	if handle_hover {
		fx.set_cursor(.SizeAll)
		if fx.key_is_pressed(.Mouse_Left) && drag_id == 0 {
			queue_begin_drag(list, index, song, rect)
		}
	}

	queue_draw_handle(handle_rect, handle_hover ? TEXT_PRIMARY : TEXT_SECONDARY)

	delete_size := f32(28)
	delete_rect := fx.Rect{rect.x + rect.w - 36, rect.y + (rect.h - delete_size) * 0.5, delete_size, delete_size}
	delete_hover := mouse_hover(delete_rect)
	if delete_hover {
		fx.set_cursor(.Hand)
		if fx.key_is_pressed(.Mouse_Left) {
			queue_delete_item(list, index, rect)
			return true
		}
	}

	cover_rect := fx.Rect{rect.x + 42, rect.y + 6, 34, 34}
	if layout_start(cover_rect) {
		ui_cover(song.thumbnail, 4)
	}

	text_x := cover_rect.x + cover_rect.w + 12
	text_w := max(delete_rect.x - text_x - 8, 0)
	title_rect := fx.Rect{text_x, rect.y + 6, text_w, 20}
	artist_rect := fx.Rect{text_x, rect.y + 25, text_w, 17}

	c1 := (hovered || is_playing) ? TEXT_PRIMARY : TEXT_SECONDARY
	c2 := (hovered || is_playing) ? TEXT_SECONDARY : fx.color_brightness(TEXT_SECONDARY, 0.6)

	fx.draw_text_faded(font, song.title, title_rect, 15, c1, true)
	fx.draw_text_faded(font, song.artist, artist_rect, 12, c2, true)

	cross_color := delete_hover ? TEXT_PRIMARY : fx.color_brightness(TEXT_SECONDARY, 0.75)
	fx.draw_texture(icons[.Cross], fx.rect_shrink(delete_rect, 8, 8), cross_color)

	return false
}

queue_draw_separator :: proc(rect: fx.Rect) {
	if rect.h <= 0 do return

	line_y := rect.y + rect.h * 0.5
	label_w := fx.measure_text(font, "Playlist", 11).x + 16
	label_rect := fx.Rect{rect.x + (rect.w - label_w) * 0.5, rect.y + 4, label_w, rect.h - 8}

	fx.draw_rect({rect.x + 8, line_y - 1, max((rect.w - label_w) * 0.5 - 16, 0), 2}, PRIMARY_BRIGHT, 1)
	fx.draw_rect({label_rect.x + label_rect.w + 8, line_y - 1, max(rect.x + rect.w - label_rect.x - label_rect.w - 16, 0), 2}, PRIMARY_BRIGHT, 1)
	fx.draw_rect(label_rect, PRIMARY_COLOR, 5)
	fx.draw_text(font, "Playlist", label_rect, 11, TEXT_SECONDARY, true, true)
}

queue_begin_drag :: proc(list: Queue_List, index: int, song: ^Music, rect: fx.Rect) {
	drag_id = int(UI_ID.Queue_Item)
	queue_drag = Queue_Drag {
		active = true,
		song = song,
		source = list,
		source_index = index,
		target = list,
		target_index = index,
		grab_y = fx.mouse_pos().y - rect.y,
		last_y = rect.y,
	}
	context_menu.selection = nil
	context_menu.rect = {}
}

queue_draw_dragged_item :: proc(panel_rect: fx.Rect) {
	if !queue_drag.active || queue_drag.song == nil do return

	mouse := fx.mouse_pos()
	rect := fx.Rect{
		panel_rect.x + QUEUE_PADDING,
		mouse.y - queue_drag.grab_y,
		max(panel_rect.w - QUEUE_PADDING * 2, 0),
		QUEUE_ITEM_H,
	}
	queue_drag.last_y = rect.y

	fx.draw_rect(fx.rect_expand(rect, 2, 2), fx.color_opacity(PRIMARY_BRIGHT, 0.85), 8)
	fx.draw_rect(rect, fx.color_opacity(HOVER_COLOR, 0.96), 6)

	queue_draw_handle({rect.x + 8, rect.y + 8, 24, rect.h - 16}, TEXT_PRIMARY)
	if layout_start({rect.x + 42, rect.y + 6, 34, 34}) {
		ui_cover(queue_drag.song.thumbnail, 4)
	}

	text_x := rect.x + 88
	text_w := max(rect.w - 132, 0)
	fx.draw_text_faded(font, queue_drag.song.title, {text_x, rect.y + 6, text_w, 20}, 15, TEXT_PRIMARY, true)
	fx.draw_text_faded(font, queue_drag.song.artist, {text_x, rect.y + 25, text_w, 17}, 12, TEXT_SECONDARY, true)
}

queue_content_y :: proc(list: Queue_List, index, queue_count: int) -> f32 {
	if list == .Queue {
		return f32(index) * (QUEUE_ITEM_H + QUEUE_GAP)
	}

	songs_y := f32(queue_count) * (QUEUE_ITEM_H + QUEUE_GAP) + QUEUE_SEPARATOR_H + QUEUE_GAP
	return songs_y + f32(index) * (QUEUE_ITEM_H + QUEUE_GAP)
}

queue_visual_item_rect :: proc(list: Queue_List, index, key: int, target_rect, panel_rect: fx.Rect) -> fx.Rect {
	if !queue_drag.active {
		return queue_animated_rect(key, target_rect)
	}

	visual_list, visual_index := queue_virtual_item_position(list, index)
	content_y := queue_content_y(visual_list, visual_index, queue_virtual_queue_len())
	target := target_rect
	target.y = panel_rect.y + QUEUE_PADDING - queue_scroll.current + content_y
	return queue_animated_rect(key, target)
}

queue_visual_separator_rect :: proc(target_rect, panel_rect: fx.Rect) -> fx.Rect {
	if !queue_drag.active {
		return queue_animated_rect(int(UI_ID.Queue_Item) + 700000, target_rect)
	}

	target := target_rect
	content_y := f32(queue_virtual_queue_len()) * (QUEUE_ITEM_H + QUEUE_GAP)
	target.y = panel_rect.y + QUEUE_PADDING - queue_scroll.current + content_y
	return queue_animated_rect(int(UI_ID.Queue_Item) + 700000, target)
}

queue_placeholder_rect :: proc(panel_rect, template: fx.Rect) -> fx.Rect {
	target := template
	content_y := queue_content_y(queue_drag.target, queue_adjusted_target_index(), queue_virtual_queue_len())
	target.y = panel_rect.y + QUEUE_PADDING - queue_scroll.current + content_y
	return queue_animated_rect(int(UI_ID.Queue_Item) + 710000, target)
}

queue_virtual_item_position :: proc(list: Queue_List, index: int) -> (Queue_List, int) {
	visual_index := index

	if queue_drag.source == list && index > queue_drag.source_index {
		visual_index -= 1
	}

	if queue_drag.target == list && visual_index >= queue_adjusted_target_index() {
		visual_index += 1
	}

	return list, visual_index
}

queue_virtual_queue_len :: proc() -> int {
	count := len(player.queue)
	if !queue_drag.active do return count

	if queue_drag.source == .Queue do count -= 1
	if queue_drag.target == .Queue do count += 1
	return count
}

queue_adjusted_target_index :: proc() -> int {
	return queue_adjusted_target_index_for(queue_drag.source, queue_drag.source_index, queue_drag.target, queue_drag.target_index)
}

queue_adjusted_target_index_for :: proc(source: Queue_List, source_index: int, target: Queue_List, target_index: int) -> int {
	index := target_index
	if source == target && index > source_index {
		index -= 1
	}

	max_index := queue_list_len(target)
	if source == target {
		max_index -= 1
	}
	return clamp(index, 0, max_index)
}

queue_delete_item :: proc(list: Queue_List, index: int, rect: fx.Rect) {
	if list == .Songs && len(player.songs) <= 1 {
		return
	}

	song := queue_song_at(list, index)
	if song == nil do return

	queue_remove_at(list, index)
	queue_sync_cursor()
}

queue_animated_rect :: proc(key: int, target: fx.Rect) -> fx.Rect {
	if queue_row_y == nil {
		queue_row_y = make(map[int]f32)
	}

	y := target.y
	if prev, ok := queue_row_y[key]; ok {
		t := ease.cubic_out(clamp(fx.frame_time() * 14, 0, 1))
		y = math.lerp(prev, target.y, t)
		if abs(y - target.y) < 0.2 {
			y = target.y
		}
	}
	queue_row_y[key] = y

	return fx.Rect{target.x, y, target.w, target.h}
}

queue_item_key :: proc(list: Queue_List, index: int, song: ^Music) -> int {
	offset := list == .Queue ? 900000 : 1200000
	return int(uintptr(song)) + offset + queue_occurrence(list, index, song) * 1009
}

queue_occurrence :: proc(list: Queue_List, index: int, song: ^Music) -> int {
	count := 0

	switch list {
	case .Queue:
		for s, i in player.queue {
			if i >= index do break
			if s == song do count += 1
		}
	case .Songs:
		for s, i in player.songs {
			if i >= index do break
			if s == song do count += 1
		}
	}

	return count
}

queue_draw_handle :: proc(rect: fx.Rect, color: fx.Color) {
	x := rect.x + (rect.w - 12) * 0.5
	y := rect.y + (rect.h - 12) * 0.5

	for row in 0..<3 {
		for col in 0..<2 {
			fx.draw_circle({x + f32(col) * 8, y + f32(row) * 6}, 1.6, color)
		}
	}
}

queue_song_at :: proc(list: Queue_List, index: int) -> ^Music {
	if index < 0 do return nil

	switch list {
	case .Queue:
		if index >= len(player.queue) do return nil
		return player.queue[index]
	case .Songs:
		if index >= len(player.songs) do return nil
		return player.songs[index]
	}

	return nil
}

queue_index_matches :: proc(list: Queue_List, index: int, song: ^Music) -> bool {
	return queue_song_at(list, index) == song
}

queue_list_len :: proc(list: Queue_List) -> int {
	switch list {
	case .Queue:
		return len(player.queue)
	case .Songs:
		return len(player.songs)
	}

	return 0
}

queue_remove_at :: proc(list: Queue_List, index: int) {
	switch list {
	case .Queue:
		ordered_remove(&player.queue, index)
	case .Songs:
		ordered_remove(&player.songs, index)
	}
}

queue_insert_at :: proc(list: Queue_List, index: int, song: ^Music) {
	switch list {
	case .Queue:
		inject_at(&player.queue, index, song)
	case .Songs:
		inject_at(&player.songs, index, song)
	}
}

queue_sync_cursor :: proc() {
	if len(player.songs) == 0 {
		player.cursor = 0
		return
	}

	if player.music != nil {
		for song, i in player.songs {
			if song == player.music {
				player.cursor = i
				return
			}
		}
	}

	player.cursor = clamp(player.cursor, 0, len(player.songs) - 1)
}
