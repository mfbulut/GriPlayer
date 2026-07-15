package main

import "core:fmt"

import "fx"

COLOR_BACKGROUND    :: fx.Color{14, 17, 22, 255}
COLOR_SURFACE       :: fx.Color{21, 25, 31, 255}
COLOR_HOVER         :: fx.Color{31, 36, 44, 255}
COLOR_BORDER        :: fx.Color{48, 54, 64, 255}
COLOR_ACCENT_DARK   :: fx.Color{52, 43, 78, 255}
COLOR_ACCENT        :: fx.Color{153, 112, 255, 255}
COLOR_ACCENT_BRIGHT :: fx.Color{188, 157, 255, 255}
COLOR_TEXT          :: fx.Color{246, 245, 241, 255}
COLOR_MUTED         :: fx.Color{158, 166, 178, 255}

Icon :: enum {
	Album,
	Artist,
	Heart,
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
}

icons: [Icon]fx.Texture

library_scroll: Scroll_State
playlist_scroll: Scroll_State
search_scroll: Scroll_State
lyrics_scroll: Scroll_State

ui_animations: map[UI_ID]f32

ui_id :: proc(group, value: uint) -> UI_ID {
	x := u64(value) + u64(group) * 0x9e3779b97f4a7c15
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	return UI_ID(x ~ (x >> 31))
}

ui_animate :: proc(id: UI_ID, on: bool, speed := f32(30)) -> f32 {
	value := ui_animations[id]
	target := on ? f32(1) : f32(0)
	value += (target - value) * min(fx.frame_time() * speed, 1)
	ui_animations[id] = value
	return value
}

GROW :: -1.0

Layout_Axis :: enum {
	Horizontal,
	Vertical,
}

Scroll_State :: struct {
	current:      f32,
	target:       f32,
	content_size: f32,
}

Layout_Container :: struct {
	bounds:    fx.Rect,
	sizes:     []f32,
	index:     int,
	axis:      Layout_Axis,
	padding:   f32,
	gap:       f32,
	grow_size: f32,
	cursor:    f32,
	scroll:    ^Scroll_State,
	background: fx.Color,
}

layout_stack: [dynamic]Layout_Container

@(deferred_out=layout_end)
layout_begin :: proc(
	bounds: fx.Rect,
	sizes: []f32 = nil,
	axis := Layout_Axis.Vertical,
	padding := f32(0),
	gap := f32(0),
	scroll: ^Scroll_State = nil,
	background := fx.Color{},
	smooth_speed := f32(16),
) -> bool {
	if bounds.w <= 0 || bounds.h <= 0 do return false
	if scroll != nil {
		fx.draw_rect(bounds, background, 8)
		max_scroll := max(scroll.content_size - bounds.h, 0)
		if fx.point_in_rect(fx.mouse_pos(), bounds) && fx.mouse_scroll().y != 0 {
			scroll.target -= fx.mouse_scroll().y * 64
		}
		scroll.target = clamp(scroll.target, 0, max_scroll)
		scroll.current += (scroll.target - scroll.current) * min(fx.frame_time() * smooth_speed, 1)
		scroll.content_size = 0
	}

	fixed := f32(0)
	grow_count := 0
	for size in sizes {
		if size == GROW {
			grow_count += 1
		} else {
			fixed += size
		}
	}

	inner_size := axis == .Horizontal ? bounds.w : bounds.h
	inner_size = max(0, inner_size - padding * 2)
	free := max(0, inner_size - fixed - gap * f32(max(0, len(sizes) - 1)))
	grow_size := grow_count > 0 ? free / f32(grow_count) : 0

	append(&layout_stack, Layout_Container{
		bounds = bounds,
		sizes = sizes,
		axis = axis,
		padding = padding,
		gap = gap,
		grow_size = grow_size,
		cursor = (axis == .Horizontal ? bounds.x : bounds.y) + padding - (scroll != nil ? scroll.current : 0),
		scroll = scroll,
		background = background,
	})
	if scroll != nil do fx.set_scissor(bounds)
	return true
}

layout_end :: proc(started: bool) {
	if !started do return
	c := pop(&layout_stack)
	if c.scroll == nil do return
	max_scroll := max(c.scroll.content_size - c.bounds.h, 0)
	c.scroll.target = clamp(c.scroll.target, 0, max_scroll)
	c.scroll.current = clamp(c.scroll.current, 0, max_scroll)
	restore_parent_clip()
	if max_scroll <= 0 || c.bounds.h < 40 do return

	fade_height := min(32, c.bounds.h * .18)
	transparent := fx.color_opacity(c.background, 0)
	opaque := fx.color_opacity(c.background, .94)
	if c.scroll.current > 1 {
		fx.draw_rect(
			{c.bounds.x, c.bounds.y, c.bounds.w, fade_height},
			[4]fx.Color{opaque, opaque, transparent, transparent},
			8,
		)
	}
	if max_scroll - c.scroll.current > 1 {
		fx.draw_rect(
			{c.bounds.x, c.bounds.y + c.bounds.h - fade_height, c.bounds.w, fade_height},
			[4]fx.Color{transparent, transparent, opaque, opaque},
			8,
		)
	}

	scrollbar_slot := max(c.padding, 7)
	track := fx.Rect{
		x = c.bounds.x + c.bounds.w - scrollbar_slot + (scrollbar_slot - 3) * .5,
		y = c.bounds.y + 8,
		w = 3,
		h = c.bounds.h - 16,
	}
	ratio := clamp(c.bounds.h / c.scroll.content_size, 0, 1)
	thumb_height := max(track.h * ratio, 24)
	travel := track.h - thumb_height
	thumb_y := track.y + travel * clamp(c.scroll.current / max_scroll, 0, 1)
	fx.draw_rect(
		{track.x, thumb_y, track.w, thumb_height},
		fx.color_opacity(COLOR_BORDER, .48),
		3 * .5,
	)
}

layout_next :: proc(height: ..f32) -> fx.Rect {
	c := &layout_stack[len(layout_stack) - 1]
	if c.scroll != nil {
		if len(height) != 1 do fmt.panicf("layout_next requires a height inside a scroll container")
		return layout_take(c, max(0, height[0]))
	}
	if len(height) != 0 do fmt.panicf("layout_next height can only be used inside a scroll container")
	if c.index >= len(c.sizes) do fmt.panicf("layout has no remaining slots")

	size := c.sizes[c.index]
	if size == GROW do size = c.grow_size
	return layout_take(c, size)
}

layout_take :: proc(c: ^Layout_Container, size: f32) -> fx.Rect {
	position := c.cursor
	c.cursor += size + c.gap
	c.index += 1

	if c.axis == .Horizontal {
		return {
			x = position,
			y = c.bounds.y + c.padding,
			w = size,
			h = max(0, c.bounds.h - c.padding * 2),
		}
	}

	width := max(0, c.bounds.w - c.padding * 2)
	if c.scroll != nil {
		scrollbar_slot := max(c.padding, 7)
		width = max(0, c.bounds.w - c.padding - scrollbar_slot)
		content_end := position + c.scroll.current + size - c.bounds.y + c.padding
		c.scroll.content_size = max(c.scroll.content_size, content_end)
	}
	return {
		x = c.bounds.x + c.padding,
		y = position,
		w = width,
		h = size,
	}
}

restore_parent_clip :: proc() {
	for i := len(layout_stack) - 1; i >= 0; i -= 1 {
		if layout_stack[i].scroll != nil {
			fx.set_scissor(layout_stack[i].bounds)
			return
		}
	}
	fx.reset_scissor()
}

format_time :: proc(seconds: f32) -> string {
	value := max(seconds, 0)
	return fmt.tprintf("%d:%02d", int(value) / 60, int(value) % 60)
}

ui_hover :: proc(bounds: fx.Rect, overlay := false) -> bool {
	if !overlay && context_menu.song != nil do return false
	return fx.point_in_rect(fx.mouse_pos(), bounds)
}

draw_cover :: proc(cover: fx.Texture, bounds: fx.Rect, radius := f32(6)) {
	if cover.srv == nil {
		fx.draw_rect(bounds, COLOR_BORDER, radius)
		shrink := min(bounds.w, bounds.h) * .31
		fx.draw_texture(icons[.Note], fx.rect_shrink(bounds, shrink, shrink), COLOR_MUTED)
		return
	}

	size := fx.Vec2(cover.size)
	crop_size := min(size.x, size.y)
	source := fx.Rect{
		(size.x - crop_size) * .5,
		(size.y - crop_size) * .5,
		crop_size,
		crop_size,
	}
	fx.draw_texture_ex(cover, source, bounds, fx.WHITE, radius)
}


context_menu: struct {
	song: ^Music,
	bounds: fx.Rect,
}

open_context_menu :: proc(song: ^Music) {
	window_size := fx.window_size()
	position := fx.mouse_pos()
	width := f32(190)
	height := f32(8 + 28 * 5)
	position.x = clamp(position.x, 10, max(10, window_size.x - width - 10))
	position.y = clamp(position.y, 10, max(10, window_size.y - height - 10))
	context_menu = {
		song = song,
		bounds = {position.x, position.y, width, height},
	}
}

draw_context_menu :: proc() {
	song := context_menu.song
	if song == nil do return

	bounds := context_menu.bounds
	fx.draw_rect(fx.rect_expand(bounds, 1, 1), COLOR_BORDER, 9)
	fx.draw_rect(bounds, COLOR_SURFACE, 8)

	labels := [?]string{song.liked ? "Unlike" : "Like", "Play next", "Add to queue", "Show artist", "Show album"}
	menu_icons := [?]Icon{.Heart, .Add_Next, .Add_Last, .Artist, .Album}

	if layout_begin(
		bounds,
		{28, 28, 28, 28, 28},
		.Vertical,
		padding = 4,
		gap = 0,
	) {
		for label, index in labels {
			row := layout_next()
			disabled := (index == 3 && song.artist == "") || (index == 4 && song.album == "")
			hovered := !disabled && ui_hover(row, true)
			if hovered {
				fx.set_cursor(.Hand)
				fx.draw_rect(row, COLOR_HOVER, 6)
			}

			icon_size := f32(16)
			icon_bounds := fx.Rect{row.x + 9, row.y + (row.h - icon_size) * .5, icon_size, icon_size}
			tint := disabled ? fx.color_opacity(COLOR_MUTED, .28) : (hovered ? COLOR_TEXT : COLOR_MUTED)
			fx.draw_texture(icons[menu_icons[index]], icon_bounds, tint)
			fx.draw_text(
				label,
				fx.Rect{row.x + 36, row.y, row.w - 45, row.h},
				13,
				tint,
			)

			if hovered && fx.key_is_pressed(.Mouse_Left) {
				switch index {
				case 0: toggle_like(song)
				case 1: inject_at(&player.queue, 0, song)
				case 2: append(&player.queue, song)
				case 3: search_open(artist = song.artist)
				case 4: search_open(album = song.album)
				}
				context_menu = {}
				return
			}
		}
	}

	if (fx.key_is_pressed(.Mouse_Left) || fx.key_is_pressed(.Mouse_Right)) &&
	   !fx.point_in_rect(fx.mouse_pos(), bounds) {
		context_menu = {}
	}
}
