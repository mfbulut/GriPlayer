package fx

import "core:mem"
import "core:slice"

Instance :: struct #align(16) {
	dest:   Rect,     // x0, y0, x1, y1
	src:    Rect,     // u0, v0, u1, v1
	color:  [4]Color, // TL, TR, BL, BR
	radius: f32,
	index:  u32,
	kind:   enum u32 { Rect, Texture, MSDF, Quad, Text },
}

NUM_STRIPES :: 8

Stripe :: struct {
	curve_start: u32,
	curve_count: u32,
}

Glyph :: struct {
	unicode: u32,
	advance: f32,
	bounds:  Rect,
}

FontGlyph :: struct {
	advance: f32,
	index:   u32,
	bounds:  Rect,
}

Batch :: struct {
	offset:  u32,
	count:   u32,
	scissor: Rect,
}

total_curves_loaded: u32
scissor: Rect
font: map[rune]FontGlyph
batches: [dynamic; 256]Batch
instances: [dynamic; MAX_INSTANCES]Instance

clear_window :: proc(color: Color) {
	vks.clear_color = Vec4(color) / 255.0
}

set_scissor :: proc(rect: Rect) {
	if rect != scissor {
		flush()
		scissor = rect
	}
}

reset_scissor :: proc() {
	set_scissor({{0, 0}, window_size()})
}

flush :: proc() {
	if len(instances) == 0 do return

	last_count: u32 = 0
	for b in batches {
		last_count += b.count
	}

	count := u32(len(instances)) - last_count
	if count == 0 do return

	append(&batches, Batch{
		offset  = last_count,
		count   = count,
		scissor = scissor,
	})
}

rect_visible :: proc(rect: Rect) -> bool {
	return rect_overlaps(rect, scissor)
}

draw_rect :: proc(r: Rect, color: [4]Color, radius := f32(0)) {
	if !rect_visible(r) do return

	append(&instances,
		Instance{
			dest   = {r.pos, r.pos + r.size},
			src    = {},
			color  = color,
			radius = radius,
			kind   = .Rect,
		}
	)
}

draw_circle :: proc(center: Vec2, radius: f32, color: [4]Color) {
	r := Rect{center - radius, radius * 2}
	if !rect_visible(r) do return
	draw_rect(r, color, radius)
}

draw_quad :: proc(p0, p1, p2, p3: Vec2, color: [4]Color) {
	append(&instances,
		Instance{
			dest   = {p0, p1},
			src    = {p2, p3},
			color  = color,
			kind   = .Quad,
		},
	)
}

draw_texture_ex :: proc(tex: Texture, src: Rect, dest: Rect, tint := cast([4]Color)WHITE, radius := f32(0)) {
	if !rect_overlaps(dest, scissor) || tex.index == 0 do return

	size := Vec2(tex.size)

	src_uv := Rect{
		src.pos / size,
		(src.pos + src.size) / size,
	}

	append(&instances,
		Instance{
			src    = src_uv,
			dest   = {dest.pos, dest.pos + dest.size},
			color  = tint,
			radius = radius,
			kind   = .Texture,
			index  = u32(tex.index),
		}
	)
}

draw_texture :: proc(tex: Texture, rect: Rect, tint := cast([4]Color)WHITE, radius := f32(0)) {
	draw_texture_ex(tex, {{0, 0}, {f32(tex.size.x), f32(tex.size.y)}}, rect, tint, radius)
}

draw_msdf_ex :: proc(tex: Texture, src: Rect, dest: Rect, px_range: f32, tint := cast([4]Color)WHITE) {
	if !rect_visible(dest) do return
	if tex.index == 0 do return

	size := Vec2(tex.size)

	src_uv := Rect{
		src.pos / size,
		(src.pos + src.size) / size,
	}

	append(&instances,
		Instance{
			src    = src_uv,
			dest   = {dest.pos, dest.pos + dest.size},
			color  = tint,
			radius = px_range / size.x,
			kind   = .MSDF,
			index  = u32(tex.index),
		},
	)
}

draw_msdf :: proc(tex: Texture, rect: Rect, px_range: f32, tint := cast([4]Color)WHITE) {
	draw_msdf_ex(tex, {{0, 0}, {f32(tex.size.x), f32(tex.size.y)}}, rect, px_range, tint)
}

// Text Rendering

font_load :: proc(font_bytes: []u8) {
	offset := 0

	glyph_count := (^u32)(raw_data(font_bytes[offset:]))^
	offset += size_of(u32)

	curve_count := (^u32)(raw_data(font_bytes[offset:]))^
	offset += size_of(u32)

	glyphs_bytes_len := int(glyph_count) * size_of(Glyph)
	glyph_bytes := font_bytes[offset : offset + glyphs_bytes_len]
	glyphs_slice := slice.reinterpret([]Glyph, glyph_bytes)
	offset += glyphs_bytes_len

	total_stripes := int(glyph_count) * NUM_STRIPES
	stripes_bytes_len := total_stripes * size_of(Stripe)
	stripe_bytes := font_bytes[offset : offset + stripes_bytes_len]
	stripes_slice := slice.reinterpret([]Stripe, stripe_bytes)
	offset += stripes_bytes_len

	curves_bytes_len := int(curve_count) * 12
	curve_bytes := font_bytes[offset : offset + curves_bytes_len]

	glyphs := make(map[rune]FontGlyph, glyph_count)
	for g, i in glyphs_slice {
		glyphs[rune(g.unicode)] = FontGlyph {
			advance = g.advance,
			index = u32(i) * NUM_STRIPES,
			bounds = g.bounds,
		}
	}

	stripes_to_copy := min(u32(len(stripes_slice)), MAX_STRIPES)
	if stripes_to_copy > 0 {
		mem.copy(vks.stripe_buffer_mapped, raw_data(stripe_bytes), int(stripes_to_copy) * size_of(Stripe))
	}

	curves_to_copy := min(curve_count, MAX_CURVES)
	if curves_to_copy > 0 {
		mem.copy(vks.curve_buffer_mapped, raw_data(curve_bytes), int(curves_to_copy) * 12)
		total_curves_loaded += curves_to_copy
	}

	font = glyphs
}

draw_text :: proc(text: string, pos: Vec2, font_size: f32, color := cast([4]Color)WHITE) {
	if text == "" do return

	x := pos.x
	y := pos.y

	for char in text {
		if char == '\n' {
			x = pos.x
			y += font_size
			continue
		}

		glyph := font[char] or_else font['?']

		dest := Rect {
			pos  = {x, y} + glyph.bounds.pos * font_size,
			size = {x, y} + glyph.bounds.size * font_size,
		}

		if rect_overlaps(dest, scissor) {
			append(&instances,
				Instance{
					dest   = dest,
					src    = glyph.bounds,
					color  = color,
					radius = 0,
					index  = glyph.index,
					kind   = .Text,
				},
			)
		}

		x += glyph.advance * font_size
	}
}

draw_text_rect :: proc(text: string, bounds: Rect, font_size: f32, color := cast([4]Color)WHITE, center_x := false, center_y := true) {
	if text == "" do return
	size := measure_text(text, font_size)
	x := bounds.pos.x + (center_x ? (bounds.size.x - size.x) * 0.5 : 0)
	y := bounds.pos.y + (center_y ? (bounds.size.y - font_size) * 0.5 : 0)
	draw_text(text, {x, y}, font_size, color)
}

draw_text_faded :: proc(text: string, bounds: Rect, font_size: f32, color: Color, center_y := true) {
	if text == "" || bounds.size.x <= 0 do return
	if !rect_visible(bounds) do return

	size := measure_text(text, font_size)
	if size.x <= bounds.size.x {
		draw_text_rect(text, bounds, font_size, color, false, center_y)
		return
	}

	x := bounds.pos.x
	y := bounds.pos.y + (center_y ? (bounds.size.y - font_size) * 0.5 : 0)

	max_w := bounds.size.x
	fade_w := min(20, max_w)
	fade_start := bounds.pos.x + max_w - fade_w

	for char in text {
		if char == '\n' {
			x = bounds.pos.x
			y += font_size
			continue
		}

		glyph := font[char] or_else font['?']

		left_x := x
		right_x := x + glyph.advance * font_size

		if left_x > bounds.pos.x + max_w {
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

		dest := Rect {
			pos  = {x, y} + glyph.bounds.pos * font_size,
			size = {x, y} + glyph.bounds.size * font_size,
		}

		if rect_overlaps(dest, scissor) {
			append(&instances,
				Instance{
					dest   = dest,
					src    = glyph.bounds,
					color  = c,
					radius = 0,
					index  = glyph.index,
					kind   = .Text,
				},
			)
		}

		x += glyph.advance * font_size
	}
}

measure_text :: proc(text: string, font_size: f32) -> (size: Vec2) {
	if text == "" do return

	cursor_x := f32(0)
	size.y = font_size

	for char in text {
		if char == '\n' {
			cursor_x = 0
			size.y += font_size
			continue
		}

		glyph := font[char] or_else font['?']
		cursor_x += glyph.advance * font_size
		size.x = max(size.x, cursor_x)
	}

	return
}