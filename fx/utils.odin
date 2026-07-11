package fx

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Rectangle :: [4]f32
Color :: [4]byte

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

color_brightness :: proc "contextless" (c: Color, factor: f32) -> Color {
	return vec4_to_color(color_to_vec4(c) * factor)
}

color_opacity :: proc "contextless" (c: Color, alpha: f32) -> Color {
	return {c.r, c.g, c.b, u8(clamp(alpha, 0, 1) * 255)}
}

color_to_oklch :: proc(color: Color) -> (l, c, h: f32) {
	col_vec := color_to_vec4(color)
	linear := linalg.vector4_srgb_to_linear(col_vec)

	_l := math.pow(0.4122214708 * linear.r + 0.5363325363 * linear.g + 0.0514459929 * linear.b, 1.0 / 3.0)
	_m := math.pow(0.2119034982 * linear.r + 0.6806995451 * linear.g + 0.1073969566 * linear.b, 1.0 / 3.0)
	_s := math.pow(0.0883024619 * linear.r + 0.2817188376 * linear.g + 0.6299787005 * linear.b, 1.0 / 3.0)

	ok_l := 0.2104542553 * _l + 0.7936177850 * _m - 0.0040720468 * _s
	ok_a := 1.9779984951 * _l - 2.4285922050 * _m + 0.4505937099 * _s
	ok_b := 0.0259040371 * _l + 0.7827717662 * _m - 0.8086757660 * _s

	return ok_l, math.sqrt(ok_a * ok_a + ok_b * ok_b), math.atan2(ok_b, ok_a),
}

Rect :: struct {
	x, y, w, h: f32,
}

point_in_rect :: proc(p: Vec2, r: Rect) -> bool {
	return 	p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

rect_overlapping :: proc(a: Rect, b: Rect) -> bool {
	return  a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

rect_center :: proc(r: Rect) -> Vec2 {
	return { r.x + r.w/2, r.y + r.h/2 }
}

rect_shrink :: proc(r: Rect, x: f32, y: f32) -> Rect {
	return { r.x + x, r.y + y, r.w - x * 2, r.h - y * 2 }
}

rect_expand :: proc(r: Rect, x: f32, y: f32) -> Rect {
	return { r.x - x, r.y - y, r.w + x * 2, r.h + y * 2 }
}