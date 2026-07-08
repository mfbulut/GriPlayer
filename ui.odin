package main

import "core:math"
import "core:math/ease"
import "fx"

BACKGROUND_COLOR := fx.Color{ 10,  15,  22, 255}
PRIMARY_COLOR    := fx.Color{ 21,  26,  34, 255}
PRIMARY_BRIGHT   := fx.Color{ 43,  48,  55, 255}
PRIMARY_DARK     := fx.Color{ 16,  21,  29, 255}
HOVER_COLOR      := fx.Color{ 28,  33,  41, 255}
ACCENT_COLOR     := fx.Color{ 10,  45,  72, 255}
ACCENT_BRIGHT    := fx.Color{ 38,  97, 162, 255}
ACCENT_DARK      := fx.Color{ 0,   38,  69, 255}
TEXT_PRIMARY     := fx.Color{245, 245, 245, 255}
TEXT_SECONDARY   := fx.Color{165, 165, 165, 255}

Icon :: enum{
	Shuffle,
	Previous,
	Pause,
	Play,
	Next,
	Heart,
	Volume,
	Mute,
	Note,
	Search,
	Cross,
	Add_Last,
	Add_Next,
	Album,
	Artist,
	Queue
}

UI_ID :: enum {
	None,
	Shuffle,
	Previous,
	Play_Pause,
	Next,
	Heart,
	Progress,
	Volume,
	Search,
	Context_Menu = 100,
	Playlist = 10000,
	Lyric_Hover = 20000,
	Lyric_Active = 30000,
	Queue_Tab = 40000,
	Lyrics_Tab = 40001,
	Queue_Item = 50000,
}

icons: [Icon]fx.Texture

GROW :: -1.0
Layout_Direction :: enum { Col, Row }

Scroll_State :: struct {
	current: f32,
	target: f32,
	content_size: f32,
}

Layout_Container :: struct {
	bounds: fx.Rect,
	elems: []f32,
	index: int,
	dir: Layout_Direction,
	padding: f32,
	gap: f32,

	grow_size: f32,
	current_pos: f32,

	scroll_state: ^Scroll_State,
}

font: fx.Font
layout_stack: [dynamic]Layout_Container
animation_state: map[int]f32

@(deferred_out=layout_end)
layout_start :: proc(bounds: fx.Rect, scroll: ^Scroll_State = nil, padding: f32 = 0, gap: f32 = 0, dir: Layout_Direction = .Col) -> bool {
	if scroll != nil {
		dt := fx.frame_time()
		mouse_scroll := fx.mouse_scroll()
		container_size := dir == .Row ? bounds.w : bounds.h
		max_scroll := max(scroll.content_size + padding * 2 - container_size, 0)

		if fx.point_in_rect(fx.mouse_pos(), bounds) && mouse_scroll.y != 0 {
			scroll.target = max(scroll.target - mouse_scroll.y * 60, 0)
		}

		scroll.target = min(scroll.target, max_scroll)
		scroll.current = math.lerp(scroll.current, scroll.target, ease.cubic_out(4 * dt))

		fx.set_scissor(bounds)
		scroll.content_size = 0
	}

	scroll_curr := scroll != nil ? scroll.current : 0
	@(static) grow_elems := [1]f32{GROW}

	origin := dir == .Row ? bounds.x : bounds.y
	span   := dir == .Row ? bounds.w : bounds.h

	append(&layout_stack, Layout_Container{
		bounds = bounds,
		elems = grow_elems[:],
		dir = dir,
		grow_size = max(0.0, span - padding * 2),
		current_pos = origin - scroll_curr + padding,
		padding = padding,
		gap = gap,
		scroll_state = scroll,
	})

	return true
}

@(deferred_out=layout_end)
layout :: proc(elems: []f32, dir: Layout_Direction, padding: f32 = 0, gap: f32 = 0) -> bool {
	bounds := layout_next()

	inner_w := max(0.0, bounds.w - padding * 2)
	inner_h := max(0.0, bounds.h - padding * 2)

	total_fixed := f32(0)
	num_grow := f32(0)
	for e in elems {
		if e == GROW {
			num_grow += 1
		} else {
			total_fixed += e
		}
	}

	total_gap := gap * f32(max(0, len(elems) - 1))
	grow_size := f32(0)
	if num_grow > 0 {
		inner_size := dir == .Row ? inner_w : inner_h
		grow_size = max(0.0, (inner_size - total_fixed - total_gap) / num_grow)
	}

	append(&layout_stack, Layout_Container{
		bounds = bounds,
		elems = elems,
		dir = dir,
		padding = padding,
		gap = gap,
		grow_size = grow_size,
		current_pos = (dir == .Row ? bounds.x : bounds.y) + padding,
		scroll_state = nil,
	})

	return true
}

layout_end :: proc(b: bool) {
	c := pop(&layout_stack)
	if c.scroll_state != nil {
		fx.reset_scissor()
	}
}

layout_next :: proc(set_size := f32(0)) -> fx.Rect {
	c := &layout_stack[len(layout_stack) - 1]
	size := set_size
	if c.scroll_state == nil {
		e := c.elems[c.index]
		size = e == GROW ? c.grow_size : e
	}

	defer c.index += 1
	defer c.current_pos += size + c.gap

	scroll_curr := c.scroll_state != nil ? c.scroll_state.current : 0
	if c.scroll_state != nil {
		origin := c.dir == .Row ? c.bounds.x : c.bounds.y
		c.scroll_state.content_size = max(c.scroll_state.content_size, (c.current_pos + size) - (origin + c.padding - scroll_curr))
	}

	if c.dir == .Row {
		return fx.Rect{
			x = c.current_pos,
			y = c.bounds.y + c.padding,
			w = size,
			h = max(0.0, c.bounds.h - c.padding * 2),
		}
	} else {
		return fx.Rect{
			x = c.bounds.x + c.padding,
			y = c.current_pos,
			w = max(0.0, c.bounds.w - c.padding * 2),
			h = size,
		}
	}
}

animate :: proc(id: int, active: bool, speed: f32 = 12.0) -> f32 {
	dt := fx.frame_time()
	t := animation_state[id]

	if active {
		t = clamp(t + speed * dt, 0, 1)
	} else {
		t = clamp(t - speed * dt, 0, 1)
	}

	if t > 0 {
		animation_state[id] = t
	} else {
		delete_key(&animation_state, id)
	}

	return t
}

mouse_hover :: proc(rect: fx.Rect, is_overlay: bool = false) -> bool {
	if !is_overlay && (context_menu.selection != nil || drag_id != 0) {
		return false
	}
	return fx.point_in_rect(fx.mouse_pos(), rect)
}
