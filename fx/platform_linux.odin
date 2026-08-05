package fx

import "base:runtime"
import "core:c"
import "core:time"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

Cursor :: enum {
	Arrow,
	Hand,
	IBeam,
	SizeAll,
}

Key_State :: enum { Held, Pressed, Released, Repeat }
Key_States :: [256]bit_set[Key_State]

window: struct {
	handle:         glfw.WindowHandle,
	size:           [2]u32,
	is_resized:     bool,
	should_close:   bool,
	key_state:      Key_States,
	cursor:         Cursor,
	mouse_pos:      Vec2,
	mouse_scroll:   Vec2,
	text_input:     [dynamic; 32]rune,
	prev_time:      time.Time,
	frame_time:     f32,
	frame_callback: proc(),
}

cursors: [Cursor]glfw.CursorHandle

init :: proc(title: string, size := [2]u32{1280, 720}) {
	if !glfw.Init() {
		panic("Failed to initialize GLFW")
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

	title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
	window.handle = glfw.CreateWindow(c.int(size.x), c.int(size.y), title_cstr, nil, nil)
	window.prev_time = time.now()
	window.mouse_pos = {-1, -1}

	glfw.SetKeyCallback(window.handle, key_callback)
	glfw.SetMouseButtonCallback(window.handle, mouse_button_callback)
	glfw.SetCursorPosCallback(window.handle, cursor_pos_callback)
	glfw.SetScrollCallback(window.handle, scroll_callback)
	glfw.SetCharCallback(window.handle, char_callback)
	glfw.SetFramebufferSizeCallback(window.handle, framebuffer_size_callback)
	w, h := glfw.GetFramebufferSize(window.handle)
	window.size = {u32(w), u32(h)}

	cursors[.Arrow]   = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
	cursors[.Hand]    = glfw.CreateStandardCursor(glfw.POINTING_HAND_CURSOR)
	cursors[.IBeam]   = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
	cursors[.SizeAll] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)

	vk_init()
	renderer_init()
}

mouse_pos :: proc() -> Vec2 {
	return window.mouse_pos
}

mouse_scroll :: proc() -> Vec2 {
	return window.mouse_scroll
}

key_is_down :: proc(key: Key) -> bool {
	return .Held in window.key_state[key]
}

key_is_pressed :: proc(key: Key) -> bool {
	return .Pressed in window.key_state[key]
}

key_is_released :: proc(key: Key) -> bool {
	return .Released in window.key_state[key]
}

key_is_pressed_repeat :: proc(key: Key) -> bool {
	return .Repeat in window.key_state[key]
}

frame_time :: proc() -> f32 {
	return min(window.frame_time, 1.0 / 60.0)
}

set_cursor :: proc(cursor: Cursor) {
	window.cursor = cursor
}

dpi_scale :: proc() -> f32 {
	if window.handle == nil do return 1.0
	xscale, _ := glfw.GetWindowContentScale(window.handle)
	return max(xscale, 1.0)
}

window_size :: proc() -> Vec2 {
	return Vec2(window.size) / dpi_scale()
}

window_is_minimized :: proc() -> bool {
	return glfw.GetWindowAttrib(window.handle, glfw.ICONIFIED) != 0
}

text_input :: proc() -> []rune {
	return window.text_input[:]
}

get_clipboard :: proc(allocator := context.temp_allocator) -> (text: string, ok: bool) {
	str := glfw.GetClipboardString(window.handle)
	if len(str) > 0 {
		return strings.clone(str, allocator), true
	}
	return
}

set_clipboard :: proc(text: string) -> (ok: bool) {
	text_cstr := strings.clone_to_cstring(text, context.temp_allocator)
	glfw.SetClipboardString(window.handle, text_cstr)
	return true
}

set_always_on_top :: proc(top: bool) {
	glfw.SetWindowAttrib(window.handle, glfw.FLOATING, top ? glfw.TRUE : glfw.FALSE)
}

get_window_rect :: proc() -> Vec4 {
	xpos, ypos := glfw.GetWindowPos(window.handle)
	w, h := glfw.GetWindowSize(window.handle)
	scale := dpi_scale()
	return Vec4 {
		f32(xpos),
		f32(ypos),
		f32(w) / scale,
		f32(h) / scale,
	}
}

set_window_rect :: proc(rect: Vec4) {
	scale := dpi_scale()
	glfw.SetWindowPos(window.handle, c.int(rect.x), c.int(rect.y))
	glfw.SetWindowSize(window.handle, c.int(rect.z * scale), c.int(rect.w * scale))
}

start_window_drag :: proc() {
	window.key_state[Key.Mouse_Left] = {}
}

set_window_borderless :: proc(borderless: bool) {
	glfw.SetWindowAttrib(window.handle, glfw.DECORATED, borderless ? glfw.FALSE : glfw.TRUE)
}

update :: proc(poll_msg := true) {
	window.mouse_scroll = {0, 0}
	clear(&window.text_input)

	for &state in window.key_state {
		state -= {.Pressed, .Released, .Repeat}
	}

	if poll_msg {
		glfw.PollEvents()
	}

	if glfw.WindowShouldClose(window.handle) {
		window.should_close = true
	}

	cur_time := time.now()
	window.frame_time = cast(f32)time.duration_seconds(time.diff(window.prev_time, cur_time))
	window.prev_time = cur_time
	window.cursor = .Arrow

	if window.frame_callback != nil {
		window.frame_callback()
	}

	flush()

	if window.size.x > 0 && window.size.y > 0 {
		if window.is_resized {
			vk_recreate_swapchain()
			window.is_resized = false
		}

		vk_render()
	}

	if cursors[window.cursor] != nil {
		glfw.SetCursor(window.handle, cursors[window.cursor])
	}

	clear(&instances)
	clear(&batches)
}

run :: proc(cb: proc()) {
	window.frame_callback = cb

	for !window.should_close {
		update()
	}

	glfw.Terminate()
}

vk_get_required_instance_extensions :: proc(allocator := context.temp_allocator) -> []cstring {
	return glfw.GetRequiredInstanceExtensions()
}

vk_create_surface :: proc(instance: vk.Instance) -> vk.SurfaceKHR {
	surface: vk.SurfaceKHR
	res := glfw.CreateWindowSurface(instance, window.handle, nil, &surface)
	if res != .SUCCESS {
		panic("Failed to create window surface")
	}
	return surface
}

glfw_key_to_key :: proc(key: c.int) -> (Key, bool) {
	switch key {
	case glfw.KEY_0..=glfw.KEY_9: return cast(Key)('0' + u8(key - glfw.KEY_0)), true
	case glfw.KEY_A..=glfw.KEY_Z: return cast(Key)('A' + u8(key - glfw.KEY_A)), true
	case glfw.KEY_BACKSPACE:    return .Backspace, true
	case glfw.KEY_TAB:          return .Tab, true
	case glfw.KEY_ENTER:        return .Enter, true
	case glfw.KEY_ESCAPE:       return .Esc, true
	case glfw.KEY_SPACE:        return .Space, true
	case glfw.KEY_END:          return .End, true
	case glfw.KEY_HOME:         return .Home, true
	case glfw.KEY_LEFT:         return .Left, true
	case glfw.KEY_UP:           return .Up, true
	case glfw.KEY_RIGHT:        return .Right, true
	case glfw.KEY_DOWN:         return .Down, true
	case glfw.KEY_DELETE:       return .Delete, true
	case glfw.KEY_PAGE_UP:      return .PageUp, true
	case glfw.KEY_PAGE_DOWN:    return .PageDown, true
	case glfw.KEY_LEFT_SUPER:   return .Left_Super, true
	case glfw.KEY_RIGHT_SUPER:  return .Right_Super, true
	case glfw.KEY_KP_0..=glfw.KEY_KP_9: return cast(Key)(u8(Key.P0) + u8(key - glfw.KEY_KP_0)), true
	case glfw.KEY_KP_MULTIPLY: return .NumStar, true
	case glfw.KEY_KP_ADD:      return .NumPlus, true
	case glfw.KEY_KP_SUBTRACT: return .NumMinus, true
	case glfw.KEY_KP_DECIMAL:  return .NumPeriod, true
	case glfw.KEY_KP_DIVIDE:   return .NumSlash, true
	case glfw.KEY_F1..=glfw.KEY_F20: return cast(Key)(u8(Key.F1) + u8(key - glfw.KEY_F1)), true
	case glfw.KEY_LEFT_SHIFT:   return .Left_Shift, true
	case glfw.KEY_RIGHT_SHIFT:  return .Right_Shift, true
	case glfw.KEY_LEFT_CONTROL: return .Left_Ctrl, true
	case glfw.KEY_RIGHT_CONTROL:return .Right_Ctrl, true
	case glfw.KEY_LEFT_ALT:     return .Left_Alt, true
	case glfw.KEY_RIGHT_ALT:    return .Right_Alt, true
	case glfw.KEY_SEMICOLON:    return .Semicolon, true
	case glfw.KEY_EQUAL:        return .Equal, true
	case glfw.KEY_COMMA:        return .Comma, true
	case glfw.KEY_MINUS:        return .Minus, true
	case glfw.KEY_PERIOD:       return .Period, true
	case glfw.KEY_SLASH:        return .Slash, true
	case glfw.KEY_GRAVE_ACCENT: return .Backtick, true
	case glfw.KEY_LEFT_BRACKET: return .LeftBracket, true
	case glfw.KEY_RIGHT_BRACKET:return .RightBracket, true
	case glfw.KEY_BACKSLASH:    return .BackSlash, true
	case glfw.KEY_APOSTROPHE:   return .Quote, true
	}
	return .Null, false
}

key_callback :: proc "c" (window_handle: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	context = runtime.default_context()

	k, ok := glfw_key_to_key(key)
	if !ok do return

	if action == glfw.PRESS {
		was_down := .Held in window.key_state[k]
		window.key_state[k] += {.Held, .Repeat}
		if !was_down {
			window.key_state[k] += {.Pressed}
		}
		if k == .Left_Shift || k == .Right_Shift {
			was_shift := .Held in window.key_state[Key.Shift]
			window.key_state[Key.Shift] += {.Held, .Repeat}
			if !was_shift do window.key_state[Key.Shift] += {.Pressed}
		}
		if k == .Left_Ctrl || k == .Right_Ctrl {
			was_ctrl := .Held in window.key_state[Key.Ctrl]
			window.key_state[Key.Ctrl] += {.Held, .Repeat}
			if !was_ctrl do window.key_state[Key.Ctrl] += {.Pressed}
		}
		if k == .Left_Alt || k == .Right_Alt {
			was_alt := .Held in window.key_state[Key.Alt]
			window.key_state[Key.Alt] += {.Held, .Repeat}
			if !was_alt do window.key_state[Key.Alt] += {.Pressed}
		}
	} else if action == glfw.REPEAT {
		window.key_state[k] += {.Held, .Repeat}
		if k == .Left_Shift || k == .Right_Shift do window.key_state[Key.Shift] += {.Held, .Repeat}
		if k == .Left_Ctrl || k == .Right_Ctrl   do window.key_state[Key.Ctrl] += {.Held, .Repeat}
		if k == .Left_Alt || k == .Right_Alt     do window.key_state[Key.Alt] += {.Held, .Repeat}
	} else if action == glfw.RELEASE {
		was_down := .Held in window.key_state[k]
		if was_down {
			window.key_state[k] -= {.Held}
			window.key_state[k] += {.Released}
		}
		if k == .Left_Shift || k == .Right_Shift {
			if !key_is_down(.Left_Shift) && !key_is_down(.Right_Shift) {
				if .Held in window.key_state[Key.Shift] {
					window.key_state[Key.Shift] -= {.Held}
					window.key_state[Key.Shift] += {.Released}
				}
			}
		}
		if k == .Left_Ctrl || k == .Right_Ctrl {
			if !key_is_down(.Left_Ctrl) && !key_is_down(.Right_Ctrl) {
				if .Held in window.key_state[Key.Ctrl] {
					window.key_state[Key.Ctrl] -= {.Held}
					window.key_state[Key.Ctrl] += {.Released}
				}
			}
		}
		if k == .Left_Alt || k == .Right_Alt {
			if !key_is_down(.Left_Alt) && !key_is_down(.Right_Alt) {
				if .Held in window.key_state[Key.Alt] {
					window.key_state[Key.Alt] -= {.Held}
					window.key_state[Key.Alt] += {.Released}
				}
			}
		}
	}
}

update_button :: proc(button: Key, down_up: bool) {
	was_down := .Held in window.key_state[button]
	if was_down != down_up {
		if down_up {
			window.key_state[button] += {.Held, .Pressed}
		} else {
			window.key_state[button] -= {.Held}
			window.key_state[button] += {.Released}
		}
	}
}

mouse_button_callback :: proc "c" (window_handle: glfw.WindowHandle, button, action, mods: c.int) {
	context = runtime.default_context()
	k: Key
	switch button {
	case glfw.MOUSE_BUTTON_LEFT:   k = .Mouse_Left
	case glfw.MOUSE_BUTTON_RIGHT:  k = .Mouse_Right
	case glfw.MOUSE_BUTTON_MIDDLE: k = .Mouse_Middle
	case: return
	}
	update_button(k, action == glfw.PRESS)
}

cursor_pos_callback :: proc "c" (window_handle: glfw.WindowHandle, xpos, ypos: f64) {
	context = runtime.default_context()
	window.mouse_pos = {f32(xpos), f32(ypos)} / dpi_scale()
}

scroll_callback :: proc "c" (window_handle: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()
	window.mouse_scroll.x += f32(xoffset)
	window.mouse_scroll.y += f32(yoffset)
}

char_callback :: proc "c" (window_handle: glfw.WindowHandle, codepoint: rune) {
	context = runtime.default_context()
	if codepoint >= 32 && codepoint != 127 {
		append(&window.text_input, codepoint)
	}
}

framebuffer_size_callback :: proc "c" (window_handle: glfw.WindowHandle, width, height: c.int) {
	context = runtime.default_context()
	window.size.x = u32(width)
	window.size.y = u32(height)
	window.is_resized = true
}

Key :: enum u8 {
	Null          = 0,
	Mouse_Left    = 0x01,
	Mouse_Right   = 0x02,
	Mouse_Middle  = 0x04,

	N0 = '0', N1 = '1', N2 = '2', N3 = '3', N4 = '4',
	N5 = '5', N6 = '6', N7 = '7', N8 = '8', N9 = '9',

	A = 'A', B = 'B', C = 'C', D = 'D', E = 'E', F = 'F',
	G = 'G', H = 'H', I = 'I', J = 'J', K = 'K', L = 'L',
	M = 'M', N = 'N', O = 'O', P = 'P', Q = 'Q', R = 'R',
	S = 'S', T = 'T', U = 'U', V = 'V', W = 'W', X = 'X',
	Y = 'Y', Z = 'Z',

	Backspace     = 0x08,
	Tab           = 0x09,
	Enter         = 0x0D,
	Shift         = 0x10,
	Ctrl          = 0x11,
	Alt           = 0x12,
	Esc           = 0x1B,
	Space         = 0x20,

	End           = 0x23,
	Home          = 0x24,
	Left          = 0x25,
	Up            = 0x26,
	Right         = 0x27,
	Down          = 0x28,
	Delete        = 0x2E,

	Left_Super    = 0x5B,
	Right_Super   = 0x5C,

	P0 = 0x60, P1 = 0x61, P2 = 0x62, P3 = 0x63, P4 = 0x64,
	P5 = 0x65, P6 = 0x66, P7 = 0x67, P8 = 0x68, P9 = 0x69,

	NumStar   = 0x6A, NumPlus  = 0x6B, NumMinus = 0x6D,
	NumPeriod = 0x6E, NumSlash = 0x6F,

	F1  = 0x70, F2  = 0x71, F3  = 0x72, F4  = 0x73,
	F5  = 0x74, F6  = 0x75, F7  = 0x76, F8  = 0x77,
	F9  = 0x78, F10 = 0x79, F11 = 0x7A, F12 = 0x7B,
	F13 = 0x7C, F14 = 0x7D, F15 = 0x7E, F16 = 0x7F,
	F17 = 0x80, F18 = 0x81, F19 = 0x82, F20 = 0x83,

	Left_Shift  = 0xA0, Right_Shift = 0xA1,
	Left_Ctrl   = 0xA2, Right_Ctrl  = 0xA3,
	Left_Alt    = 0xA4, Right_Alt   = 0xA5,

	Next_Track  = 0xB0,
	Prev_Track  = 0xB1,
	Play_Pause  = 0xB3,

	Semicolon    = 0xBA, Equal        = 0xBB,
	Comma        = 0xBC, Minus        = 0xBD,
	Period       = 0xBE, Slash        = 0xBF,
	Backtick     = 0xC0,

	PageUp       = 0x21,
	PageDown     = 0x22,

	LeftBracket  = 0xDB, RightBracket = 0xDD,
	BackSlash    = 0xDC, Quote        = 0xDE,
}
