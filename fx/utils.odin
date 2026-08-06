package fx

import "core:math"
import "core:math/linalg"

Vec2  :: [2]f32
Vec3  :: [3]f32
Vec4  :: [4]f32
Color :: [4]byte

Rect :: struct {
	pos, size: Vec2,
}

Bounds :: struct {
	left, bottom, right, top: f32,
}

WHITE := Color{255, 255, 255, 255}
BLACK := Color{0, 0, 0, 255}
BLANK := Color{0, 0, 0, 0}

color_to_vec4 :: #force_inline proc(c: Color) -> [4]f32 {
	return cast([4]f32)c * (1.0 / 255.0)
}

vec4_to_color :: #force_inline proc(v: [4]f32) -> Color {
	return Color(linalg.clamp(v, 0.0, 1.0) * 255.0)
}

color_lerp :: proc(a, b: Color, t: f32) -> Color {
	return vec4_to_color(linalg.lerp(color_to_vec4(a), color_to_vec4(b), t))
}

color_opacity :: proc(c: Color, alpha: f32) -> Color {
	return {c.r, c.g, c.b, u8(clamp(alpha, 0, 1) * 255)}
}

color_to_oklch :: proc(color: Color) -> (l, c, h: f32) {
	LINEAR_SRGB_TO_LINEAR_LMS :: #row_major matrix[3, 3]f32{
		0.4121764600, 0.5362739563, 0.0514403731,
		0.2119092047, 0.6807178855, 0.1073998436,
		0.0883448124, 0.2818539739, 0.6302808523,
	}

	LINEAR_LMS_TO_OKLAB :: #row_major matrix[3, 3]f32{
		0.2104542553,  0.7936177850, -0.0040720468,
		1.9779984951, -2.4285922050,  0.4505937099,
		0.0259040371,  0.7827717662, -0.8086757660,
	}

	srgb := color_to_vec4(color).rgb
	linear := linalg.vector3_srgb_to_linear(srgb)
	lms := LINEAR_SRGB_TO_LINEAR_LMS * linear
	lms = {math.cbrt(lms.x), math.cbrt(lms.y), math.cbrt(lms.z)}
	oklab := LINEAR_LMS_TO_OKLAB * lms
	l = oklab.x
	c = math.hypot(oklab.y, oklab.z)
	h = c > 1e-6 ? math.atan2(oklab.z, oklab.y) : 0.0
	return
}

point_in_rect :: proc(r: Rect, p: Vec2) -> bool {
	return p.x >= r.pos.x && p.x < r.pos.x + r.size.x && p.y >= r.pos.y && p.y < r.pos.y + r.size.y
}

rect_shrink :: proc(r: Rect, n: f32) -> Rect {
	return {r.pos + n, r.size - n * 2}
}

rect_expand :: proc(rect: Rect, n: f32) -> Rect {
	return {rect.pos - n, rect.size + n * 2}
}

rect_overlaps :: proc(a, b: Rect) -> bool {
	return a.pos.x < b.pos.x + b.size.x && a.pos.x + a.size.x > b.pos.x && a.pos.y < b.pos.y + b.size.y && a.pos.y + a.size.y > b.pos.y
}