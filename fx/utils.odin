package fx

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
	return {
		u8(clamp(f32(c.r) * factor, 0, 255)),
		u8(clamp(f32(c.g) * factor, 0, 255)),
		u8(clamp(f32(c.b) * factor, 0, 255)),
		c.a
	}
}

color_opacity :: proc "contextless" (c: Color, alpha: f32) -> Color {
	return {c.r, c.g, c.b, u8(clamp(alpha, 0, 1) * 255)}
}

Rect :: struct {
	x, y, w, h: f32,
}

point_in_rect :: proc(point: Vec2, rect: Rect) -> bool {
	return 	point.x >= rect.x && point.x < rect.x + rect.w && point.y >= rect.y && point.y < rect.y + rect.h
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