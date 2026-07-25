package fx

import "core:encoding/json"

Texture :: struct {
	index: int,
	size:   [2]int,
}

Instance :: struct {
	dest:   Rect,      // x0, y0, x1, y1
	src:    Rect,      // u0, v0, u1, v1
	color:  [4]Color,  // TL, TR, BL, BR
	radius: f32,
	_pad:   f32,
	kind:   enum u32 { Rect, Texture, Text },
	tex_idx: u32,
}

// Font

Glyph :: struct {
	advance:     f32,
	atlasBounds: MSDF_Bounds,
	planeBounds: MSDF_Bounds,
}

Font :: struct {
	atlas:   Texture,
	metrics: MSDF_Metrics,
	glyphs:  map[rune]Glyph,
}

font: Font

MSDF_Metrics :: struct {
	emSize:             f32,
	lineHeight:         f32,
	ascender:           f32,
	descender:          f32,
	underlineY:         f32,
	underlineThickness: f32,
}

MSDF_Bounds :: struct {
	left, bottom, right, top: f32,
}

MSDF_Glyph :: struct {
	unicode:     u32,
	advance:     f32,
	planeBounds: MSDF_Bounds,
	atlasBounds: MSDF_Bounds,
}

MSDF_File :: struct {
	metrics: MSDF_Metrics,
	glyphs:  []MSDF_Glyph,
}

renderer_init :: proc() {
	msdf_data: MSDF_File
	if err := json.unmarshal(#load("../assets/Inter.json"), &msdf_data, allocator = context.temp_allocator); err != nil {
		panic("[ERROR] Failed to parse MSDF JSON")
	}

	font.atlas = texture_load(#load("../assets/Inter.png"), false)
	font.metrics = msdf_data.metrics

	for glyph in msdf_data.glyphs {
		font.glyphs[cast(rune)glyph.unicode] = Glyph{
			advance     = glyph.advance,
			atlasBounds = glyph.atlasBounds,
			planeBounds = glyph.planeBounds,
		}
	}
}

batch: struct {
	instances: [dynamic; MAX_INSTANCES]Instance,
	scissor:   [4]i32,
}

clear_window :: proc(color: Color) {
	if window.size.x <= 0 || window.size.y <= 0 || window_is_minimized() do return
	vks.clear_color = color_to_vec4(color)
}

set_scissor :: proc(rect: Rect) {
	flush()
	scale := dpi_scale()
	batch.scissor = {
		cast(i32)(rect.x * scale),
		cast(i32)(rect.y * scale),
		cast(i32)(rect.w * scale),
		cast(i32)(rect.h * scale),
	}
}

reset_scissor :: proc() {
	ws := window_size()
	set_scissor({0, 0, ws.x, ws.y})
}

add_instance :: proc(inst: Instance) {
	if len(batch.instances) >= MAX_INSTANCES {
		flush()
	}
	append(&batch.instances, inst)
}

flush :: proc() {
	if len(batch.instances) == 0 do return
	vk_draw_instances(batch.instances[:], batch.scissor)
	clear(&batch.instances)
}

draw_rect :: proc(r: Rect, color: [4]Color, radius := f32(0)) {
	add_instance(
		Instance{
			dest   = {r.x, r.y, r.x + r.w, r.y + r.h},
			src    = {},
			color  = color,
			radius = radius,
			kind   = .Rect,
			tex_idx = 0,
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

draw_texture_ex :: proc(tex: Texture, src: Rect, dest: Rect, tint := cast([4]Color)WHITE, radius := f32(0)) {
	if tex.index < 0 do return
	tw := cast(f32)tex.size.x
	th := cast(f32)tex.size.y

	src_uv := Rect{
		src.x / tw,
		src.y / th,
		(src.x + src.w) / tw,
		(src.y + src.h) / th,
	}

	add_instance(
		Instance{
			src     = src_uv,
			dest    = {dest.x, dest.y, dest.x + dest.w, dest.y + dest.h},
			color   = tint,
			radius  = radius,
			kind    = .Texture,
			tex_idx = u32(tex.index),
		},
	)
}

draw_texture :: proc(tex: Texture, rect: Rect, tint := cast([4]Color)WHITE, radius := f32(0)) {
	draw_texture_ex(tex, {0, 0, f32(tex.size.x), f32(tex.size.y)}, rect, tint, radius)
}

// Text Rendering

draw_text :: proc {
	draw_text_vec,
	draw_text_rect,
}

draw_text_vec :: proc(text: string, pos: Vec2, font_size: f32, color: [4]Color) {
	if text == "" do return
	font := font

	font_scale := font_size / font.metrics.emSize
	line_h := font.metrics.lineHeight * font_scale

	x := pos.x
	y := pos.y + (font.metrics.ascender * font_scale)

	atlas_w := cast(f32)font.atlas.size.x
	atlas_h := cast(f32)font.atlas.size.y

	for char in text {
		if char == '\n' {
			x = pos.x
			y += line_h
			continue
		}

		glyph := font.glyphs[char] or_else font.glyphs['?']

		dest := Rect{
			x + (glyph.planeBounds.left * font_scale),
			y - (glyph.planeBounds.top * font_scale),
			x + (glyph.planeBounds.right * font_scale),
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src := Rect{
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance{
				dest    = dest,
				src     = src,
				color   = color,
				kind    = .Text,
				tex_idx = u32(font.atlas.index),
			},
		)

		x += glyph.advance * font_scale
	}
}

draw_text_rect :: proc(text: string, bounds: Rect, font_size: f32, color: [4]Color, center_x := false, center_y := true) {
	if text == "" do return
	font := font

	x := bounds.x
	y := bounds.y

	if center_x || center_y {
		size := measure_text(text, font_size)
		if center_x {
			x = bounds.x + (bounds.w - size.x) * 0.5
		}
		if center_y {
			font_scale := font_size / font.metrics.emSize
			line_h := font.metrics.lineHeight * font_scale
			y = bounds.y + (bounds.h - line_h) * 0.5
		}
	}

	draw_text_vec(text, {x, y}, font_size, color)
}

draw_text_faded :: proc(text: string, bounds: Rect, font_size: f32, color: Color, center_x := false, center_y := true) {
	if text == "" || bounds.w <= 0 do return
	font := font

	if measure_text(text, font_size).x <= bounds.w {
		draw_text_rect(text, bounds, font_size, color, center_x, center_y)
		return
	}

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

	for char in text {
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

		c := [4]Color{color_tl, color_tr, color_bl, color_br}

		dest := Rect{
			left_x,
			y - (glyph.planeBounds.top * font_scale),
			right_x,
			y - (glyph.planeBounds.bottom * font_scale),
		}

		src := Rect{
			glyph.atlasBounds.left / atlas_w,
			1 - (glyph.atlasBounds.top / atlas_h),
			glyph.atlasBounds.right / atlas_w,
			1 - (glyph.atlasBounds.bottom / atlas_h),
		}

		add_instance(
			Instance{
				dest    = dest,
				src     = src,
				color   = c,
				kind    = .Text,
				tex_idx = u32(font.atlas.index),
			},
		)

		x += glyph.advance * font_scale
	}
}

measure_text :: proc(text: string, font_size: f32) -> Vec2 {
	if text == "" do return {0, 0}
	font := font

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
