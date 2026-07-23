package main

import "core:container/bit_array"
import "core:hash/xxhash"
import "core:slice"
import "core:strings"
import "core:unicode"

import "fx"
import "fx/textbox"

Search_Match :: struct {
	music: ^Music,
	score: int,
}

search: struct {
	results:     [dynamic]^Music,
	last_query:  string,
	initialized: bool,
	active:      bool,
	filter_artist: string,
	filter_album:  string,
}

search_open :: proc(artist := "", album := "") {
	search.active = true
	search.initialized = false
	search.filter_artist = artist
	search.filter_album = album
	textbox.set_text("")
	textbox.set_visible(true)
	textbox.focus()
	if fx.window_size().x < 800 do compact_tab = .Library
}

search_close :: proc() {
	textbox.set_text("")
	textbox.blur()
	search.active = false
	search.initialized = false
	search.filter_artist = ""
	search.filter_album = ""
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
			total_windows := len(runes) - 4
			for index in 0 ..< total_windows {
				bytes := slice.reinterpret([]byte, runes[index:index + 5])
				if bit_array.unsafe_get(&song.lyrics_filter, uint(xxhash.XXH32(bytes) & 32767)) {
					match_count += 1
				}
			}
			if match_count > 0 do score += match_count * 5000 / total_windows
		}
	}
	return score
}

update_search :: proc() {
	if !search.active && !textbox.focused() do return
	if textbox.focused() {
		search.active = true
	}
	if textbox.pressed(.Escape) {
		textbox.blur()
		return
	}
	if textbox.pressed(.Backspace_On_Empty) {
		search.filter_artist = ""
		search.filter_album = ""
		search.initialized = false
	}
	query_text := textbox.text()
	if textbox.pressed(.Enter) && len(search.results) > 0 {
		player_start_playlist(search.results[:], 0)
		textbox.blur()
	}
	if query_text == search.last_query && search.initialized do return
	search.initialized = true
	clear(&search.results)
	delete(search.last_query)
	search.last_query = strings.clone(query_text)
	query := strings.to_lower(strings.trim_space(query_text), context.temp_allocator)
	if query == "" {
		for playlist in playlists[LIBRARY_PLAYLIST_START:] {
			for song in playlist.songs {
				if search.filter_artist != "" && song.artist != search.filter_artist do continue
				if search.filter_album != "" && song.album != search.filter_album do continue
				append(&search.results, song)
			}
		}
		slice.sort_by(search.results[:], proc(a, b: ^Music) -> bool {
			if search.filter_album != "" && a.track != b.track do return a.track < b.track
			return strings.compare(a.title, b.title) == -1
		})
		return
	}

	matches: [dynamic]Search_Match
	defer delete(matches)
	words := strings.split(query, " ", context.temp_allocator)
	for playlist in playlists[LIBRARY_PLAYLIST_START:] {
		for song in playlist.songs {
			if search.filter_artist != "" && song.artist != search.filter_artist do continue
			if search.filter_album != "" && song.album != search.filter_album do continue
			if score := search_score(song, query, words); score > 0 {
				append(&matches, Search_Match{song, score})
			}
		}
	}
	slice.sort_by(matches[:], proc(a, b: Search_Match) -> bool {return a.score > b.score})
	for match in matches do append(&search.results, match.music)
	search.active = true
}

draw_search_box :: proc(bounds: fx.Rect) {
	if textbox.focused() do search.active = true
	query := textbox.text()
	show_close := len(query) > 0 || search.active
	filter := search.filter_artist != "" ? search.filter_artist : search.filter_album
	badge_width := f32(0)
	if filter != "" do badge_width = min(fx.measure_text(filter, 10).x + 31, bounds.w * .48)
	hovered := queue_drag.song == nil && (mouse_visible(bounds) || textbox.hovered())
	target := search.active || textbox.focused() ? COLOR_HOVER : hovered ? COLOR_HOVER : COLOR_SURFACE
	background := animate(id("search-background"), target, HOVER_DURATION, .Sine_In_Out)
	if textbox.focused() {
		fx.draw_rect(bounds, COLOR_ACCENT_BRIGHT, 8)
		fx.draw_rect(fx.rect_shrink(bounds, 1, 1), background, 7)
	} else {
		fx.draw_rect(bounds, background, 8)
	}

	close_bounds := fx.Rect{bounds.x + bounds.w - 30, bounds.y + 9, 24, 24}
	close_hit := Interaction{}
	if show_close do close_hit = interact(id("close-search"), close_bounds)
	if fx.key_is_pressed(.Mouse_Left) {
		if hovered && !close_hit.hovered {
			textbox.focus()
			search.active = true
		} else if !hovered {
			textbox.blur()
		}
	}

	if layout(bounds, .Row, { px(18), px(badge_width > 0 ? badge_width + 16 : 8), fr(), px(show_close ? 22 : 0)}, pad = pad_all(10)) {
		draw_icon(.Search, next(), COLOR_MUTED)
		badge_slot := next()
		if badge_width > 0 {
			badge := fx.Rect{badge_slot.x + 8, badge_slot.y - .5, badge_width, 23}
			fx.draw_rect(badge, fx.color_opacity(COLOR_ACCENT, .30), 6)
			filter_icon: Icon = search.filter_artist != "" ? .Artist : .Album
			draw_icon(filter_icon, {badge.x + 4, badge.y, 19, badge.h}, COLOR_TEXT, 2)
			fx.draw_text_faded(filter, {badge.x + 26, badge.y, badge.w - 31, badge.h}, 10, COLOR_TEXT)
		}
		text_area := next()
		textbox.set_colors(COLOR_TEXT, background)
		textbox.set_bounds(text_area.x, text_area.y, text_area.w, text_area.h + 6)
		close_slot := next()
		if show_close {
			icon_bounds := fx.Rect{close_slot.x + 8, close_slot.y, 14, close_slot.h}
			draw_icon(.Cross, icon_bounds, close_hit.hovered ? COLOR_TEXT : COLOR_MUTED)
			if close_hit.clicked do search_close()
			if close_hit.hovered do fx.set_cursor(.Hand)
		}
	}
}
