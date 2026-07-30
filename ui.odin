package main

import "core:math/ease"
import "core:hash"
import "core:time"

import "fx"

Id :: distinct u64

Layout :: struct {
	body:                fx.Rect,
	position, size, max: fx.Vec2,
	widths:              [32]f32,
	items_count:         int,
	item_index:          int,
	next_row:            f32,
	gap:             	 f32,
}

Container :: struct {
	rect, body:    fx.Rect,
	content_size:  fx.Vec2,
	scroll:        fx.Vec2,
	scroll_target: fx.Vec2,
	bg_color:      fx.Color,
	has_scroll:    bool,
}

ctx : struct {
	frame: int,
	hover_id, focus_id, scroll_id: Id,
	containers:      map[Id]Container,
	container_stack: [dynamic; 256]Id,
	layout_stack:    [dynamic; 256]Layout,
	clip_stack:      [dynamic; 256]fx.Rect,
}

@(deferred_none=end)
begin :: proc(name: string, rect: fx.Rect = {}, pad: f32 = 0, gap: f32 = 0, radius: f32 = 8, scroll := false, bg := fx.BLANK, marker: f32 = -1) -> bool {
	is_root := len(ctx.container_stack) == 0

	id := scroll ? get_id(name) : get_id("temp")
	container := get_container(id)
	container.bg_color = bg
	container.rect = is_root ? rect : layout_next()

	fx.draw_rect(container.rect, bg, radius)

	append(&ctx.container_stack, id)
	container.has_scroll = scroll

	body := container.rect

	if scroll {
		cs := container.content_size + pad
		if cs.x > container.body.size.x { body.size.y -= 9 }
		if cs.y > container.body.size.y { body.size.x -= 9 }
		scrollbar(container, body, cs, "scrollbar_v", 1, marker)
		scrollbar(container, body, cs, "scrollbar_h", 0, -1)
	}

	layout_body := fx.rect_shrink(body, pad)
	layout := Layout {
		body = fx.Rect{layout_body.pos - container.scroll, layout_body.size},
		gap = gap,
	}

	append(&ctx.layout_stack, layout)
	container.body = body

	if scroll do push_clip_rect(container.body)
	return true
}

end :: proc() {
	layout := get_layout()
	container := get_current_container()
	container.content_size.x = layout.max.x - layout.body.pos.x
	container.content_size.y = layout.max.y - layout.body.pos.y

	if container.content_size.y > container.body.size.y {
		fade_height := min(f32(30), container.body.size.y * 0.25)
		transparent := container.bg_color
		transparent.a = 0
		opaque := container.bg_color

		if container.scroll.y > 0.1 {
			fx.draw_rect(
				{container.body.pos, {container.body.size.x, fade_height}},
				{opaque, opaque, transparent, transparent}, 8
			)
		}

		max_scroll := container.content_size.y - container.body.size.y
		if max_scroll - container.scroll.y > 0.1 {
			fx.draw_rect(
				{{container.body.pos.x, container.body.pos.y + container.body.size.y - fade_height}, {container.body.size.x, fade_height}},
				{transparent, transparent, opaque, opaque}, 8
			)
		}
	}

	pop(&ctx.container_stack)
	pop(&ctx.layout_stack)

	if container.has_scroll do pop_clip_rect()
}

update_ui :: proc() {
	if ctx.scroll_id != 0 {
		container := get_container(ctx.scroll_id)
		container.scroll_target.x += fx.mouse_scroll().x * 60
		container.scroll_target.y += fx.mouse_scroll().y * -60
	}

	ctx.scroll_id = 0
	ctx.frame += 1
}

get_id         :: proc{get_id_string, get_id_bytes}
get_id_string  :: #force_inline proc(str: string)  -> Id { return get_id_bytes(transmute([]byte) str) }

get_id_bytes   :: proc(bytes: []byte) -> Id {
	idx := len(ctx.container_stack)
	seed := idx > 0 ? u64(ctx.container_stack[idx - 1]) : 2166136261
	return Id(hash.fnv64a(bytes, seed))
}

get_child_id         :: proc{get_child_id_string, get_child_id_bytes}
get_child_id_string  :: #force_inline proc(id: Id, str: string)  -> Id { return get_child_id_bytes(id, transmute([]byte) str) }
get_child_id_bytes   :: proc(id: Id, bytes: []byte) -> Id {
	return Id(hash.fnv64a(bytes, u64(id)))
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

get_current_container :: proc() -> ^Container {
	return get_container(ctx.container_stack[len(ctx.container_stack) - 1])
}

get_container :: proc(id: Id) -> ^Container {
	_, ptr, _, _ := map_entry(&ctx.containers, id)
	return ptr
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