package main

import "core:hash/xxhash"

import "fx"

ID :: distinct u64
ID_NONE :: ID(0)

Direction :: enum {
	Row,
	Col,
}

Size_Kind :: enum {
	Pixels,
	Fraction,
	Percent,
}

Size :: struct {
	kind:  Size_Kind,
	value: f32,
}

Padding :: struct {
	left, top, right, bottom: f32,
}

Interaction :: struct {
	hovered:      bool,
	entered:      bool,
	left:         bool,
	pressed:      bool,
	released:     bool,
	clicked:      bool,
	held:         bool,
	drag_started: bool,
	dragging:     bool,
	drag_total:   fx.Vec2,
	changed:      bool,
	committed:    bool,
}

Scroll_State :: struct {
	id:           ID,
	last_touched: u64,
	current:      f32,
	target:       f32,
	content_size: f32,
	viewport:     f32,
	thumb_grab:   f32,
	thumb_held:   bool,
}

Layout :: struct {
	bounds:         fx.Rect,
	inner:          fx.Rect,
	sizes:          []Size,
	direction:      Direction,
	gap:            f32,
	index:          int,
	item_count:     int,
	content_length: f32,
	fixed_length:   f32,
	fraction_total: f32,
	free_length:    f32,
	can_scroll:     bool,
	scroll_index:   int,
	scroll_style:   Style,
	scroll_marker:  f32,
	scroll_duration: f32,
}

Context :: struct {
	frame:          u64,
	overlay:        bool,

	hot:          ID,
	previous_hot: ID,
	active:       ID,
	dragging:     bool,
	drag_origin:  fx.Vec2,

	layouts: [dynamic]Layout,
	clips:   [dynamic]fx.Rect,
	scrolls: [dynamic]Scroll_State,

	animations: [dynamic]Animation,
}

ui_ctx: Context

px :: proc(value: f32) -> Size {
	return {kind = .Pixels, value = value}
}

fr :: proc(weight := f32(1)) -> Size {
	return {kind = .Fraction, value = max(weight, 0)}
}

percent :: proc(value: f32) -> Size {
	return {kind = .Percent, value = clamp(value, 0, 1)}
}

pad_all :: proc(value: f32) -> Padding {
	return {value, value, value, value}
}

pad_xy :: proc(x, y: f32) -> Padding {
	return {x, y, x, y}
}

id :: proc(value: string, child_id := ID_NONE) -> ID {
	hash := u64(xxhash.XXH64(transmute([]u8)value, xxhash.XXH64_hash(child_id)))
	if hash == 0 {
		hash = 1
	}
	return ID(hash)
}

scroll_to :: proc(layout_id: ID, offset: f32) {
	scroll_id := id("scroll", layout_id)
	for &state in ui_ctx.scrolls {
		if state.id == scroll_id {
			state.target = max(offset, 0)
			return
		}
	}
}

begin_frame :: proc() {
	assert(len(ui_ctx.layouts) == 0)
	assert(len(ui_ctx.clips) == 0)
	ui_ctx.frame += 1
	ui_ctx.previous_hot = ui_ctx.hot
	ui_ctx.hot = ID_NONE
	animation_update_all()
	fx.reset_scissor()
}

end_frame :: proc() {
	assert(len(ui_ctx.layouts) == 0)
	assert(len(ui_ctx.clips) == 0)

	if fx.key_is_released(.Mouse_Left) || !fx.key_is_down(.Mouse_Left) {
		ui_ctx.active = ID_NONE
		ui_ctx.dragging = false
	}
	if ui_ctx.frame % 300 == 0 {
		for index := len(ui_ctx.scrolls) - 1; index >= 0; index -= 1 {
			if ui_ctx.frame - ui_ctx.scrolls[index].last_touched <= 600 {
				continue
			}
			last := pop(&ui_ctx.scrolls)
			if index < len(ui_ctx.scrolls) {
				ui_ctx.scrolls[index] = last
			}
		}
	}
	fx.reset_scissor()
}

intersect_rects :: proc(a, b: fx.Rect) -> fx.Rect {
	x1 := max(a.x, b.x)
	y1 := max(a.y, b.y)
	x2 := min(a.x + a.w, b.x + b.w)
	y2 := min(a.y + a.h, b.y + b.h)
	return {x1, y1, max(0, x2 - x1), max(0, y2 - y1)}
}

current_clip :: proc() -> (fx.Rect, bool) {
	if len(ui_ctx.clips) == 0 {
		return {}, false
	}
	return ui_ctx.clips[len(ui_ctx.clips) - 1], true
}

push_clip :: proc(bounds: fx.Rect) {
	clip := bounds
	if parent, ok := current_clip(); ok {
		clip = intersect_rects(parent, bounds)
	}
	append(&ui_ctx.clips, clip)
	fx.set_scissor(clip)
}

pop_clip :: proc() {
	assert(len(ui_ctx.clips) > 0)
	pop(&ui_ctx.clips)
	if clip, ok := current_clip(); ok {
		fx.set_scissor(clip)
	} else {
		fx.reset_scissor()
	}
}

is_visible :: proc(bounds: fx.Rect) -> bool {
	if bounds.w <= 0 || bounds.h <= 0 {
		return false
	}
	if clip, ok := current_clip(); ok {
		return fx.rect_overlaps(bounds, clip)
	}
	return true
}

mouse_visible :: proc(bounds: fx.Rect) -> bool {
	mouse := fx.mouse_pos()
	if !fx.point_in_rect(mouse, bounds) {
		return false
	}
	if clip, ok := current_clip(); ok {
		return fx.point_in_rect(mouse, clip)
	}
	return true
}

interact :: proc(control_id: ID, bounds: fx.Rect, disabled := false, overlay := false) -> Interaction {
	result: Interaction
	if ui_ctx.overlay && !overlay do return result
	mouse := fx.mouse_pos()
	can_hover := !disabled && (ui_ctx.active == ID_NONE || ui_ctx.active == control_id)
	result.hovered = can_hover && mouse_visible(bounds)
	result.entered = result.hovered && ui_ctx.previous_hot != control_id
	result.left = !result.hovered && ui_ctx.previous_hot == control_id

	if result.hovered {
		ui_ctx.hot = control_id
	}

	if result.hovered && fx.key_is_pressed(.Mouse_Left) && ui_ctx.active == ID_NONE {
		ui_ctx.active = control_id
		ui_ctx.drag_origin = mouse
		ui_ctx.dragging = false
		result.pressed = true
	}

	if ui_ctx.active == control_id {
		result.held = fx.key_is_down(.Mouse_Left)
		result.released = fx.key_is_released(.Mouse_Left)
		result.clicked = result.released && result.hovered
		result.drag_total = mouse - ui_ctx.drag_origin

		if result.held && !ui_ctx.dragging &&
		   (abs(result.drag_total.x) >= 3 || abs(result.drag_total.y) >= 3) {
			ui_ctx.dragging = true
			result.drag_started = true
		}
		result.dragging = ui_ctx.dragging && result.held
	}

	return result
}

@(deferred_none=end_layout)
layout :: proc(
	bounds: fx.Rect,
	direction: Direction,
	sizes: []Size = nil,
	pad: Padding = {},
	gap := f32(0),
	can_scroll := false,
	layout_id := ID_NONE,
	scroll_style: Style = SCROLL_STYLE,
	scroll_speed := f32(0),
	scroll_marker := f32(-1),
	scroll_duration := f32(.16),
) -> bool {
	scroll_index := -1
	if can_scroll {
		scroll_id := id("scroll", layout_id)
		for index in 0 ..< len(ui_ctx.scrolls) {
			if ui_ctx.scrolls[index].id == scroll_id {
				scroll_index = index
				break
			}
		}
		if scroll_index < 0 {
			append(&ui_ctx.scrolls, Scroll_State{id = scroll_id})
			scroll_index = len(ui_ctx.scrolls) - 1
		}
		state := &ui_ctx.scrolls[scroll_index]
		state.last_touched = ui_ctx.frame
		maximum := max(state.content_size - state.viewport, 0)
		if maximum > 0 {
			state.target = clamp(state.target, 0, maximum)
			if state.thumb_held {
				state.current = state.target
			} else if scroll_speed > 0 {
				animation_cancel(id("offset", scroll_id))
				state.current += (state.target - state.current) * min(fx.frame_time() * scroll_speed, 1)
			} else {
				state.current = animate(id("offset", scroll_id), state.target, scroll_duration, .Quadratic_Out)
			}
		} else {
			state.current = 0
			state.target = 0
			state.thumb_held = false
			animation_cancel(id("offset", scroll_id))
		}
	}

	inner := fx.Rect{
		x = bounds.x + pad.left,
		y = bounds.y + pad.top,
		w = max(0, bounds.w - pad.left - pad.right),
		h = max(0, bounds.h - pad.top - pad.bottom),
	}
	axis_length := direction == .Row ? inner.w : inner.h
	gap_length := gap * f32(max(len(sizes) - 1, 0))
	available := max(0, axis_length - gap_length)
	fixed_length := f32(0)
	fraction_total := f32(0)
	for item in sizes {
		switch item.kind {
		case .Pixels:
			fixed_length += max(item.value, 0)
		case .Percent:
			fixed_length += available * clamp(item.value, 0, 1)
		case .Fraction:
			fraction_total += max(item.value, 0)
		}
	}

	append(&ui_ctx.layouts, Layout{
		bounds = bounds,
		inner = inner,
		sizes = sizes,
		direction = direction,
		gap = gap,
		fixed_length = fixed_length,
		fraction_total = fraction_total,
		free_length = max(0, available - fixed_length),
		can_scroll = can_scroll,
		scroll_index = scroll_index,
		scroll_style = scroll_style,
		scroll_marker = scroll_marker,
		scroll_duration = scroll_duration,
	})
	if can_scroll {
		push_clip(bounds)
	}
	return true
}

current_layout :: proc() -> ^Layout {
	assert(len(ui_ctx.layouts) > 0)
	return &ui_ctx.layouts[len(ui_ctx.layouts) - 1]
}

resolve_size :: proc(layout: ^Layout, item: Size) -> f32 {
	switch item.kind {
	case .Pixels:
		return max(item.value, 0)
	case .Percent:
		axis_length := layout.direction == .Row ? layout.inner.w : layout.inner.h
		gap_length := layout.gap * f32(max(len(layout.sizes) - 1, 0))
		return max(0, axis_length - gap_length) * clamp(item.value, 0, 1)
	case .Fraction:
		if layout.fraction_total <= 0 {
			return 0
		}
		return layout.free_length * max(item.value, 0) / layout.fraction_total
	}
	return 0
}

take :: proc(layout: ^Layout, length: f32) -> fx.Rect {
	if layout.item_count > 0 {
		layout.content_length += layout.gap
	}
	offset := layout.content_length
	layout.content_length += length
	layout.item_count += 1

	scroll_offset := f32(0)
	if layout.can_scroll {
		scroll_offset = ui_ctx.scrolls[layout.scroll_index].current
	}

	if layout.direction == .Row {
		return {
			x = layout.inner.x + offset - scroll_offset,
			y = layout.inner.y,
			w = length,
			h = layout.inner.h,
		}
	}
	return {
		x = layout.inner.x,
		y = layout.inner.y + offset - scroll_offset,
		w = layout.inner.w,
		h = length,
	}
}

next :: proc() -> fx.Rect {
	layout := current_layout()
	assert(layout.index < len(layout.sizes))
	item := layout.sizes[layout.index]
	layout.index += 1
	return take(layout, resolve_size(layout, item))
}

next_size :: proc(item: Size) -> fx.Rect {
	layout := current_layout()
	return take(layout, resolve_size(layout, item))
}

end_layout :: proc() {
	assert(len(ui_ctx.layouts) > 0)
	layout := pop(&ui_ctx.layouts)
	if !layout.can_scroll {
		return
	}
	assert(layout.scroll_index >= 0)

	state := &ui_ctx.scrolls[layout.scroll_index]
	state.content_size = layout.content_length +
		(layout.inner.y - layout.bounds.y) +
		(layout.bounds.y + layout.bounds.h - layout.inner.y - layout.inner.h)
	state.viewport = layout.bounds.h
	maximum := max(state.content_size - state.viewport, 0)
	state.target = clamp(state.target, 0, maximum)
	state.current = clamp(state.current, 0, maximum)

	pop_clip()
	if maximum <= 0 {
		state.current = 0
		state.target = 0
		state.thumb_held = false
		animation_cancel(id("offset", state.id))
		return
	}

	wheel := fx.mouse_scroll()
	wheel_claimed := false
	for &scroll_state in ui_ctx.scrolls {
		if ui_ctx.hot == scroll_state.id {
			wheel_claimed = true
			break
		}
	}
	owns_wheel := wheel.y != 0 && !ui_ctx.overlay && !wheel_claimed && mouse_visible(layout.bounds)
	if owns_wheel {
		state.target = clamp(state.target - wheel.y * 64, 0, maximum)
		ui_ctx.hot = state.id
	}

	style := layout.scroll_style
	if COLOR_SURFACE.a > 0 {
		fade_height := min(f32(30), layout.bounds.h * .25)
		transparent := fx.color_opacity(COLOR_SURFACE, 0)
		opaque := fx.color_opacity(COLOR_SURFACE, .96)
		if state.current > .5 {
			fx.draw_rect(
				{layout.bounds.x, layout.bounds.y, layout.bounds.w, fade_height},
				{opaque, opaque, transparent, transparent},
				8,
			)
		}
		if maximum - state.current > .5 {
			fx.draw_rect(
				{
					layout.bounds.x,
					layout.bounds.y + layout.bounds.h - fade_height,
					layout.bounds.w,
					fade_height,
				},
				{transparent, transparent, opaque, opaque},
				8,
			)
		}
	}

	if layout.bounds.h < 32 {
		return
	}

	track := fx.Rect{
		x = layout.bounds.x + layout.bounds.w - 7,
		y = layout.bounds.y + 7,
		w = 3,
		h = layout.bounds.h - 14,
	}
	ratio := clamp(state.viewport / state.content_size, 0, 1)
	thumb_height := max(track.h * ratio, 24)
	travel := track.h - thumb_height
	thumb_y := track.y + travel * state.current / maximum
	thumb := fx.Rect{track.x, thumb_y, track.w, thumb_height}

	hit_bounds := fx.rect_expand(thumb, 5, 2)
	hit := interact(id("thumb", state.id), hit_bounds)
	mouse := fx.mouse_pos()
	if hit.pressed {
		state.thumb_grab = mouse.y - thumb.y
		animation_cancel(id("offset", state.id))
	}
	state.thumb_held = hit.held
	if hit.held && travel > 0 {
		position := clamp(mouse.y - state.thumb_grab - track.y, 0, travel)
		state.current = position / travel * maximum
		state.target = state.current
		thumb.y = track.y + position
	}
	colors := style_state(style, hit)
	track_color := animate(id("track-color", state.id), colors.bg, HOVER_DURATION, .Sine_In_Out)
	thumb_color := animate(id("thumb-color", state.id), colors.text, HOVER_DURATION, .Sine_In_Out)
	if track_color.a > 0 do fx.draw_rect(track, track_color, track.w * .5)
	if thumb_color.a > 0 {
		fx.draw_rect(thumb, thumb_color, thumb.w * .5)
	}
	if layout.scroll_marker >= 0 {
		marker_target := clamp(layout.scroll_marker, 0, 1)
		marker_position := animate(
			id("marker-position", state.id),
			marker_target,
			layout.scroll_duration,
			.Quadratic_Out,
		)
		marker_height := min(f32(10), track.h)
		marker_y := track.y + (track.h - marker_height) * marker_position
		fx.draw_rect(
			{track.x, marker_y, track.w, marker_height},
			COLOR_ACCENT,
			track.w * .5,
		)
	}
	if owns_wheel {
		ui_ctx.hot = state.id
	}
}
