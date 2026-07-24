package main

import easing "core:math/ease"

import "fx"

Animation :: struct {
	id:           ID,
	last_touched: u64,
	progress:     f32,
	duration:     f32,
	easing:       easing.Ease,
	initial:      fx.Vec4,
	current:      fx.Vec4,
	target:       fx.Vec4,
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

animation_to :: proc(animation_id: ID, target: fx.Vec4, duration: f32, curve: easing.Ease) -> fx.Vec4 {
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
	item.current = item.initial + (item.target - item.initial) * amount

	if item.target != target {
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

animate_f32 :: proc(
	animation_id: ID,
	target: f32,
	duration := f32(0.08),
	curve := easing.Ease.Sine_In_Out,
) -> f32 {
	return animation_to(animation_id, {target, 0, 0, 0}, duration, curve).x
}

animate_vec2 :: proc(
	animation_id: ID,
	target: fx.Vec2,
	duration := f32(0.08),
	curve := easing.Ease.Sine_In_Out,
) -> fx.Vec2 {
	return animation_to(animation_id, {target.x, target.y, 0, 0}, duration, curve).xy
}

animate_rect :: proc(
	animation_id: ID,
	target: fx.Rect,
	duration := f32(0.08),
	curve := easing.Ease.Sine_In_Out,
) -> fx.Rect {
	value := animation_to(animation_id, {target.x, target.y, target.w, target.h}, duration, curve)
	return {value.x, value.y, value.z, value.w}
}

animate_color :: proc(
	animation_id: ID,
	target: fx.Color,
	duration := f32(0.08),
	curve := easing.Ease.Sine_In_Out,
) -> fx.Color {
	value := fx.color_to_vec4(target)
	if index := animation_find(animation_id); index >= 0 {
		item := &ui_ctx.animations[index]
		if item.current.a == 0 {
			item.initial.rgb = value.rgb
			item.current.rgb = value.rgb
			item.target.rgb = value.rgb
		}
		if value.a == 0 do value.rgb = item.current.rgb
	}

	return fx.vec4_to_color(animation_to(animation_id, value, duration, curve))
}

animate :: proc {
	animate_f32,
	animate_vec2,
	animate_rect,
	animate_color,
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
