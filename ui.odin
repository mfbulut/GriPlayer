package main

import "core:math/ease"
import "core:hash"
import "core:time"
import "core:strings"

import "fx"

Id :: distinct u64

Scroll_State :: struct {
	scroll:            fx.Vec2,
	scroll_target:     fx.Vec2,
	content_size:      fx.Vec2,
	drag_start_scroll: fx.Vec2,
}

Layout :: struct {
	id:             Id,
	rect, body:     fx.Rect,
	pos, size, max: fx.Vec2,
	widths:         [32]f32,
	items_count:    int,
	item_index:     int,
	next_row:       f32,
	gap:            f32,
	bg_color:       fx.Color,
}

ctx : struct {
	hover_id, focus_id: Id,
	drag_start:    fx.Vec2,
	scroll_states: map[Id]Scroll_State,
	layout_stack:  [dynamic]Layout,
}

@(deferred_in=end)
begin :: proc(name: string, rect: fx.Rect = {}, pad: f32 = 0, gap: f32 = 0, scroll := false, bg := fx.BLANK, marker: f32 = -1) -> bool {
	id := get_id(name)

	layout := Layout {
		id = id,
		gap = gap,
		bg_color = bg,
	}

	layout.rect = rect.size.x > 0 ? rect : layout_next()
	fx.draw_rect(layout.rect, bg, 8)

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
		fx.set_scissor(body)
	} else {
		layout.body = fx.rect_shrink(body, pad)
	}

	append(&ctx.layout_stack, layout)

	return true
}

end :: proc(name: string, rect: fx.Rect = {}, pad: f32 = 0, gap: f32 = 0, scroll := false, bg := fx.BLANK, marker: f32 = -1) {
	layout := get_layout()

	if scroll {
		state := get_scroll_state(layout.id)
		state.content_size.x = layout.max.x - layout.body.pos.x
		state.content_size.y = layout.max.y - layout.body.pos.y

		if state.content_size.y > layout.rect.size.y {
			fade_height := min(f32(30), layout.rect.size.y * 0.25)
			transparent := layout.bg_color
			transparent.a = 0
			opaque := layout.bg_color

			if state.scroll.y > 0.1 {
				fx.draw_rect(
					{layout.rect.pos, {layout.rect.size.x, fade_height}},
					{opaque, opaque, transparent, transparent}, 8,
				)
			}

			max_scroll := state.content_size.y - layout.rect.size.y
			if max_scroll - state.scroll.y > 0.1 {
				fx.draw_rect(
					{{layout.rect.pos.x, layout.rect.pos.y + layout.rect.size.y - fade_height}, {layout.rect.size.x, fade_height}},
					{transparent, transparent, opaque, opaque}, 8,
				)
			}
		}

		fx.reset_scissor()
	}

	pop(&ctx.layout_stack)
}

get_id :: proc(str: string) -> Id {
	idx := len(ctx.layout_stack)
	seed := idx > 0 ? u64(ctx.layout_stack[idx - 1].id) : 2166136261
	return Id(hash.fnv64a(transmute([]byte)str, seed))
}

child_id :: proc(id: Id, child: Id) -> Id {
	child_u64 := u64(child)
	buf: [8]byte
	buf[0] = byte(child_u64)
	buf[1] = byte(child_u64 >> 8)
	buf[2] = byte(child_u64 >> 16)
	buf[3] = byte(child_u64 >> 24)
	buf[4] = byte(child_u64 >> 32)
	buf[5] = byte(child_u64 >> 40)
	buf[6] = byte(child_u64 >> 48)
	buf[7] = byte(child_u64 >> 56)
	return Id(hash.fnv64a(buf[:], u64(id)))
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
	layout.pos = fx.Vec2{0, layout.next_row}
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
		layout.pos = fx.Vec2{0, layout.next_row}
		layout.item_index = 0
	}

	res.pos = layout.pos
	res.size.x = layout.items_count > 0 ? layout.widths[layout.item_index] : layout.size.x
	res.size.y = layout.size.y
	if res.size.x < 0 { res.size.x += layout.body.size.x - res.pos.x + 1 }
	if res.size.y < 0 { res.size.y += layout.body.size.y - res.pos.y + 1 }

	layout.item_index += 1
	layout.pos.x += res.size.x + layout.gap
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
	initial:     f32,
	current:     f32,
	target:      f32,
	ease:        ease.Ease,
}

animations: map[Id]Animation

animate :: proc(animation_id: Id, target: f32, duration := f32(0.1), curve := ease.Ease.Cubic_Out) -> f32 {
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

animation_update_all :: proc() {
	keys_to_delete := make([dynamic]Id, context.temp_allocator)

	for key, &item in animations {
		diff := time.tick_since(item.last_update)

		if time.duration_seconds(diff) > 1 {
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

to_string :: proc(args: ..any) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator = context.temp_allocator)

	for arg in args {
		switch v in arg {
		case string:
			strings.write_string(&b, v)
		case int:
			strings.write_int(&b, v, 10)
		case f32:
			strings.write_float(&b, f64(v), 'f', 1, 32, true)
		}
	}

	return strings.to_string(b)
}