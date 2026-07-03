package fx

clear_window :: proc(color: Color) {
	tmp_color := color_to_vec4(color)
	d3d11_state.device_ctx->ClearRenderTargetView(d3d11_state.swapchain.default_rtv, &tmp_color)
}

set_sampler :: proc(kind: Sampler_Kind) {
	d3d11_state.batch.binding.sampler_kind = kind
}

set_scissor :: proc(rect: Rect) {
	scale := dpi_scale()
	d3d11_state.batch.binding.scissor = {
		cast(i32)(rect.x * scale),
		cast(i32)(rect.y * scale),
		cast(i32)((rect.x + rect.w) * scale),
		cast(i32)((rect.y + rect.h) * scale),
	}
}

reset_scissor :: proc() {
	ws := window_size()
	set_scissor({0, 0, ws.x, ws.y})
}

add_instance :: proc(inst: Instance) {
	batch := &d3d11_state.batch
	if len(batch.instanced) + 1 > cap(batch.instanced) {
		if !flush_batch() {
			return
		}
	}

	needs_new_run := len(batch.runs) == 0
	if !needs_new_run {
		last_binding := batch.runs[len(batch.runs) - 1].binding
		needs_new_run = last_binding != batch.binding
	}
	if needs_new_run && len(batch.runs) + 1 > cap(batch.runs) {
		if !flush_batch() {
			return
		}
	}
	if needs_new_run {
		start_index := cast(u32)len(batch.instanced)
		append(&batch.runs, Batch_Run{binding = batch.binding, first = start_index})
	}

	append(&batch.instanced, inst)
	batch.runs[len(batch.runs) - 1].count += 1
}

draw_rect :: proc(r: Rect, color: [4]Color, radius := f32(0)) {
	add_instance(
		Instance {
			dest = {r.x, r.y, r.x + r.w, r.y + r.h},
			color = color,
			radius = radius,
			kind = .Rect,
		},
	)
}

draw_rect_vec :: proc(pos, size: Vec2, color: [4]Color, radius := f32(0)) {
	draw_rect(Rect{pos.x, pos.y, size.x, size.y}, color, radius)
}

draw_circle :: proc(center: Vec2, radius: f32, color: [4]Color) {
	top_left := center - radius
	draw_rect_vec(top_left, radius * 2, color, radius)
}

draw_texture_ex :: proc(
	tex: Texture,
	src: Rect,
	dest: Rect,
	tint_rect := cast([4]Color)WHITE,
	radius := f32(0),
) {
	d3d11_state.batch.binding.texture = tex.srv

	tw := cast(f32)tex.size.x
	th := cast(f32)tex.size.y

	src_rect_arr := Rect {
		src.x / tw,
		src.y / th,
		(src.x + src.w) / tw,
		(src.y + src.h) / th,
	}

	add_instance(
		Instance {
			src = src_rect_arr,
			dest = {dest.x, dest.y, dest.x + dest.w, dest.y + dest.h},
			color = tint_rect,
			radius = radius,
			kind = .Texture,
		},
	)
}

draw_texture :: proc(tex: Texture, rect: Rect, tint_rect := cast([4]Color)WHITE, radius := f32(0)) {
	draw_texture_ex(tex, {0, 0, f32(tex.size.x), f32(tex.size.y)}, rect, tint_rect, radius)
}

draw_text :: proc {
	draw_text_vec,
	draw_text_rect,
}

draw_text_vec :: proc(font: Font, str: string, pos: Vec2, font_size: f32, color: [4]Color) {
	if str == "" do return

	d3d11_state.batch.binding.texture = font.atlas.srv

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := pos.x
	y := pos.y + (font.metrics.ascender * font_scale)

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y

	for char in str {
		if char == '\n' {
			x = pos.x
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		dest := Rect {
			x + (glyph.planeBounds.left * font_scale),
			y - (glyph.planeBounds.top * font_scale),
			x + (glyph.planeBounds.right * font_scale),
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src := Rect {
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance {
				dest = dest,
				src = src,
				color = color,
				kind = .Text,
			},
		)

		x += glyph.advance * font_scale
	}
}

draw_text_rect :: proc(font: Font, str: string, bounds: Rect, font_size: f32, color: Color, center_x := false, center_y := false) {
	if str == "" do return

	d3d11_state.batch.binding.texture = font.atlas.srv

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := bounds.x
	y := bounds.y + (font.metrics.ascender * font_scale)

	if center_x || center_y {
		size := measure_text(font, str, font_size)
		if center_x {
			x = bounds.x + (bounds.w - size.x) * 0.5
		}
		if center_y {
			y = bounds.y + (bounds.h - line_h) * 0.5 + (font.metrics.ascender * font_scale)
		}
	}

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y
	color := [4]Color{color, color, color, color}

	for char in str {
		if char == '\n' {
			x = bounds.x
			if center_x {
				size := measure_text(font, str, font_size)
				x = bounds.x + (bounds.w - size.x) * 0.5
			}
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		dest := Rect {
			x + (glyph.planeBounds.left * font_scale),
			y - (glyph.planeBounds.top * font_scale),
			x + (glyph.planeBounds.right * font_scale),
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src := Rect {
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance {
				dest = dest,
				src = src,
				color = color,
				kind = .Text,
			},
		)

		x += glyph.advance * font_scale
	}
}

draw_text_faded :: proc(font: Font, str: string, bounds: Rect, font_size: f32, color: Color, center_y := false) {
	if str == "" do return

	d3d11_state.batch.binding.texture = font.atlas.srv

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := bounds.x
	y := bounds.y + (font.metrics.ascender * font_scale)

	if center_y {
		y = bounds.y + (bounds.h - line_h) * 0.5 + (font.metrics.ascender * font_scale)
	}

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y

	max_w := bounds.w
	fade_w := min(f32(30), max_w)
	fade_start := bounds.x + max_w - fade_w

	for char in str {
		if char == '\n' {
			x = bounds.x
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		left_x := x + (glyph.planeBounds.left * font_scale)
		right_x := x + (glyph.planeBounds.right * font_scale)

		if left_x > bounds.x + max_w {
			break
		}

		alpha_l := f32(1.0)
		if left_x > fade_start {
			alpha_l = 1.0 - clamp((left_x - fade_start) / fade_w, 0.0, 1.0)
		}

		alpha_r := f32(1.0)
		if right_x > fade_start {
			alpha_r = 1.0 - clamp((right_x - fade_start) / fade_w, 0.0, 1.0)
		}

		color_tl := color
		color_tl.a = u8(f32(color.a) * alpha_l)
		color_bl := color_tl

		color_tr := color
		color_tr.a = u8(f32(color.a) * alpha_r)
		color_br := color_tr

		color := [4]Color{color_tl, color_tr, color_bl, color_br}

		dest := Rect {
			left_x,
			y - (glyph.planeBounds.top * font_scale),
			right_x,
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src := Rect {
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance {
				dest = dest,
				src = src,
				color = color,
				kind = .Text,
			},
		)

		x += glyph.advance * font_scale
	}
}

measure_text :: proc(font: Font, text: string, font_size: f32) -> Vec2 {
	if text == "" {
		return {0, 0}
	}

	cursor_x := f32(0)
	max_x := f32(0)

	font_scale := font_size / font.metrics.emSize
	line_height := font.metrics.lineHeight * font_scale

	total_height := line_height

	for char in text {
		if char == '\n' {
			max_x = max(max_x, cursor_x)
			cursor_x = 0
			total_height += line_height
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		cursor_x += glyph.advance * font_scale
	}

	return {max(max_x, cursor_x), total_height}
}
