package main

import "core:slice"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:hash/xxhash"
import "core:container/bit_array"
import "core:unicode"

import "fx"

SearchMatch :: struct {
	music: ^Music,
	score: int,
}

search : struct {
	box:        	edit.State,
	builder:    	strings.Builder,
	results:    	[dynamic]^Music,
	initialized:    bool,
	focused:   		bool,
	active:     	bool,
	last_query:     string,
	filter_artist:  string,
	filter_album:   string,
	blink_timer:    f32,
	scroll: 		f32,
}

open_search_filtered_by :: proc(artist := "", album := "") {
	search.focused = true
	search.active = true
	strings.builder_reset(&search.builder)
	search.filter_artist = artist
	search.filter_album = album
	search.initialized = false
}

close_search :: proc() {
	strings.builder_reset(&search.builder)
	search.initialized = false
	search.filter_artist = ""
	search.filter_album = ""
	search.focused = false
	search.active = false
	search.box.selection = {0, 0}
	if drag_id == int(UI_ID.Search) do drag_id = 0
}

handle_search_input :: proc() {
	prev_sel := search.box.selection

	runes := fx.text_input()
	edit.update_time(&search.box)
	edit.input_runes(&search.box, runes)

	shift := fx.key_is_down(.Shift)
	ctrl  := fx.key_is_down(.Ctrl)

	if fx.key_is_pressed(.Backspace) {
		if strings.builder_len(search.builder) == 0 && (search.filter_artist != "" || search.filter_album != "") {
        	search.filter_artist = ""
        	search.filter_album = ""
        	search.initialized = false
		} else {
			edit.perform_command(&search.box, ctrl ? .Delete_Word_Left : .Backspace)
		}
	}

	if fx.key_is_pressed_repeat(.Left) {
		switch {
		case shift && ctrl: edit.perform_command(&search.box, .Select_Word_Left)
		case shift:         edit.perform_command(&search.box, .Select_Left)
		case ctrl:          edit.perform_command(&search.box, .Word_Left)
		case:               edit.perform_command(&search.box, .Left)
		}
	}
	if fx.key_is_pressed_repeat(.Right) {
		switch {
		case shift && ctrl: edit.perform_command(&search.box, .Select_Word_Right)
		case shift:         edit.perform_command(&search.box, .Select_Right)
		case ctrl:          edit.perform_command(&search.box, .Word_Right)
		case:               edit.perform_command(&search.box, .Right)
		}
	}

	if fx.key_is_pressed(.Delete) do edit.perform_command(&search.box, ctrl ? .Delete_Word_Right : .Delete)
	if fx.key_is_pressed(.Home) do edit.perform_command(&search.box, shift ? .Select_Line_Start : .Line_Start)
	if fx.key_is_pressed(.End) do edit.perform_command(&search.box, shift ? .Select_Line_End : .Line_End)
	if fx.key_is_pressed(.Z) && ctrl do edit.perform_command(&search.box, shift ? .Redo : .Undo)
	if fx.key_is_pressed(.A) && ctrl do edit.perform_command(&search.box, .Select_All)
	if fx.key_is_pressed(.C) && ctrl do edit.copy(&search.box)
	if fx.key_is_pressed(.X) && ctrl do edit.cut(&search.box)
	if fx.key_is_pressed(.V) && ctrl do edit.paste(&search.box)
	if fx.key_is_pressed(.Esc) do search.focused = false
	if fx.key_is_pressed(.Enter) && len(search.results) > 0 {
		player_start_playlist(search.results[:], 0)
		search.focused = false
	}

	if search.box.selection != prev_sel || len(runes) > 0 do search.blink_timer = 0
}

score_song :: proc(song: ^Music, query: string, query_words: []string) -> int {
	score := 0

	Field :: struct {
		text:  string,
		words: []string,
		mult:  int,
	}

	fields := [3]Field{
		{strings.to_lower(song.title, context.temp_allocator), nil, 10},
		{strings.to_lower(song.artist, context.temp_allocator), nil, 8},
		{strings.to_lower(song.album, context.temp_allocator), nil, 6},
	}

	for &f in fields {
		f.words = strings.split(f.text, " ", context.temp_allocator)
		if strings.has_prefix(f.text, query) do score += 10000 * f.mult
		if strings.contains(f.text, query) do score += 1000 * f.mult
	}

	for qw in query_words {
		if len(qw) == 0 do continue

		allowed_dist := 0
		if len(qw) >= 3 do allowed_dist = 1
		if len(qw) >= 5 do allowed_dist = 2
		if len(qw) >= 7 do allowed_dist = 3

		best_word_score := 0

		for f in fields {
			for w in f.words {
				if len(w) == 0 do continue
				word_score := 0
				if w == qw do word_score += 100 * f.mult
				else if strings.has_prefix(w, qw) do word_score += 50 * f.mult
				dist := strings.levenshtein_distance(qw, w, context.temp_allocator)
				if dist <= allowed_dist {
					word_score += (allowed_dist - dist + 1) * 10 * f.mult
				}
				best_word_score = max(best_word_score, word_score)
			}
		}

		if best_word_score > 0 {
			score += best_word_score
		} else {
			score -= 500
		}
	}

	if song.lyrics_filter != nil {
		query_runes := make([dynamic]rune, 0, len(query), context.temp_allocator)
		for r in query {
			if unicode.is_letter(r) || unicode.is_digit(r) {
				append(&query_runes, r)
			}
		}

		if len(query_runes) >= 5 {
			match_count := 0
			total_windows := len(query_runes) - 5 + 1

			for i in 0..<total_windows {
				bytes := slice.reinterpret([]byte, query_runes[i : i+5])
				hash := xxhash.XXH32(bytes)

				if bit_array.unsafe_get(song.lyrics_filter, uint(hash & 32767)) {
					match_count += 1
				}
			}

			if match_count > 0 {
				score += (match_count * 5000) / total_windows
			}
		}
	}

	return score
}

update_search :: proc() {
	if search.focused {
		handle_search_input()
	}

	current_query := strings.to_string(search.builder)
	if current_query == search.last_query && search.initialized do return
	search.initialized = true

	clear(&search.results)
	delete(search.last_query)
	search.last_query = strings.clone(current_query)
	query_str := strings.to_lower(current_query, context.temp_allocator)
	query_words := strings.split(query_str, " ", context.temp_allocator)

	results: [dynamic]SearchMatch
	defer delete(results)

	for playlist in playlists[1:] {
		for song in playlist.songs {
			if search.filter_artist != "" && song.artist != search.filter_artist do continue
			if search.filter_album != "" && song.album != search.filter_album do continue

			if len(query_str) == 0 {
				append(&search.results, song)
				continue
			}

			if score := score_song(song, query_str, query_words[:]); score > 0 {
				append(&results, SearchMatch{song, score})
			}
		}
	}

	if len(query_str) == 0 {
		slice.sort_by(search.results[:], proc(i, j: ^Music) -> bool {
			if search.filter_album != "" && i.track != j.track {
				return i.track < j.track
			}
			return strings.compare(i.title, j.title) == -1
		})
	} else {
		slice.sort_by(results[:], proc(i, j: SearchMatch) -> bool { return i.score > j.score })
		for r in results do append(&search.results, r.music)
	}

	songs_scroll.current = 0
	songs_scroll.target = 0
}

ui_search_bar :: proc() {
	rect := layout_next()
	query_text := strings.to_string(search.builder)
	filter_text := search.filter_artist != "" ? search.filter_artist : search.filter_album

	bounds: fx.Rect
	if layout_start(rect) {
		if layout({30, GROW, 30}, .Row) {
			layout_next()
			if layout({GROW, 36, GROW}, .Col) {
				layout_next()
				bounds = layout_next()
			}
		}
	}
	bounds.w = max(bounds.w, 0)

	fx.set_scissor(bounds)
	hovered := mouse_hover(bounds)

	was_focused := search.focused
	if fx.mouse_is_pressed(.Left) {
		if hovered {
			search.active = true
			search.focused = true
		} else {
			if !mouse_hover(rect) {
				search.focused = false
			}
			clicked_outside_box := mouse_hover(rect) && !mouse_hover(bounds)
			if clicked_outside_box && strings.builder_len(search.builder) == 0 && !(context_menu.selection != nil || drag_id != 0) {
				close_search()
			}
		}
	}

	anim_t := animate(int(UI_ID.Search), search.focused || hovered)
	bg := fx.color_lerp(PRIMARY_COLOR, HOVER_COLOR, anim_t)

	fx.rect(bounds, bg, 18)
	fx.sprite(icons[.Search], {bounds.x + 14, bounds.y + 10, 16, 16}, TEXT_SECONDARY)

	offset_x := f32(38)
	if filter_text != "" {
		filter_w := fx.text_size(font, filter_text, 12).x + 16
		fx.rect({bounds.x + offset_x, bounds.y + 8, filter_w, 20}, ACCENT_BRIGHT, 4)
		fx.text(font, filter_text, {bounds.x + offset_x, bounds.y + 8, filter_w, 20}, 12, TEXT_PRIMARY, true, true)
		offset_x += filter_w + 8
	}

	if len(query_text) > 0 || search.active {
		discard_w := f32(12)
		discard_pos := fx.Vec2{bounds.x + bounds.w - 26, bounds.y + (bounds.h - discard_w) * 0.5}
		hover_discard := mouse_hover({discard_pos.x - 4, discard_pos.y - 4, discard_w + 8, discard_w + 8})

		if hover_discard {
			fx.set_cursor(.Hand)
			if fx.mouse_is_pressed(.Left) {
				close_search()
			}
		}

		fx.sprite(icons[.Cross], {discard_pos.x, discard_pos.y, discard_w, discard_w}, hover_discard ? TEXT_PRIMARY : TEXT_SECONDARY)
	}

	bounds.x += offset_x
	bounds.w -= offset_x

	visible_w := max(bounds.w - 33, 0)
	update_search_scroll(query_text, visible_w)
	handle_search_drag(query_text, bounds)

	fx.set_scissor({bounds.x, bounds.y, visible_w, bounds.h})
	ui_search_selection(query_text, bounds)

	search_text_rect := fx.Rect{bounds.x - search.scroll, bounds.y, bounds.w + search.scroll, bounds.h}
	if len(query_text) == 0 && !search.focused && !was_focused {
		fx.text(font, "Search...", search_text_rect, 14, TEXT_SECONDARY, false, true)
	} else {
		fx.text(font, query_text, search_text_rect, 14, TEXT_PRIMARY, false, true)
	}

	fx.reset_scissor()
}

ui_search_selection :: proc(query_text: string, bounds: fx.Rect) {
	lo, hi := edit.sorted_selection(&search.box)
	if lo != hi {
		before_w := fx.text_size(font, query_text[:lo], 14).x
		sel_w := fx.text_size(font, query_text[lo:hi], 14).x
		fx.rect({bounds.x + before_w - search.scroll - 2, bounds.y + 7, sel_w + 4, 20}, ACCENT_BRIGHT, 3)
	} else if search.focused {
		cursor_idx := clamp(search.box.selection[0], 0, len(query_text))
		str_before_cursor := query_text[:cursor_idx]
		cursor_x := bounds.x - search.scroll

		if len(str_before_cursor) > 0 {
			cursor_x += fx.text_size(font, str_before_cursor, 14).x
		}

		search.blink_timer += fx.frame_time()
		if search.blink_timer < 0.5 {
			fx.rect({cursor_x, bounds.y + 10, 2, 15}, fx.WHITE, 2)
		} else if search.blink_timer > 1.0 {
			search.blink_timer = 0
		}
	}
}

update_search_scroll :: proc(query_text: string, visible_w: f32) {
	if !search.focused {
		search.scroll = 0
		return
	}
	cursor_idx := clamp(search.box.selection[0], 0, len(query_text))
	cursor_rel_x := len(query_text[:cursor_idx]) > 0 ? fx.text_size(font, query_text[:cursor_idx], 14).x : 0

	if cursor_rel_x - search.scroll > visible_w - 10 {
		search.scroll = cursor_rel_x - visible_w + 10
	}
	if cursor_rel_x - search.scroll < 10 {
		search.scroll = cursor_rel_x - 10
	}
	search.scroll = max(search.scroll, 0)
}

handle_search_drag :: proc(query_text: string, bounds: fx.Rect) {
	hovered := mouse_hover(bounds)

	if !search.focused || !fx.mouse_is_down(.Left) {
		if drag_id == int(UI_ID.Search) do drag_id = 0
	}

	if drag_id != 0 && drag_id != int(UI_ID.Search) do return
	if drag_id != int(UI_ID.Search) {
		if !hovered || !fx.mouse_is_pressed(.Left) do return
		drag_id = int(UI_ID.Search)
	}

	mouse := fx.mouse_pos()
	mouse_x := mouse.x - bounds.x + search.scroll

	closest_idx := 0
	closest_dist := abs(mouse_x)
	current_idx := 0
	for r, i in query_text {
		current_idx = i + utf8.rune_size(r)
		sub_w := fx.text_size(font, query_text[:current_idx], 14).x
		if dist := abs(sub_w - mouse_x); dist < closest_dist {
			closest_dist = dist
			closest_idx = current_idx
		}
	}

	if fx.mouse_is_pressed(.Left) {
		search.box.selection = {closest_idx, closest_idx}
	} else {
		search.box.selection[0] = closest_idx
	}
	search.blink_timer = 0
}