package fx

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Color :: [4]byte

Rect :: struct {
	x, y, w, h: f32,
}

LIGHTGRAY  :: Color{200, 200, 200, 255}
GRAY       :: Color{130, 130, 130, 255}
DARKGRAY   :: Color{80, 80, 80, 255}
YELLOW     :: Color{253, 249, 0, 255}
GOLD       :: Color{255, 203, 0, 255}
ORANGE     :: Color{255, 161, 0, 255}
PINK       :: Color{255, 109, 194, 255}
RED        :: Color{230, 41, 55, 255}
MAROON     :: Color{190, 33, 55, 255}
GREEN      :: Color{0, 228, 48, 255}
LIME       :: Color{0, 158, 47, 255}
DARKGREEN  :: Color{0, 117, 44, 255}
SKYBLUE    :: Color{102, 191, 255, 255}
BLUE       :: Color{0, 121, 241, 255}
DARKBLUE   :: Color{0, 82, 172, 255}
PURPLE     :: Color{200, 122, 255, 255}
VIOLET     :: Color{135, 60, 190, 255}
DARKPURPLE :: Color{112, 31, 126, 255}
BEIGE      :: Color{211, 176, 131, 255}
BROWN      :: Color{127, 106, 79, 255}
DARKBROWN  :: Color{76, 63, 47, 255}

WHITE      :: Color{255, 255, 255, 255}
BLACK      :: Color{0, 0, 0, 255}
BLANK      :: Color{0, 0, 0, 0}
MAGENTA    :: Color{255, 0, 255, 255}

color_to_vec4 :: #force_inline proc(c: Color) -> [4]f32 {
	return cast([4]f32)c * (1.0 / 255.0)
}

vec4_to_color :: #force_inline proc(v: [4]f32) -> Color {
	return Color(linalg.clamp(v, 0.0, 1.0) * 255.0)
}

color_lerp :: proc(a, b: Color, t: f32) -> Color {
	return vec4_to_color(linalg.lerp(color_to_vec4(a), color_to_vec4(b), t))
}

color_brightness :: proc(c: Color, factor: f32) -> Color {
	return vec4_to_color(color_to_vec4(c) * factor)
}

color_opacity :: proc(c: Color, alpha: f32) -> Color {
	return {c.r, c.g, c.b, u8(clamp(alpha, 0, 1) * 255)}
}

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

color_to_oklch :: proc(color: Color) -> (l, c, h: f32) {
	srgb   := color_to_vec4(color).rgb
	linear := linalg.vector3_srgb_to_linear(srgb)

	lms := LINEAR_SRGB_TO_LINEAR_LMS * linear
	lms  = {math.cbrt(lms.x), math.cbrt(lms.y), math.cbrt(lms.z)}

	oklab := LINEAR_LMS_TO_OKLAB * lms

	l = oklab.x
	c = math.hypot(oklab.y, oklab.z)
	h = c > 1e-6 ? math.atan2(oklab.z, oklab.y) : 0.0
	return
}

point_in_rect :: proc(p: Vec2, r: Rect) -> bool {
	return 	p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

rect_overlaps :: proc(a, b: Rect) -> bool {
	return a.x < b.x + b.w &&
	       a.x + a.w > b.x &&
	       a.y < b.y + b.h &&
	       a.y + a.h > b.y
}

rect_overlap :: proc(a, b: Rect) -> Rect {
	x1 := max(a.x, b.x)
	y1 := max(a.y, b.y)
	x2 := min(a.x + a.w, b.x + b.w)
	y2 := min(a.y + a.h, b.y + b.h)
	return {x1, y1, max(0, x2 - x1), max(0, y2 - y1)}
}

rect_shrink :: proc(r: Rect, x: f32, y: f32) -> Rect {
	return {r.x + x, r.y + y, r.w - x * 2, r.h - y * 2}
}

rect_expand :: proc(r: Rect, x: f32, y: f32) -> Rect {
	return {r.x - x, r.y - y, r.w + x * 2, r.h + y * 2}
}
