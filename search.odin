package main

import "core:hash"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:text/edit"
import "core:unicode/utf8"
import "core:container/bit_array"

import "fx"

Search_Match :: struct {
	music: ^Music,
	score: int,
}

Search_Filter :: enum {
	None,
	Artist,
	Album,
}

textbox: edit.State

search: struct {
	active: bool,
	focused: bool,
	filter: string,
	filter_type: Search_Filter,
	results: [dynamic]^Music,
}

search_open :: proc(filter := "", type: Search_Filter = .None) {
	search.active = true
	search.focused = true
	search.filter = filter
	search.filter_type = type
	update_search()
}

search_close :: proc() {
	edit.clear_all(&textbox)
	search.active = false
	search.focused = false
	search.filter = ""
	search.filter_type = .None
	clear(&search.results)
}

search_score :: proc(song: ^Music, query: string, words: []string) -> int {
	score := 0
	Field :: struct {text: string, words: []string, weight: int}

	fields := [3]Field{
		{strings.to_lower(song.title, context.temp_allocator), nil, 10},
		{strings.to_lower(song.artist, context.temp_allocator), nil, 8},
		{strings.to_lower(song.album, context.temp_allocator), nil, 6},
	}

	for &field in fields {
		field.words = strings.split(field.text, " ", context.temp_allocator)
		if strings.has_prefix(field.text, query) do score += 10000 * field.weight
		if strings.contains(field.text, query) do score += 1000 * field.weight
	}

	for query_word in words {
		if query_word == "" do continue
		allowed_distance := 0
		if len(query_word) >= 3 do allowed_distance = 1
		if len(query_word) >= 5 do allowed_distance = 2
		if len(query_word) >= 7 do allowed_distance = 3
		best_word_score := 0
		for field in fields {
			for candidate in field.words {
				if candidate == "" do continue
				word_score := 0
				if candidate == query_word do word_score += 100 * field.weight
				else if strings.has_prefix(candidate, query_word) do word_score += 50 * field.weight
				distance := strings.levenshtein_distance(query_word, candidate, context.temp_allocator)
				if distance <= allowed_distance {
					word_score += (allowed_distance - distance + 1) * 10 * field.weight
				}
				best_word_score = max(best_word_score, word_score)
			}
		}
		if best_word_score > 0 do score += best_word_score
		else do score -= 500
	}

	if len(song.lyrics_filter.bits) > 0 {
		runes := make([dynamic]rune, 0, len(query), context.temp_allocator)
		for character in query {
			if unicode.is_letter(character) || unicode.is_digit(character) {
				append(&runes, character)
			}
		}
		if len(runes) >= 5 {
			match_count := 0
			window_count := len(runes) - 4
			for index in 0..<window_count {
				bytes := slice.reinterpret([]byte, runes[index:index + 5])
				if bit_array.unsafe_get(&song.lyrics_filter, uint(hash.fnv32a(bytes) & 32767)) {
					match_count += 1
				}
			}
			if match_count > 0 do score += match_count * 5000 / window_count
		}
	}

	return score
}

update_search :: proc() {
	if !search.active do return

	query_text := string(textbox.builder.buf[:])
	clear(&search.results)

	state := get_scroll_state(get_id("SongsList"))
	state.scroll_target.y = 0
	state.scroll.y = 0

	query := strings.to_lower(strings.trim_space(query_text), context.temp_allocator)
	if query == "" {
		for playlist in playlists[LIBRARY_PLAYLIST_START:] {
			for song in playlist.songs {
				if search.filter_type == .Artist && song.artist != search.filter do continue
				if search.filter_type == .Album && song.album != search.filter do continue
				append(&search.results, song)
			}
		}
		slice.sort_by(search.results[:], proc(a, b: ^Music) -> bool {
			if search.filter_type == .Album && a.track != b.track do return a.track < b.track
			return strings.compare(a.title, b.title) == -1
		})
		return
	}

	matches: [dynamic]Search_Match
	defer delete(matches)
	words := strings.split(query, " ", context.temp_allocator)
	for playlist in playlists[LIBRARY_PLAYLIST_START:] {
		for song in playlist.songs {
			if search.filter_type == .Artist && song.artist != search.filter do continue
			if search.filter_type == .Album && song.album != search.filter do continue
			if score := search_score(song, query, words); score > 0 {
				append(&matches, Search_Match{song, score})
			}
		}
	}

	slice.sort_by(matches[:], proc(a, b: Search_Match) -> bool {return a.score > b.score})
	for match in matches do append(&search.results, match.music)
}

draw_search_box :: proc() {
	if search.active {
		if fx.key_is_pressed(.Esc) {
			if search.focused {
				search.focused = false
				textbox.selection[0] = 0
				textbox.selection[1] = 0
			} else {
				search_close()
			}
		}

		if fx.key_is_pressed(.Enter) && len(search.results) > 0 {
			player_start_playlist(search.results[:], 0)
		}
	}

	if begin("SearchBox", pad = 8, gap = 4) {
		bounds := get_layout().rect
		bg_id := get_id("SearchBoxBg")
		tb_id := get_id("SearchBox")
		close_id := get_id("close-search")

		update_control(bg_id, bounds)
		hovered := ctx.hover_id == bg_id || ctx.hover_id == tb_id || ctx.hover_id == close_id

		background := (search.focused || hovered) ? ROW_COLOR.hover : COLOR_SURFACE

		if search.focused {
			fx.draw_rect(fx.rect_expand(bounds, 1), COLOR_ACCENT, 8)
			fx.draw_rect(bounds, background, 7)
		} else {
			fx.draw_rect(bounds, background, 8)
		}

		if fx.key_is_pressed(.Mouse_Left) || fx.key_is_pressed(.Mouse_Right) && !hovered {
			search.focused = false
			textbox.selection[0] = len(textbox.builder.buf)
			textbox.selection[1] = len(textbox.builder.buf)
		}

		show_close := len(textbox.builder.buf) > 0 || search.active

		badge_width := f32(0)
		if search.filter != "" {
			badge_width = min(fx.measure_text(search.filter, 10).x + 32, bounds.size.x * 0.5)
		}

		widths: [dynamic; 4]f32
		append(&widths, f32(26))
		if badge_width > 0.5 do append(&widths, badge_width)
		append(&widths, f32(-1))
		if show_close do append(&widths, f32(24))

		layout_row(widths[:], -1)
		draw_icon(.Search, layout_next(), 24, COLOR_MUTED)

		if badge_width > 0.5 {
			rect := layout_next()
			fx.draw_rect(rect, COLOR_ACCENT, 6)
			filter_icon := search.filter_type == .Artist ? Icon.Artist : Icon.Album
			filter_rect := fx.Rect{{rect.pos.x + 5, rect.pos.y}, {16, rect.size.y}}
			draw_icon(filter_icon, filter_rect, 16, fx.WHITE)
			fx.draw_text_faded(search.filter, fx.Rect{{rect.pos.x + 24, rect.pos.y}, {badge_width - 32, rect.size.y}}, 10, fx.WHITE)
		}

		text_rect := layout_next()

		res := update_control(tb_id, text_rect)

		if .HOVER in res do fx.set_cursor(.IBeam)
		if .ACTIVE in res {
			if !search.active do search_open()
			search.focused = true
		}

		text := string(textbox.builder.buf[:])
		if len(text) == 0 && !search.focused {
			fx.draw_text_faded("Search tracks, artists, lyrics", text_rect, 16, COLOR_MUTED)
		} else {
			draw_textbox(text_rect, 16)
		}

		if show_close {
			close_rect := layout_next()
			close_res := update_control(get_id("close-search"), close_rect)
			cross_color := .HOVER in close_res ? COLOR_TEXT : COLOR_MUTED

			draw_icon(.Cross, close_rect, 16, cross_color)

			if .HOVER in close_res && fx.key_is_pressed(.Mouse_Left) do search_close()
			if .HOVER in close_res do fx.set_cursor(.Hand)
		}
	}
}

draw_textbox :: proc(bounds: fx.Rect, font_size: f32) {
	@static scroll_x: f32
	@static blink_time: f32
	@static click_timer: f32
	@static click_count: int
	@static last_click_pos: fx.Vec2

	text_bounds := bounds

	edit.update_time(&textbox)

	old_text := strings.clone(string(textbox.builder.buf[:]), context.temp_allocator)
	old_caret_pos := textbox.selection[0]

	if search.focused {
		if fx.key_is_pressed(.Backspace) && textbox.selection[0] == 0 {
			search.filter = ""
			search.filter_type = .None
			update_search()
		}

		edit.input_runes(&textbox, fx.text_input())

		shift := fx.key_is_down(.Shift) || fx.key_is_down(.Left_Shift) || fx.key_is_down(.Right_Shift)
		ctrl := fx.key_is_down(.Ctrl) || fx.key_is_down(.Left_Ctrl) || fx.key_is_down(.Right_Ctrl)

		if ctrl {
			if shift {
				if fx.key_is_pressed_repeat(.Left)  do edit.perform_command(&textbox, .Select_Word_Left)
				if fx.key_is_pressed_repeat(.Right) do edit.perform_command(&textbox, .Select_Word_Right)
			} else {
				if fx.key_is_pressed_repeat(.Left)  do edit.perform_command(&textbox, .Word_Left)
				if fx.key_is_pressed_repeat(.Right) do edit.perform_command(&textbox, .Word_Right)
			}
			if fx.key_is_pressed_repeat(.Backspace) do edit.perform_command(&textbox, .Delete_Word_Left)
			if fx.key_is_pressed_repeat(.Delete)    do edit.perform_command(&textbox, .Delete_Word_Right)
			if fx.key_is_pressed(.C) do edit.perform_command(&textbox, .Copy)
			if fx.key_is_pressed(.X) do edit.perform_command(&textbox, .Cut)
			if fx.key_is_pressed(.V) do edit.perform_command(&textbox, .Paste)
			if fx.key_is_pressed(.A) do edit.perform_command(&textbox, .Select_All)
			if fx.key_is_pressed(.Z) do edit.perform_command(&textbox, .Undo)
			if fx.key_is_pressed(.Y) do edit.perform_command(&textbox, .Redo)
		} else {
			if shift {
				if fx.key_is_pressed_repeat(.Left)  do edit.perform_command(&textbox, .Select_Left)
				if fx.key_is_pressed_repeat(.Right) do edit.perform_command(&textbox, .Select_Right)
				if fx.key_is_pressed_repeat(.Up)    do edit.perform_command(&textbox, .Select_Start)
				if fx.key_is_pressed_repeat(.Down)  do edit.perform_command(&textbox, .Select_End)
				if fx.key_is_pressed_repeat(.Home)  do edit.perform_command(&textbox, .Select_Line_Start)
				if fx.key_is_pressed_repeat(.End)   do edit.perform_command(&textbox, .Select_Line_End)
			} else {
				if fx.key_is_pressed_repeat(.Left)  do edit.perform_command(&textbox, .Left)
				if fx.key_is_pressed_repeat(.Right) do edit.perform_command(&textbox, .Right)
				if fx.key_is_pressed_repeat(.Up)    do edit.perform_command(&textbox, .Start)
				if fx.key_is_pressed_repeat(.Down)  do edit.perform_command(&textbox, .End)
				if fx.key_is_pressed_repeat(.Home)  do edit.perform_command(&textbox, .Line_Start)
				if fx.key_is_pressed_repeat(.End)   do edit.perform_command(&textbox, .Line_End)
			}
			if fx.key_is_pressed_repeat(.Backspace) do edit.perform_command(&textbox, .Backspace)
			if fx.key_is_pressed_repeat(.Delete)    do edit.perform_command(&textbox, .Delete)
		}
	}

	text := string(textbox.builder.buf[:])

	if text != old_text {
		update_search()
	}

	if click_timer > 0 {
		click_timer -= fx.frame_time()
		if click_timer < 0 do click_count = 0
	}

	if search.focused && fx.key_is_down(.Mouse_Left) {
		rel_x := fx.mouse_pos().x - text_bounds.pos.x + scroll_x
		best_index := 0
		min_diff := f32(1e9)

		diff := abs(fx.measure_text("", font_size).x - rel_x)
		if diff < min_diff {
			min_diff = diff
			best_index = 0
		}

		current_idx := 0
		for r in text {
			current_idx += utf8.rune_size(r)
			diff = abs(fx.measure_text(text[:current_idx], font_size).x - rel_x)
			if diff < min_diff {
				min_diff = diff
				best_index = current_idx
			}
		}

		if fx.key_is_pressed(.Mouse_Left) {
			mouse_pos := fx.mouse_pos()
			if click_timer > 0 && abs(mouse_pos.x - last_click_pos.x) <= 1.0 && abs(mouse_pos.y - last_click_pos.y) <= 1.0 {
				click_count += 1
			} else {
				click_count = 1
			}
			click_timer = 0.3
			last_click_pos = mouse_pos

			if click_count >= 3 {
				textbox.selection[1] = 0
				textbox.selection[0] = len(textbox.builder.buf)
			} else if click_count == 2 {
				start_index := best_index
				end_index := best_index

				for start_index > 0 && text[start_index - 1] != ' ' {
					start_index -= 1
				}
				for end_index < len(text) && text[end_index] != ' ' {
					end_index += 1
				}

				textbox.selection[1] = start_index
				textbox.selection[0] = end_index
			} else {
				textbox.selection[0] = best_index
				textbox.selection[1] = best_index
			}
		} else {
			if click_count <= 1 {
				textbox.selection[0] = best_index
			}
		}
	}

	caret_pos := textbox.selection[0]
	caret_str := string(textbox.builder.buf[:caret_pos])
	caret_left := fx.measure_text(caret_str, font_size).x

	if caret_left - scroll_x < 0 {
		scroll_x = max(caret_left - 10, 0)
	} else if caret_left - scroll_x > text_bounds.size.x {
		scroll_x = caret_left - text_bounds.size.x + 10
	}

	fx.set_scissor(text_bounds)

	lo, hi := edit.sorted_selection(&textbox)

	if lo != hi {
		pre_str := string(textbox.builder.buf[:lo])
		sel_str := string(textbox.builder.buf[lo:hi])
		pre_x := fx.measure_text(pre_str, font_size).x
		sel_w := fx.measure_text(sel_str, font_size).x

		sel_target_x_w := fx.Vec2{text_bounds.pos.x + pre_x - scroll_x, sel_w}
		sel_anim_x_w := sel_target_x_w

		sel_rect := fx.Rect{
			pos = {sel_anim_x_w.x, text_bounds.pos.y + (text_bounds.size.y - font_size) * 0.5},
			size = {sel_anim_x_w.y, font_size},
		}

		fx.draw_rect(fx.rect_expand(sel_rect, 1), COLOR_ACCENT, 2)
	}

	if caret_pos != old_caret_pos {
		blink_time = 0
	}

	caret_x := text_bounds.pos.x + caret_left - scroll_x
	caret_y := text_bounds.pos.y + (text_bounds.size.y - font_size) * 0.5
	smear_x := animate(get_id("smear"), caret_x, 0.16)

	if search.focused && !fx.key_is_down(.Mouse_Left) {
		smear_w := abs(smear_x - caret_x)
		fx.draw_rect({{caret_x < smear_x ? caret_x : smear_x, caret_y}, {smear_w, font_size}}, COLOR_ACCENT, 4)
	}

	if len(text) > 0 {
		draw_bounds := text_bounds
		draw_bounds.pos.x -= scroll_x
		draw_bounds.size.x += scroll_x
		fx.draw_text_rect(text, draw_bounds, font_size, COLOR_TEXT, false)
	}

	if search.focused {
		blink_time += fx.frame_time()
		if blink_time >= 1.0 {
			blink_time -= 1.0
		}

		if blink_time < 0.5 {
			caret_rect := fx.Rect{
				pos  = {caret_x, caret_y},
				size = {2, font_size},
			}
			fx.draw_rect(caret_rect, COLOR_TEXT)
		}
	}

	fx.reset_scissor()
}