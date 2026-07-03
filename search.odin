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
	box:            edit.State,
	builder:        strings.Builder,
	results:        [dynamic]^Music,
	initialized:    bool,
	focused:        bool,
	active:         bool,
	last_query:     string,
	filter_artist:  string,
	filter_album:   string,
	blink_timer:    f32,
	scroll:         f32,
}

search_init :: proc() {
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
}

search_open :: proc(artist := "", album := "") {
	search.focused = true
	search.active = true
	strings.builder_reset(&search.builder)
	search.filter_artist = artist
	search.filter_album = album
	search.initialized = false
}

search_close :: proc() {
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
		cmd: edit.Command
		switch {
		case shift && ctrl: cmd = .Select_Word_Left
		case shift:         cmd = .Select_Left
		case ctrl:          cmd = .Word_Left
		case:               cmd = .Left
		}
		edit.perform_command(&search.box, cmd)
	}
	if fx.key_is_pressed_repeat(.Right) {
		cmd: edit.Command
		switch {
		case shift && ctrl: cmd = .Select_Word_Right
		case shift:         cmd = .Select_Right
		case ctrl:          cmd = .Word_Right
		case:               cmd = .Right
		}
		edit.perform_command(&search.box, cmd)
	}

	if fx.key_is_pressed(.Delete) do edit.perform_command(&search.box, ctrl ? .Delete_Word_Right : .Delete)
	if fx.key_is_pressed(.Home)   do edit.perform_command(&search.box, shift ? .Select_Line_Start : .Line_Start)
	if fx.key_is_pressed(.End)    do edit.perform_command(&search.box, shift ? .Select_Line_End : .Line_End)

	if ctrl {
		if fx.key_is_pressed(.Z) do edit.perform_command(&search.box, shift ? .Redo : .Undo)
		if fx.key_is_pressed(.A) do edit.perform_command(&search.box, .Select_All)
		if fx.key_is_pressed(.C) do edit.copy(&search.box)
		if fx.key_is_pressed(.X) do edit.cut(&search.box)
		if fx.key_is_pressed(.V) do edit.paste(&search.box)
	}

	if fx.key_is_pressed(.Esc) do search.focused = false
	if fx.key_is_pressed(.Enter) && len(search.results) > 0 {
		player_start_playlist(search.results[:], 0)
		search.focused = false
	}

	if search.box.selection != prev_sel || len(runes) > 0 {
		search.blink_timer = 0
	}
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
	query := strings.to_string(search.builder)
	filter := search.filter_artist != "" ? search.filter_artist : search.filter_album

	pad := min(f32(30), rect.w * 0.1)
	bar := fx.Rect{rect.x + pad, rect.y + (rect.h - 36) * 0.5, max(rect.w - pad * 2, 0), 36}

	hovered := mouse_hover(bar)
	was_focused := search.focused
	was_active := search.active

	if fx.mouse_is_pressed(.Left) {
		if hovered {
			search.active = true
			search.focused = true
		} else {
			search.focused = false
		}
	}

	anim_t := animate(int(UI_ID.Search), search.focused || hovered)
	fx.rect(bar, fx.color_lerp(PRIMARY_COLOR, HOVER_COLOR, anim_t), 18)
	fx.sprite(icons[.Search], {bar.x + 14, bar.y + 10, 16, 16}, TEXT_SECONDARY)

	text_start := bar.x + f32(38)
	if filter != "" {
		badge_w := fx.text_size(font, filter, 12).x + 16
		badge := fx.Rect{text_start, bar.y + 8, badge_w, 20}
		fx.rect(badge, ACCENT_BRIGHT, 4)
		fx.text(font, filter, badge, 12, TEXT_PRIMARY, true, true)
		text_start += badge_w + 8
	}

	text_area := fx.Rect{text_start, bar.y, bar.x + bar.w - text_start, bar.h}
	visible_w := max(text_area.w - 33, 0)

	update_search_scroll(query, visible_w)
	handle_search_drag(query, {text_area.x, text_area.y, visible_w, text_area.h})

	fx.set_scissor({text_area.x, text_area.y, visible_w, text_area.h})
	draw_search_cursor(query, text_area)

	scrolled := fx.Rect{text_area.x - search.scroll, text_area.y, text_area.w + search.scroll, text_area.h}
	if len(query) == 0 && !search.focused && !was_focused {
		fx.text(font, "Search...", scrolled, 14, TEXT_SECONDARY, false, true)
	} else {
		fx.text(font, query, scrolled, 14, TEXT_PRIMARY, false, true)
	}
	fx.reset_scissor()

	if len(query) > 0 || search.active {
		icon_size := f32(12)
		icon_pos := fx.Vec2{text_area.x + text_area.w - 26, bar.y + (bar.h - icon_size) * 0.5}
		hit := fx.Rect{icon_pos.x - 4, icon_pos.y - 4, icon_size + 8, icon_size + 8}
		close_hover := mouse_hover(hit, true)

		if close_hover {
			fx.set_cursor(.Hand)
			if fx.mouse_is_pressed(.Left) && was_active == search.active {
				search_close()
			}
		}

		fx.sprite(icons[.Cross], {icon_pos.x, icon_pos.y, icon_size, icon_size}, close_hover ? TEXT_PRIMARY : TEXT_SECONDARY)
	}
}

draw_search_cursor :: proc(query: string, area: fx.Rect) {
	lo, hi := edit.sorted_selection(&search.box)

	if lo != hi {
		before_w := fx.text_size(font, query[:lo], 14).x
		sel_w := fx.text_size(font, query[lo:hi], 14).x
		fx.rect({area.x + before_w - search.scroll - 2, area.y + 7, sel_w + 4, 20}, ACCENT_BRIGHT, 3)
		return
	}

	if !search.focused do return

	cursor_idx := clamp(search.box.selection[0], 0, len(query))
	cursor_x := area.x - search.scroll
	if cursor_idx > 0 {
		cursor_x += fx.text_size(font, query[:cursor_idx], 14).x
	}

	search.blink_timer += fx.frame_time()
	if search.blink_timer < 0.5 {
		fx.rect({cursor_x, area.y + 10, 2, 15}, fx.WHITE, 2)
	} else if search.blink_timer > 1.0 {
		search.blink_timer = 0
	}
}

update_search_scroll :: proc(query: string, visible_w: f32) {
	if !search.focused {
		search.scroll = 0
		return
	}

	cursor_idx := clamp(search.box.selection[0], 0, len(query))
	cursor_x := cursor_idx > 0 ? fx.text_size(font, query[:cursor_idx], 14).x : 0

	if cursor_x - search.scroll > visible_w - 10 {
		search.scroll = cursor_x - visible_w + 10
	}
	if cursor_x - search.scroll < 10 {
		search.scroll = cursor_x - 10
	}
	search.scroll = max(search.scroll, 0)
}

handle_search_drag :: proc(query: string, area: fx.Rect) {
	hovered := mouse_hover(area)

	if !search.focused || !fx.mouse_is_down(.Left) {
		if drag_id == int(UI_ID.Search) do drag_id = 0
	}

	if drag_id != 0 && drag_id != int(UI_ID.Search) do return
	if drag_id != int(UI_ID.Search) {
		if !hovered || !fx.mouse_is_pressed(.Left) do return
		drag_id = int(UI_ID.Search)
	}

	mouse_x := fx.mouse_pos().x - area.x + search.scroll

	closest_idx := 0
	closest_dist := abs(mouse_x)
	for r, i in query {
		byte_end := i + utf8.rune_size(r)
		char_x := fx.text_size(font, query[:byte_end], 14).x
		if dist := abs(char_x - mouse_x); dist < closest_dist {
			closest_dist = dist
			closest_idx = byte_end
		}
	}

	if fx.mouse_is_pressed(.Left) {
		search.box.selection = {closest_idx, closest_idx}
	} else {
		search.box.selection[0] = closest_idx
	}
	search.blink_timer = 0
}