package main

import easing "core:math/ease"

import "fx"

Animation_Value :: union #no_nil {
	f32,
	fx.Vec2,
	fx.Rect,
	fx.Color,
}

Animation :: struct {
	id:           ID,
	last_touched: u64,
	progress:     f32,
	duration:     f32,
	easing:       easing.Ease,
	initial:      Animation_Value,
	current:      Animation_Value,
	target:       Animation_Value,
}

animation_find :: proc(animation_id: ID) -> int {
	for index in 0 ..< len(ui_ctx.animations) {
		if ui_ctx.animations[index].id == animation_id {
			return index
		}
	}
	return -1
}

animation_cancel :: proc(animation_id: ID) {
	index := animation_find(animation_id)
	if index < 0 {
		return
	}
	last := pop(&ui_ctx.animations)
	if index < len(ui_ctx.animations) {
		ui_ctx.animations[index] = last
	}
}

animation_value_equal :: proc(a, b: Animation_Value) -> bool {
	switch value in a {
	case f32:
		other, ok := b.(f32)
		return ok && value == other
	case fx.Vec2:
		other, ok := b.(fx.Vec2)
		return ok && value == other
	case fx.Rect:
		other, ok := b.(fx.Rect)
		return ok && value == other
	case fx.Color:
		other, ok := b.(fx.Color)
		return ok && value == other
	}
	return false
}

animation_to :: proc(
	animation_id: ID,
	target: Animation_Value,
	duration: f32,
	curve: easing.Ease,
) -> Animation_Value {
	index := animation_find(animation_id)
	if index < 0 {
		append(&ui_ctx.animations, Animation{
			id = animation_id,
			last_touched = ui_ctx.frame,
			progress = 1,
			duration = duration,
			easing = curve,
			initial = target,
			current = target,
			target = target,
		})
		return target
	}

	item := &ui_ctx.animations[index]
	item.last_touched = ui_ctx.frame
	amount := easing.ease(item.easing, clamp(item.progress, 0, 1))
	switch initial in item.initial {
	case f32:
		target := item.target.(f32)
		item.current = initial + (target - initial) * amount
	case fx.Vec2:
		target := item.target.(fx.Vec2)
		item.current = initial + (target - initial) * amount
	case fx.Rect:
		target := item.target.(fx.Rect)
		item.current = fx.Rect{
			initial.x + (target.x - initial.x) * amount,
			initial.y + (target.y - initial.y) * amount,
			initial.w + (target.w - initial.w) * amount,
			initial.h + (target.h - initial.h) * amount,
		}
	case fx.Color:
		from := initial
		to := item.target.(fx.Color)
		if from.a == 0 do from.rgb = to.rgb
		if to.a == 0 do to.rgb = from.rgb
		item.current = fx.color_lerp(from, to, amount)
	}

	if !animation_value_equal(item.target, target) {
		item.initial = item.current
		item.target = target
		item.progress = 0
		item.duration = duration
		item.easing = curve
	}
	if duration <= 0 {
		item.initial = target
		item.current = target
		item.target = target
		item.progress = 1
	}
	return item.current
}

animate_f32 :: proc(animation_id: ID, target, duration: f32, curve: easing.Ease) -> f32 {
	return animation_to(animation_id, target, duration, curve).(f32)
}

animate_vec2 :: proc(animation_id: ID, target: fx.Vec2, duration: f32, curve: easing.Ease) -> fx.Vec2 {
	return animation_to(animation_id, target, duration, curve).(fx.Vec2)
}

animate_rect :: proc(animation_id: ID, target: fx.Rect, duration: f32, curve: easing.Ease) -> fx.Rect {
	return animation_to(animation_id, target, duration, curve).(fx.Rect)
}

animate_color :: proc(animation_id: ID, target: fx.Color, duration: f32, curve: easing.Ease) -> fx.Color {
	return animation_to(animation_id, target, duration, curve).(fx.Color)
}

animate :: proc {
	animate_f32,
	animate_vec2,
	animate_rect,
	animate_color,
}

smooth_f32 :: proc(animation_id: ID, target, speed: f32) -> f32 {
	index := animation_find(animation_id)
	if index < 0 {
		append(&ui_ctx.animations, Animation{
			id = animation_id,
			last_touched = ui_ctx.frame,
			progress = 1,
			initial = f32(0),
			current = f32(0),
			target = f32(0),
		})
		index = len(ui_ctx.animations) - 1
	}

	item := &ui_ctx.animations[index]
	item.last_touched = ui_ctx.frame
	current := item.current.(f32)
	current += (target - current) * min(fx.frame_time() * speed, 1)
	item.progress = 1
	item.initial = current
	item.current = current
	item.target = current
	return current
}

animation_update_all :: proc() {
	for index := len(ui_ctx.animations) - 1; index >= 0; index -= 1 {
		item := &ui_ctx.animations[index]
		if ui_ctx.frame - item.last_touched > 600 {
			last := pop(&ui_ctx.animations)
			if index < len(ui_ctx.animations) {
				ui_ctx.animations[index] = last
			}
			continue
		}
		if item.progress < 1 {
			item.progress = min(item.progress + fx.frame_time() / max(item.duration, 0.0001), 1)
		}
	}
}
