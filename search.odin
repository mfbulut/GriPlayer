package main

import "core:container/bit_array"
import "core:hash/xxhash"
import "core:slice"
import "core:strings"
import "core:unicode"

import "fx"

Search_Match :: struct {
	music: ^Music,
	score: int,
}

search: struct {
	results:       [dynamic]^Music,
	initialized:   bool,
	focused:       bool,
	active:        bool,
	last_query:    string,
	filter_artist: string,
	filter_album:  string,
}

search_open :: proc(artist := "", album := "") {
	search.focused = true
	search.active = true
	fx.text_box_set_text("")
	fx.text_box_focus()
	search.filter_artist = artist
	search.filter_album = album
	search.initialized = false
}

search_close :: proc() {
	fx.text_box_set_text("")
	fx.text_box_blur()
	search.initialized = false
	search.filter_artist = ""
	search.filter_album = ""
	search.focused = false
	search.active = false
}

handle_search_input :: proc() {
	if fx.text_box_backspace_on_empty() {
		search.filter_artist = ""
		search.filter_album = ""
		search.initialized = false
	}

	if fx.text_box_escape_pressed() {
		search.focused = false
		fx.text_box_blur()
		return
	}

	if fx.text_box_enter_pressed() && len(search.results) > 0 {
		player_start_playlist(search.results[:], 0)
		search.focused = false
		fx.text_box_blur()
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

	for &field in fields {
		field.words = strings.split(field.text, " ", context.temp_allocator)
		if strings.has_prefix(field.text, query) do score += 10000 * field.mult
		if strings.contains(field.text, query) do score += 1000 * field.mult
	}

	for query_word in query_words {
		if len(query_word) == 0 do continue

		allowed_distance := 0
		if len(query_word) >= 3 do allowed_distance = 1
		if len(query_word) >= 5 do allowed_distance = 2
		if len(query_word) >= 7 do allowed_distance = 3

		best_word_score := 0
		for field in fields {
			for word in field.words {
				if len(word) == 0 do continue
				word_score := 0
				if word == query_word do word_score += 100 * field.mult
				else if strings.has_prefix(word, query_word) do word_score += 50 * field.mult
				distance := strings.levenshtein_distance(query_word, word, context.temp_allocator)
				if distance <= allowed_distance {
					word_score += (allowed_distance - distance + 1) * 10 * field.mult
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

	if len(song.lyrics_filter.bits) > 0 {
		query_runes := make([dynamic]rune, 0, len(query), context.temp_allocator)
		for character in query {
			if unicode.is_letter(character) || unicode.is_digit(character) {
				append(&query_runes, character)
			}
		}

		if len(query_runes) >= 5 {
			match_count := 0
			total_windows := len(query_runes) - 4
			for index in 0 ..< total_windows {
				bytes := slice.reinterpret([]byte, query_runes[index:index + 5])
				hash := xxhash.XXH32(bytes)
				if bit_array.unsafe_get(&song.lyrics_filter, uint(hash & 32767)) {
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
	if !search.active && !search.focused do return
	if search.focused do handle_search_input()

	current_query := fx.text_box_text()
	if current_query == search.last_query && search.initialized do return
	search.initialized = true
	search_scroll = {}

	clear(&search.results)
	delete(search.last_query)
	search.last_query = strings.clone(current_query)
	query := strings.to_lower(current_query, context.temp_allocator)
	query_words := strings.split(query, " ", context.temp_allocator)

	matches: [dynamic]Search_Match
	defer delete(matches)
	for playlist in playlists[1:] {
		for song in playlist.songs {
			if search.filter_artist != "" && song.artist != search.filter_artist do continue
			if search.filter_album != "" && song.album != search.filter_album do continue

			if len(query) == 0 {
				append(&search.results, song)
				continue
			}
			if score := score_song(song, query, query_words[:]); score > 0 {
				append(&matches, Search_Match{song, score})
			}
		}
	}

	if len(query) == 0 {
		slice.sort_by(search.results[:], proc(a, b: ^Music) -> bool {
			if search.filter_album != "" && a.track != b.track do return a.track < b.track
			return strings.compare(a.title, b.title) == -1
		})
	} else {
		slice.sort_by(matches[:], proc(a, b: Search_Match) -> bool {return a.score > b.score})
		for match in matches do append(&search.results, match.music)
	}
}

draw_search_box :: proc(bounds: fx.Rect) {
	query := fx.text_box_text()
	filter := search.filter_artist != "" ? search.filter_artist : search.filter_album
	close_width := f32(len(query) > 0 || search.active ? 14 : 0)
	badge_width := f32(0)
	if filter != "" {
		badge_width = min(fx.measure_text(filter, 10).x + 31, bounds.w * .48)
	}

	slots := make([dynamic]f32, 0, 4, context.temp_allocator)
	append(&slots, f32(18))
	if badge_width > 0 do append(&slots, badge_width)
	append(&slots, GROW)
	if close_width > 0 do append(&slots, close_width)

	if fx.text_box_is_focused() {
		search.active = true
		search.focused = true
	}
	background := search.active ? COLOR_HOVER : COLOR_SURFACE
	fx.draw_rect(bounds, background, 8)
	if fx.text_box_is_focused() {
		fx.draw_rect({bounds.x + 5, bounds.y + bounds.h - 2, bounds.w - 10, 2}, COLOR_ACCENT_BRIGHT, 1)
	}

	close_hovered := false
	if close_width > 0 {
		close_hit := fx.Rect{bounds.x + bounds.w - 30, bounds.y + 9, 24, 24}
		close_hovered = ui_hover(close_hit)
	}

	hovered := ui_hover(bounds)
	if fx.key_is_pressed(.Mouse_Left) {
		if hovered && !close_hovered {
			search.active = true
			search.focused = true
			fx.text_box_focus()
		} else if !hovered {
			search.focused = false
			fx.text_box_blur()
		}
	}

	if layout_begin(bounds, slots[:], .Horizontal, padding = 10, gap = 8) {
		search_icon := layout_next()
		fx.draw_texture(
			icons[.Search],
			{search_icon.x, search_icon.y + (search_icon.h - 18) * .5 - 1, 18, 18},
			search.focused ? COLOR_ACCENT_BRIGHT : COLOR_MUTED,
		)

		if badge_width > 0 {
			badge := layout_next()
			badge.y += (badge.h - 23) * .5
			badge.h = 23
			fx.draw_rect(badge, fx.color_opacity(COLOR_ACCENT, .30), 6)
			filter_icon := search.filter_artist != "" ? Icon.Artist : Icon.Album
			fx.draw_texture(icons[filter_icon], {badge.x + 6, badge.y + 4, 15, 15}, COLOR_TEXT)
			fx.draw_text_faded(filter, {badge.x + 26, badge.y, badge.w - 31, badge.h}, 10, COLOR_TEXT)
		}

		text_area := layout_next()
		if ui_hover(text_area) do fx.set_cursor(.IBeam)
		fx.text_box_set_colors(COLOR_TEXT, background)
		fx.text_box_set_rect({text_area.x, text_area.y, text_area.w, text_area.h + 6})

		if close_width > 0 {
			close_slot := layout_next()
			icon_bounds := fx.Rect{close_slot.x, close_slot.y + (close_slot.h - 14) * .5, 14, 14}
			if close_hovered {
				fx.set_cursor(.Hand)
				if fx.key_is_pressed(.Mouse_Left) do search_close()
			}
			fx.draw_texture(icons[.Cross], icon_bounds, close_hovered ? COLOR_TEXT : COLOR_MUTED)
		}
	}
}
