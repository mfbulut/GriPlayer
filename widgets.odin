package main

import "fx"

COLOR_BACKGROUND :: fx.Color{14, 17, 22, 255}
COLOR_SURFACE    :: fx.Color{21, 25, 31, 255}
COLOR_HOVER      :: fx.Color{31, 36, 44, 255}
COLOR_BORDER     :: fx.Color{48, 54, 64, 255}
COLOR_ACCENT_DARK :: fx.Color{52, 43, 78, 255}
COLOR_ACCENT     :: fx.Color{153, 112, 255, 255}
COLOR_ACCENT_BRIGHT :: fx.Color{188, 157, 255, 255}
COLOR_TEXT       :: fx.Color{246, 245, 241, 255}
COLOR_MUTED      :: fx.Color{158, 166, 178, 255}
HOVER_DURATION   :: f32(0.1)

Icon :: enum {
	Album,
	Artist,
	Heart,
	Heart_Empty,
	History,
	Next,
	Note,
	Pause,
	Play,
	Previous,
	Queue,
	Add_Last,
	Add_Next,
	Search,
	Shuffle,
	Sort_Alpha_Ascending,
	Sort_Alpha_Descending,
	Sort_Number_Ascending,
	Sort_Number_Descending,
	Sort_Time_Ascending,
	Sort_Time_Descending,
	Sort_Date_Ascending,
	Sort_Date_Descending,
	Volume,
	Mute,
	Cross,
}

icons: [Icon]fx.Texture
sort_icons: [2][Playlist_Sort]Icon

load_icons :: proc() {
	icons = {
		.Album = fx.texture_load(#load("assets/icons/album.png")),
		.Artist = fx.texture_load(#load("assets/icons/artist.png")),
		.Heart = fx.texture_load(#load("assets/icons/heart.png")),
		.Heart_Empty = fx.texture_load(#load("assets/icons/heart_empty.png")),
		.History = fx.texture_load(#load("assets/icons/history.png")),
		.Next = fx.texture_load(#load("assets/icons/next.png")),
		.Note = fx.texture_load(#load("assets/icons/note.png")),
		.Pause = fx.texture_load(#load("assets/icons/pause.png")),
		.Play = fx.texture_load(#load("assets/icons/play.png")),
		.Previous = fx.texture_load(#load("assets/icons/previous.png")),
		.Queue = fx.texture_load(#load("assets/icons/queue.png")),
		.Add_Last = fx.texture_load(#load("assets/icons/add_last.png")),
		.Add_Next = fx.texture_load(#load("assets/icons/add_next.png")),
		.Search = fx.texture_load(#load("assets/icons/search.png")),
		.Shuffle = fx.texture_load(#load("assets/icons/shuffle.png")),
		.Sort_Alpha_Ascending = fx.texture_load(#load("assets/icons/sort_alpha_ascending.png")),
		.Sort_Alpha_Descending = fx.texture_load(#load("assets/icons/sort_alpha_descending.png")),
		.Sort_Number_Ascending = fx.texture_load(#load("assets/icons/sort_number_ascending.png")),
		.Sort_Number_Descending = fx.texture_load(#load("assets/icons/sort_number_descending.png")),
		.Sort_Time_Ascending = fx.texture_load(#load("assets/icons/sort_time_ascending.png")),
		.Sort_Time_Descending = fx.texture_load(#load("assets/icons/sort_time_descending.png")),
		.Sort_Date_Ascending = fx.texture_load(#load("assets/icons/sort_date_ascending.png")),
		.Sort_Date_Descending = fx.texture_load(#load("assets/icons/sort_date_descending.png")),
		.Volume = fx.texture_load(#load("assets/icons/volume.png")),
		.Mute = fx.texture_load(#load("assets/icons/mute.png")),
		.Cross = fx.texture_load(#load("assets/icons/cross.png")),
	}
	sort_icons[0] = {
		.Title = .Sort_Alpha_Ascending, .Artist = .Sort_Alpha_Ascending, .Album = .Sort_Alpha_Ascending,
		.Track = .Sort_Number_Ascending, .Duration = .Sort_Time_Descending, .Playtime = .Sort_Time_Descending,
		.Last_Listened = .Sort_Date_Descending, .Liked_Time = .Sort_Date_Descending,
	}
	sort_icons[1] = {
		.Title = .Sort_Alpha_Descending, .Artist = .Sort_Alpha_Descending, .Album = .Sort_Alpha_Descending,
		.Track = .Sort_Number_Descending, .Duration = .Sort_Time_Ascending, .Playtime = .Sort_Time_Ascending,
		.Last_Listened = .Sort_Date_Ascending, .Liked_Time = .Sort_Date_Ascending,
	}
}

Style_State :: struct {
	bg:   fx.Color,
	text: fx.Color,
}

Style :: struct {
	disabled: Style_State,
	normal:   Style_State,
	hover:    Style_State,
	press:    Style_State,
}

LABEL_STYLE :: Style{
	normal = {text = COLOR_TEXT},
}

LINK_STYLE :: Style{
	disabled = {text = fx.Color{158, 166, 178, 70}},
	normal = {text = COLOR_MUTED},
	hover = {text = COLOR_TEXT},
	press = {text = COLOR_TEXT},
}

BUTTON_STYLE :: Style{
	disabled = {bg = fx.Color{31, 36, 44, 115}, text = fx.Color{158, 166, 178, 70}},
	normal = {bg = COLOR_HOVER, text = COLOR_MUTED},
	hover = {bg = COLOR_BORDER, text = COLOR_TEXT},
	press = {bg = fx.Color{62, 69, 80, 255}, text = COLOR_TEXT},
}

ACTIVE_BUTTON_STYLE :: Style{
	disabled = {bg = fx.Color{52, 43, 78, 115}, text = fx.Color{158, 166, 178, 70}},
	normal = {bg = COLOR_ACCENT_DARK, text = COLOR_TEXT},
	hover = {bg = fx.Color{62, 51, 92, 255}, text = COLOR_TEXT},
	press = {bg = fx.Color{72, 58, 108, 255}, text = COLOR_TEXT},
}

SLIDER_STYLE :: Style{
	disabled = {bg = fx.Color{48, 54, 64, 127}, text = fx.Color{158, 166, 178, 127}},
	normal = {bg = COLOR_BORDER, text = COLOR_ACCENT},
	hover = {bg = COLOR_BORDER, text = COLOR_ACCENT},
	press = {bg = COLOR_BORDER, text = COLOR_ACCENT},
}

MUTED_SLIDER_STYLE :: Style{
	disabled = {bg = fx.Color{48, 54, 64, 127}, text = fx.Color{158, 166, 178, 127}},
	normal = {bg = COLOR_BORDER, text = COLOR_MUTED},
	hover = {bg = COLOR_BORDER, text = COLOR_MUTED},
	press = {bg = COLOR_BORDER, text = COLOR_MUTED},
}

ICON_BUTTON_STYLE :: Style{
	disabled = {bg = fx.Color{}, text = fx.Color{158, 166, 178, 70}},
	normal = {bg = fx.Color{}, text = COLOR_MUTED},
	hover = {bg = COLOR_HOVER, text = COLOR_TEXT},
	press = {bg = COLOR_BORDER, text = COLOR_TEXT},
}

LIKE_BUTTON_STYLE :: Style{
	disabled = {bg = fx.Color{}, text = fx.Color{158, 166, 178, 70}},
	normal = {bg = fx.Color{}, text = COLOR_MUTED},
	hover = {bg = COLOR_HOVER, text = COLOR_MUTED},
	press = {bg = COLOR_BORDER, text = COLOR_MUTED},
}

ACTIVE_ICON_BUTTON_STYLE :: Style{
	disabled = {bg = fx.Color{}, text = fx.Color{158, 166, 178, 70}},
	normal = {bg = fx.Color{}, text = COLOR_TEXT},
	hover = {bg = fx.Color{72, 58, 108, 255}, text = COLOR_TEXT},
	press = {bg = fx.Color{86, 67, 130, 255}, text = COLOR_TEXT},
}

SCROLL_STYLE :: Style{
	disabled = {bg = fx.Color{}, text = fx.Color{}},
	normal = {bg = fx.Color{48, 54, 64, 50}, text = fx.Color{122, 130, 142, 110}},
	hover = {bg = fx.Color{48, 54, 64, 65}, text = fx.Color{158, 166, 178, 140}},
	press = {bg = fx.Color{48, 54, 64, 80}, text = fx.Color{158, 166, 178, 165}},
}

square_bounds :: proc(bounds: fx.Rect, inset := f32(0)) -> fx.Rect {
	size := max(min(bounds.w, bounds.h) - inset * 2, 0)
	return {
		x = bounds.x + (bounds.w - size) * .5,
		y = bounds.y + (bounds.h - size) * .5,
		w = size,
		h = size,
	}
}

draw_icon :: proc(icon: Icon, bounds: fx.Rect, tint := COLOR_MUTED, inset := f32(0)) {
	icon_bounds := square_bounds(bounds, inset)
	if icon_bounds.w > 0 {
		fx.draw_texture(icons[icon], icon_bounds, tint)
	}
}

style_state :: proc(style: Style, hit: Interaction, disabled := false, selected := false) -> Style_State {
	if disabled do return style.disabled
	if hit.held do return style.press
	if hit.hovered || selected do return style.hover
	return style.normal
}

text_style :: proc(color: fx.Color) -> Style {
	style := LABEL_STYLE
	style.normal.text = color
	return style
}

label :: proc(bounds: fx.Rect, text: string, font_size := f32(12), style: Style = LABEL_STYLE, center_x := false, center_y := true) {
	if !is_visible(bounds) do return
	fx.draw_text_faded(text, bounds, font_size, style.normal.text, center_x, center_y)
}

link :: proc(link_id: ID, bounds: fx.Rect, text: string, font_size := f32(13), style: Style = LINK_STYLE, disabled := false) -> bool {
	if text == "" || bounds.w <= 0 || bounds.h <= 0 do return false
	width := min(fx.measure_text(text, font_size).x, bounds.w)
	hit_bounds := fx.Rect{bounds.x, bounds.y, width, bounds.h}
	hit := interact(link_id, hit_bounds, disabled)
	state := style_state(style, hit, disabled)
	background := animate(id("background", link_id), state.bg, HOVER_DURATION, .Sine_In_Out)
	color := animate(id("text", link_id), state.text, HOVER_DURATION, .Sine_In_Out)
	amount := animate(id("hover", link_id), hit.hovered ? f32(1) : f32(0), HOVER_DURATION, .Sine_In_Out)
	if background.a > 0 do fx.draw_rect(hit_bounds, background, 4)
	fx.draw_text_faded(text, bounds, font_size, color, false, true)

	if amount > .001 {
		underline_width := hit_bounds.w * amount
		fx.draw_rect(
			{hit_bounds.x + (hit_bounds.w - underline_width) * .5, hit_bounds.y + hit_bounds.h - 3, underline_width, 1},
			fx.color_opacity(style.hover.text, amount),
		)
	}

	if hit.hovered do fx.set_cursor(.Hand)
	return hit.clicked
}

button :: proc( button_id: ID, bounds: fx.Rect, label: string, style: Style = BUTTON_STYLE, disabled := false,) -> bool {
	hit := interact(button_id, bounds, disabled)
	state := style_state(style, hit, disabled)
	background := animate(id("background", button_id), state.bg, HOVER_DURATION, .Sine_In_Out)
	text := animate(id("text", button_id), state.text, HOVER_DURATION, .Sine_In_Out)
	fx.draw_rect(bounds, background, 7)
	fx.draw_text_faded(label, bounds, 12, text, true, true)

	if hit.hovered && !disabled {
		fx.set_cursor(.Hand)
	}

	return hit.clicked
}

icon_button :: proc(button_id: ID, bounds: fx.Rect, icon: Icon, selected := false, disabled := false, style: Style = ICON_BUTTON_STYLE) -> bool {
	hit := interact(button_id, bounds, disabled)
	state := style_state(style, hit, disabled, selected)
	background := animate(id("background", button_id), state.bg, HOVER_DURATION, .Sine_In_Out)
	tint := animate(id("text", button_id), state.text, HOVER_DURATION, .Sine_In_Out)
	circle := square_bounds(bounds)

	fx.draw_circle(
		{circle.x + circle.w * .5, circle.y + circle.h * .5},
		circle.w * .5,
		background,
	)

	draw_icon(icon, bounds, tint, 9)
	if hit.hovered && !disabled {
		fx.set_cursor(.Hand)
	}

	return hit.clicked
}

slider :: proc(slider_id: ID, bounds: fx.Rect, value: ^f32, low, high: f32, style: Style = SLIDER_STYLE, disabled := false) -> Interaction {
	hit := interact(slider_id, bounds, disabled)
	if hit.held && high > low && bounds.w > 0 {
		previous := value^
		value^ = low + clamp((fx.mouse_pos().x - bounds.x) / bounds.w, 0, 1) * (high - low)
		hit.changed = value^ != previous
	}
	hit.committed = hit.released

	ratio := high > low ? clamp((value^ - low) / (high - low), 0, 1) : f32(0)
	state := style_state(style, hit, disabled)
	center_y := bounds.y + bounds.h * .5
	track := fx.Rect{
		x = bounds.x,
		y = center_y - 3.5/2,
		w = bounds.w,
		h = 3.5,
	}

	track_color := animate(id("background", slider_id), state.bg, HOVER_DURATION, .Sine_In_Out)
	fill_color := animate(id("text", slider_id), state.text, HOVER_DURATION, .Sine_In_Out)
	fx.draw_rect(track, track_color, 2)
	fx.draw_rect({track.x, track.y, track.w * ratio, track.h}, fill_color, 2)
	thumb_size := animate(id("size", slider_id), hit.hovered || hit.held ? f32(4) : f32(3), HOVER_DURATION, .Sine_In_Out)
	fx.draw_circle({bounds.x + bounds.w * ratio, center_y}, thumb_size, fill_color)

	if hit.hovered || hit.held {
		fx.set_cursor(.Hand)
	}

	return hit
}
