package main

import "core:math/ease"
import "core:hash"
import "core:time"

import "fx"

Id :: distinct u64

Scroll_State :: struct {
	scroll:        fx.Vec2,
	scroll_target: fx.Vec2,
	content_size:  fx.Vec2,
}

Layout :: struct {
	id:                  Id,
	rect, body:          fx.Rect,
	position, size, max: fx.Vec2,
	widths:              [32]f32,
	items_count:         int,
	item_index:          int,
	next_row:            f32,
	gap:                 f32,
	bg_color:            fx.Color,
	has_scroll:          bool,
}

ctx : struct {
	frame: int,
	hover_id, focus_id, scroll_id: Id,
	scroll_states:      map[Id]Scroll_State,
	layout_stack:    [dynamic]Layout,
	clip_stack:      [dynamic]fx.Rect,
}

@(deferred_none=end)
begin :: proc(name: string, rect: fx.Rect = {}, pad: f32 = 0, gap: f32 = 0, radius: f32 = 8, scroll := false, bg := fx.BLANK, marker: f32 = -1) -> bool {
	is_root := len(ctx.layout_stack) == 0

	id := scroll ? get_id(name) : get_id("temp")

	layout := Layout {
		id = id,
		bg_color = bg,
		has_scroll = scroll,
		gap = gap,
	}

	layout.rect = is_root ? rect : layout_next()
	fx.draw_rect(layout.rect, bg, radius)

	body := layout.rect

	if scroll {
		state := get_scroll_state(id)
		cs := state.content_size + pad
		if cs.x > body.size.x { body.size.y -= 9 }
		if cs.y > body.size.y { body.size.x -= 9 }
		scrollbar(id, state, body, cs, "scrollbar_v", 1, marker)
		scrollbar(id, state, body, cs, "scrollbar_h", 0, -1)

		layout_body := fx.rect_shrink(body, pad)
		layout.body = fx.Rect{layout_body.pos - state.scroll, layout_body.size}
		push_clip_rect(body)
	} else {
		layout.body = fx.rect_shrink(body, pad)
	}

	append(&ctx.layout_stack, layout)
	return true
}

end :: proc() {
	layout := get_layout()

	if layout.has_scroll {
		state := get_scroll_state(layout.id)
		state.content_size.x = layout.max.x - layout.body.pos.x
		state.content_size.y = layout.max.y - layout.body.pos.y

		fade_height := min(f32(30), layout.body.size.y * 0.25)
		transparent := layout.bg_color
		transparent.a = 0
		opaque := layout.bg_color

		if state.scroll.y > 0.1 {
			fx.draw_rect(
				{layout.body.pos, {layout.body.size.x, fade_height}},
				{opaque, opaque, transparent, transparent}, 8
			)
		}

		max_scroll := state.content_size.y - layout.body.size.y
		if max_scroll - state.scroll.y > 0.1 {
			fx.draw_rect(
				{{layout.body.pos.x, layout.body.pos.y + layout.body.size.y - fade_height}, {layout.body.size.x, fade_height}},
				{transparent, transparent, opaque, opaque}, 8
			)
		}

		pop_clip_rect()
	}

	pop(&ctx.layout_stack)
}

update_ui :: proc() {
	if ctx.scroll_id != 0 {
		state := get_scroll_state(ctx.scroll_id)
		state.scroll_target.x += fx.mouse_scroll().x * 60
		state.scroll_target.y += fx.mouse_scroll().y * -60
	}

	ctx.scroll_id = 0
	ctx.frame += 1
}

get_id :: proc(str: string) -> Id {
	idx := len(ctx.layout_stack)
	seed := idx > 0 ? u64(ctx.layout_stack[idx - 1].id) : 2166136261
	return Id(hash.fnv64a(transmute([]byte)str, seed))
}

child_id   :: proc(id: Id, str: string) -> Id {
	return Id(hash.fnv64a(transmute([]byte)str, u64(id)))
}

push_clip_rect :: proc(rect: fx.Rect) {
	append(&ctx.clip_stack, rect)
	fx.set_scissor(get_clip_rect())
}

pop_clip_rect :: proc() {
	pop(&ctx.clip_stack)
	fx.set_scissor(get_clip_rect())
}

get_clip_rect :: proc() -> fx.Rect {
	if len(ctx.clip_stack) == 0 do return fx.Rect{{0, 0}, {99999, 99999}}
	return ctx.clip_stack[len(ctx.clip_stack) - 1]
}

get_scroll_state :: proc(id: Id) -> ^Scroll_State {
	if id not_in ctx.scroll_states {
		ctx.scroll_states[id] = {}
	}
	return &ctx.scroll_states[id]
}

get_layout :: proc() -> ^Layout {
	return &ctx.layout_stack[len(ctx.layout_stack) - 1]
}

layout_row :: proc(widths: []f32, height: f32 = 0, gap: f32 = -1) {
	layout := get_layout()
	if gap >= 0 do layout.gap = gap

	if len(widths) > 0 do copy(layout.widths[:], widths[:])
	layout.items_count = len(widths)
	layout.position = fx.Vec2{0, layout.next_row}
	layout.size.y = height
	layout.item_index = 0

	if layout.items_count == 0 do return

	fixed_width: f32 = 0
	flex_weight: f32 = 0
	for i in 0..<layout.items_count {
		w := layout.widths[i]
		if w > 0 do fixed_width += w
		else if w < 0 do flex_weight += -w
	}

	if flex_weight == 0 do return

	spacing_width := f32(layout.items_count - 1) * layout.gap
	available_width := max(0, layout.body.size.x - fixed_width - spacing_width)

	for i in 0..<layout.items_count {
		w := layout.widths[i]
		if w < 0 do layout.widths[i] = available_width * (-w / flex_weight)
	}
}

layout_next :: proc() -> (res: fx.Rect) {
	layout := get_layout()

	if layout.item_index == layout.items_count {
		layout.position = fx.Vec2{0, layout.next_row}
		layout.item_index = 0
	}

	res.pos = layout.position
	res.size.x = layout.items_count > 0 ? layout.widths[layout.item_index] : layout.size.x
	res.size.y = layout.size.y
	if res.size.x < 0 { res.size.x += layout.body.size.x - res.pos.x + 1 }
	if res.size.y < 0 { res.size.y += layout.body.size.y - res.pos.y + 1 }

	layout.item_index += 1
	layout.position.x += res.size.x + layout.gap
	layout.next_row = max(layout.next_row, res.pos.y + res.size.y + layout.gap)

	res.pos += layout.body.pos

	layout.max.x = max(layout.max.x, res.pos.x + res.size.x)
	layout.max.y = max(layout.max.y, res.pos.y + res.size.y)
	return
}

Animation :: struct {
	last_update: time.Tick,
	progress:    f32,
	duration:    f32,
	initial:     fx.Vec4,
	current:     fx.Vec4,
	target:      fx.Vec4,
	ease:        ease.Ease,
}

animations: map[Id]Animation

animation_to :: proc(animation_id: Id, target: fx.Vec4, duration: f32, curve: ease.Ease) -> fx.Vec4 {
	if animation_id not_in animations {
		animations[animation_id] = Animation{
			last_update = time.tick_now(),
			progress = 1,
			duration = duration,
			ease = curve,
			initial = target,
			current = target,
			target = target,
		}
		return target
	}

	item := &animations[animation_id]
	item.last_update = time.tick_now()
	amount := ease.ease(item.ease, clamp(item.progress, 0, 1))
	item.current = item.initial + (item.target - item.initial) * amount

	if item.target != target {
		item.initial = item.current
		item.target = target
		item.progress = 0
		item.duration = duration
		item.ease = curve
	}

	if duration <= 0 {
		item.initial = target
		item.current = target
		item.target = target
		item.progress = 1
	}

	return item.current
}

animation_cancel :: proc(animation_id: Id) {
	delete_key(&animations, animation_id)
}

animate_f32 :: proc(id: Id, target: f32, duration := f32(0.08), curve := ease.Ease.Cubic_Out) -> f32 {
	return animation_to(id, {target, 0, 0, 0}, duration, curve).x
}

animate_color :: proc(id: Id, target: fx.Color, duration := f32(0.08), curve := ease.Ease.Cubic_Out) -> fx.Color {
	value := fx.color_to_vec4(target)
	result := animation_to(id, value, duration, curve)
	return fx.vec4_to_color(result)
}

animate :: proc {
	animate_f32,
	animate_color,
}

animation_update_all :: proc() {
	keys_to_delete := make([dynamic]Id, context.temp_allocator)
	for key, &item in animations {
		diff := time.tick_since(item.last_update)

		if time.duration_seconds(diff) > 10 {
			append(&keys_to_delete, key)
			continue
		}

		if item.progress < 1 {
			item.progress = min(item.progress + fx.frame_time() / max(item.duration, 0.0001), 1)
		}
	}

	for key in keys_to_delete {
		delete_key(&animations, key)
	}
}