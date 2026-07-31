package main

import "core:math"
import "fx"

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
	Volume,
	Mute,
	Cross,
	Alpha_Ascending,
	Alpha_Descending,
	Number_Ascending,
	Number_Descending,
	Time_Ascending,
	Time_Descending,
	Date_Ascending,
	Date_Descending,
}

sort_icons := [2][Playlist_Sort]Icon{
	{
		.Title = .Alpha_Ascending, .Artist = .Alpha_Ascending, .Album = .Alpha_Ascending,
		.Track = .Number_Ascending, .Duration = .Time_Descending, .Playtime = .Time_Descending,
		.Last_Listened = .Date_Descending, .Liked_Time = .Date_Descending,
	},
	{
		.Title = .Alpha_Descending, .Artist = .Alpha_Descending, .Album = .Alpha_Descending,
		.Track = .Number_Descending, .Duration = .Time_Ascending, .Playtime = .Time_Ascending,
		.Last_Listened = .Date_Ascending, .Liked_Time = .Date_Ascending,
	}
}

icon_atlas: fx.Texture

Result :: enum u32 {
	ACTIVE,
	HOVER,
	SUBMIT,
	CHANGE,
	SECONDARY,
}

Result_Set :: bit_set[Result; u32]

UI_Color :: struct {
	base:  fx.Color,
	hover: fx.Color,
	focus: fx.Color,
}

COLOR_BACKGROUND    :: fx.Color{16, 18, 22, 255}
COLOR_SURFACE       :: fx.Color{24, 26, 32, 255}
COLOR_BORDER        :: fx.Color{60, 68, 80, 255}
COLOR_TEXT          :: fx.Color{240, 245, 255, 255}
COLOR_MUTED         :: fx.Color{150, 160, 175, 255}
COLOR_ACCENT        :: fx.Color{30, 100, 160, 255}

ACTIVE_COVER_BG      :: fx.Color{72, 80, 94, 255}
SLIDER_PREVIEW_COLOR :: fx.Color{100, 110, 120, 255}

LINK_COLOR           := UI_Color{COLOR_MUTED, COLOR_TEXT, COLOR_TEXT}

BUTTON_COLOR         := UI_Color{fx.Color{40, 44, 52, 255}, fx.Color{48, 52, 60, 255}, fx.Color{60, 66, 76, 255}}
ACTIVE_BUTTON_COLOR  := UI_Color{fx.Color{26, 88, 140, 255}, fx.Color{44, 105, 160, 255}, fx.Color{62, 123, 178, 255}}

ROW_COLOR            := UI_Color{fx.BLANK, fx.Color{36, 40, 48, 255}, fx.Color{48, 54, 64, 255}}
ACTIVE_ROW_COLOR     := UI_Color{fx.Color{25, 42, 60, 255}, fx.Color{26, 48, 70, 255}, fx.Color{26, 52, 77, 255}}

SCROLLBAR_COLOR      := UI_Color{fx.Color{48, 54, 64, 255}, fx.Color{58, 64, 74, 255}, fx.Color{68, 74, 84, 255}}
SLIDER_FILL_COLOR    := UI_Color{COLOR_ACCENT, fx.Color{50, 120, 180, 255}, fx.Color{70, 140, 200, 255}}

ui_color :: proc(c: UI_Color, res: Result_Set) -> fx.Color {
	if .ACTIVE in res do return c.focus
	if .HOVER in res do return c.hover
	return c.base
}

mouse_over :: proc(rect: fx.Rect) -> bool {
	if context_menu.song != nil {
		if !fx.point_in_rect(context_menu.bounds, fx.mouse_pos()) {
			return false
		}
		if !fx.point_in_rect(context_menu.bounds, rect.pos) {
			return false
		}
	}

	return fx.point_in_rect(rect, fx.mouse_pos()) && fx.rect_visible({fx.mouse_pos(), {1, 1}})
}

update_control :: proc(id: Id, rect: fx.Rect) -> (res: Result_Set) {
	hover := mouse_over(rect)

	if ctx.focus_id == id {
		res += {.ACTIVE}
	}

	if hover && !fx.key_is_down(.Mouse_Left) && !fx.key_is_down(.Mouse_Right) {
		ctx.hover_id = id
	}

	if ctx.focus_id == id {
		if fx.key_is_released(.Mouse_Left) && hover {
			res += {.SUBMIT}
		}
		if fx.key_is_released(.Mouse_Right) && hover {
			res += {.SECONDARY}
		}
		if (fx.key_is_pressed(.Mouse_Left) || fx.key_is_pressed(.Mouse_Right)) && !hover {
			ctx.focus_id = 0
		}
		if !fx.key_is_down(.Mouse_Left) && !fx.key_is_down(.Mouse_Right) {
			ctx.focus_id = 0
		}
	}

	if ctx.hover_id == id {
		if hover do res += {.HOVER}
		if fx.key_is_pressed(.Mouse_Left) || fx.key_is_pressed(.Mouse_Right) {
			ctx.focus_id = id
			ctx.drag_start = fx.mouse_pos()
			res += {.ACTIVE}
		} else if !hover {
			ctx.hover_id = 0
		}
	}

	return
}

label :: proc(text: string, font_size: f32 = 14) {
	rect := layout_next()
	fx.draw_text_rect(text, rect, font_size, COLOR_TEXT, true)
}

link :: proc(id: Id, text: string, font_size: f32 = 14) -> (res: Result_Set) {
	text_width := fx.measure_text(text, font_size).x

	bounds := layout_next()
	bounds.size.x = min(text_width, bounds.size.x)

	res = update_control(id, bounds)

	color := ui_color(LINK_COLOR, res)
	fx.draw_text_faded(text, bounds, font_size, color)

	amount := animate(child_id(id, "amount"), .HOVER in res ? f32(1) : f32(0))
	if amount > 0.001 {
		underline_width := bounds.size.x * amount
		c := LINK_COLOR.hover
		c.a = u8(amount * 255.0)
		fx.draw_rect(
			{ bounds.pos + {(bounds.size.x - underline_width) * 0.5, bounds.size.y - 3},
			{ underline_width, 1}},
			c,
		)
	}

	if .HOVER in res do fx.set_cursor(.Hand)

	return
}

button :: proc(label: string, font_size: f32 = 14, active := false) -> (res: Result_Set) {
	id := get_id(label)
	r := layout_next()
	res = update_control(id, r)

	bg_style := active ? ACTIVE_BUTTON_COLOR : BUTTON_COLOR
	color := ui_color(bg_style, res)
	fx.draw_rect(r, color, 8)
	fx.draw_text_rect(label, r, font_size, COLOR_TEXT, true)

	if .HOVER in res do fx.set_cursor(.Hand)

	return
}

icon_button :: proc(id_str: string, icon: Icon, tint: fx.Color = COLOR_MUTED, radius: f32 = 8, bg: bool = true, offset: f32 = 0, scale: f32 = 0.7, active: bool = false) -> (res: Result_Set) {
	id := get_id(id_str)
	r := layout_next()
	r.pos.x += offset
	res = update_control(id, r)

	if bg {
		bg_style := active ? ACTIVE_BUTTON_COLOR : BUTTON_COLOR
		color := ui_color(bg_style, res)
		fx.draw_rect(r, color, radius)
	}

	tint_amount := (active || .HOVER in res || .ACTIVE in res) ? f32(1) : f32(0)
	final_tint := fx.color_lerp(tint, COLOR_TEXT, tint_amount)

	draw_icon(icon, r, min(r.size.x, r.size.y) * scale, final_tint)

	if .HOVER in res do fx.set_cursor(.Hand)

	return
}

slider :: proc(id: Id, value: ^f32, low, high: f32, fill: UI_Color = SLIDER_FILL_COLOR, preview: bool = false) -> (res: Result_Set, bounds: fx.Rect) {
	last := value^
	v := last
	base := layout_next()

	res = update_control(id, base)

	if .ACTIVE in res && fx.key_is_released(.Mouse_Left) {
		res += {.SUBMIT}
	}

	if ctx.focus_id == id && fx.key_is_down(.Mouse_Left) {
		v = low + f32(fx.mouse_pos().x - base.pos.x) * (high - low) / max(base.size.x, 1)
		res += {.CHANGE}
	}

	v = clamp(v, low, high); value^ = v

	ratio := (high > low) ? clamp((v - low) / (high - low), 0.0, 1.0) : f32(0)
	center_y := base.pos.y + base.size.y * 0.5
	track := fx.Rect{
		pos = {base.pos.x, center_y - 1.75},
		size = {base.size.x, 3.5},
	}

	track_color := ui_color(SCROLLBAR_COLOR, res)
	fx.draw_rect(track, track_color, 2.0)

	fill_track := track
	fill_track.size.x = track.size.x * ratio
	fill_color := ui_color(fill, res)
	fx.draw_rect(fill_track, fill_color, 2.0)

	if preview && .HOVER in res && !(.ACTIVE in res) {
		hover_ratio := clamp((fx.mouse_pos().x - base.pos.x) / max(base.size.x, 1), 0.0, 1.0)
		preview_track := track
		if hover_ratio > ratio {
			preview_track.pos.x += track.size.x * ratio
			preview_track.size.x = track.size.x * (hover_ratio - ratio)
			fx.draw_rect(preview_track, SLIDER_PREVIEW_COLOR, 2.0)
		}
	}

	thumb_size: f32 = (.HOVER in res || .ACTIVE in res) ? 4.5 : 3.5
	thumb_pos := fx.Vec2{base.pos.x + base.size.x * ratio, center_y}
	fx.draw_circle(thumb_pos, thumb_size, fill_color)

	bounds = base
	return
}

scrollbar :: proc(layout_id: Id, state: ^Scroll_State, body: fx.Rect, cs: fx.Vec2, id_string: string, i: int, marker: f32 = -1) {
	maxscroll := cs[i] - body.size[i]

	if maxscroll > 0 && body.size[i] > 0 {
		id := child_id(layout_id, id_string)
		id_thumb := child_id(id, "thumb")

		base := body
		base.pos[1-i] += base.size[1-i]
		base.size[1-i] = 4

		thumb := base
		thumb.size[i] = clamp(base.size[i] * body.size[i] / cs[i], 30, base.size[i])
		thumb.pos[i] += state.scroll[i] * (base.size[i] - thumb.size[i]) / maxscroll

		res := update_control(id, fx.rect_expand(base, 4))
		res_thumb := update_control(id_thumb, fx.rect_expand(thumb, 4))

		if fx.key_is_down(.Mouse_Left) {
			scroll_ratio := maxscroll / max(1.0, base.size[i] - thumb.size[i])

			if fx.key_is_pressed(.Mouse_Left) {
				if ctx.focus_id == id {
					target_pos := fx.mouse_pos()[i] - thumb.size[i] * 0.5
					state.scroll[i] = (target_pos - base.pos[i]) * scroll_ratio
					state.scroll_target[i] = state.scroll[i]
					ctx.focus_id = id_thumb
					ctx.drag_start = fx.mouse_pos()
				}
				if ctx.focus_id == id_thumb {
					state.drag_start_scroll = state.scroll
				}
			}

			if ctx.focus_id == id_thumb {
				delta := fx.mouse_pos() - ctx.drag_start
				state.scroll[i] = clamp(state.drag_start_scroll[i] + delta[i] * scroll_ratio, 0.0, maxscroll)
				state.scroll_target[i] = state.scroll[i]
			}
		}

		state.scroll_target[i] = clamp(state.scroll_target[i], 0.0, maxscroll)

		if ctx.focus_id == id_thumb {
			state.scroll[i] = state.scroll_target[i]
		} else {
			dt := fx.frame_time()
			t := 1.0 - math.exp(-20.0 * dt)
			state.scroll[i] += (state.scroll_target[i] - state.scroll[i]) * t
			if abs(state.scroll_target[i] - state.scroll[i]) < 0.001 {
				state.scroll[i] = state.scroll_target[i]
			}
		}

		state.scroll[i] = clamp(state.scroll[i], 0.0, maxscroll)

		thumb.pos[i] = base.pos[i] + state.scroll[i] * (base.size[i] - thumb.size[i]) / maxscroll
		thumb_color := ui_color(SCROLLBAR_COLOR, res + res_thumb)
		fx.draw_rect(thumb, thumb_color, 8)

		if marker >= 0 {
			marker_target := clamp(marker, 0, 1)
			marker_position := animate(child_id(id, "marker"), marker_target, 0.5)
			marker_height := min(f32(10), base.size[i])
			marker_rect := base
			marker_rect.pos[i] = base.pos[i] + (base.size[i] - marker_height) * marker_position
			marker_rect.size[i] = marker_height
			fx.draw_rect(marker_rect, COLOR_ACCENT, 8)
		}

		if mouse_over(body) || mouse_over(base) {
			state.scroll_target.x += fx.mouse_scroll().x * 60
			state.scroll_target.y += fx.mouse_scroll().y * -60
		}
	} else {
		state.scroll[i] = 0
		state.scroll_target[i] = 0
	}
}

menu_button :: proc(text: string, icon: Icon) -> (res: Result_Set) {
	id := get_id(text)
	bounds := layout_next()
	res = update_control(id, bounds)

	bg_color := ui_color(ROW_COLOR, res)
	fx.draw_rect(bounds, bg_color, 8)

	if .HOVER in res {
		fx.set_cursor(.Hand)
	}

	icon_rect := fx.Rect{
		{bounds.pos.x + 6, bounds.pos.y},
		{20, bounds.size.y}
	}

	icon_color := ui_color(LINK_COLOR, res)

	draw_icon(icon, icon_rect, 20, icon_color)

	text_bounds := fx.Rect{
		{bounds.pos.x + 32, bounds.pos.y + (bounds.size.y - 14) * 0.5},
		{max(bounds.size.x - 32, 0), 14}
	}

	fx.draw_text_faded(text, text_bounds, 13, COLOR_TEXT)

	return
}

draw_icon :: proc(icon: Icon, bounds: fx.Rect, size: f32 = 0, tint := COLOR_TEXT) {
	final_size := size > 0 ? size : max(min(bounds.size.x, bounds.size.y), 0)
	dest := fx.Rect{bounds.pos + (bounds.size - final_size) * 0.5, final_size}
	source := fx.Rect{{f32(int(icon) % 8), f32(int(icon) / 8)} * 32 + 1, 30}
	fx.draw_msdf_ex(icon_atlas, source, dest, 4, tint)
}