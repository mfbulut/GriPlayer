package fx

import "base:runtime"

import "core:mem"
import "core:time"
import "core:unicode"
import "core:unicode/utf16"

import win "core:sys/windows"

Cursor :: enum {
	Arrow,
	Hand,
	IBeam,
	SizeNS,
	SizeWE,
	SizeAll,
}

Key_States :: bit_set[enum { Held, Pressed, Released, Repeat }]

window: struct {
	hwnd:           win.HWND,
	size:      		[2]i32,
	is_resized:     bool,
	should_close:   bool,
	key_state:      [256]Key_States,
	text_input:     [dynamic]rune,
	cursor:       	Cursor,
	mouse_pos: 		Vec2,
	mouse_scroll:   Vec2,
	prev_time:      time.Time,
	frame_time:     f32,
	frame_callback: proc(),
}

init :: proc(title: string, size := [2]i32{1280, 720}) {
	win.SetProcessDPIAware()

	hInstance := cast(win.HINSTANCE)win.GetModuleHandleW(nil)
	wndclass := win.WNDCLASSW {
		lpfnWndProc   = window_proc,
		style         = win.CS_VREDRAW | win.CS_HREDRAW | win.CS_OWNDC,
		hInstance     = hInstance,
		hIcon         = win.LoadIconW(hInstance, cast(win.LPCWSTR)win.MAKEINTRESOURCEW(1)),
		hCursor       = win.LoadCursorA(nil, win.IDC_ARROW),
		hbrBackground = cast(win.HBRUSH)win.GetStockObject(win.BLACK_BRUSH),
		lpszClassName = "fMusic",
	}

	win.RegisterClassW(&wndclass)

	window_rect: win.RECT = {
		right  = size.x,
		bottom = size.y,
	}

	dw_style := win.WS_OVERLAPPEDWINDOW
	ex_style := win.WS_EX_APPWINDOW
	win.AdjustWindowRectEx(&window_rect, dw_style, false, ex_style)

	window_w := window_rect.right - window_rect.left
	window_h := window_rect.bottom - window_rect.top

	xpos := (win.GetSystemMetrics(win.SM_CXSCREEN) - window_w) / 2
	ypos := (win.GetSystemMetrics(win.SM_CYSCREEN) - window_h) / 2

	title16 := win.utf8_to_wstring(title, context.temp_allocator)
	window.hwnd = win.CreateWindowExW(ex_style, "fMusic", title16, dw_style, xpos, ypos, window_w, window_h, nil, nil, hInstance, nil)

	scale := dpi_scale()
	if scale != 1.0 {
		scaled_rect: win.RECT = {
			right  = cast(i32)(f32(size.x) * scale),
			bottom = cast(i32)(f32(size.y) * scale),
		}
		win.AdjustWindowRectEx(&scaled_rect, dw_style, false, ex_style)
		new_w := scaled_rect.right - scaled_rect.left
		new_h := scaled_rect.bottom - scaled_rect.top
		new_x := (win.GetSystemMetrics(win.SM_CXSCREEN) - new_w) / 2
		new_y := (win.GetSystemMetrics(win.SM_CYSCREEN) - new_h) / 2
		win.SetWindowPos(window.hwnd, nil, new_x, new_y, new_w, new_h, win.SWP_NOZORDER)
	}

	window.prev_time = time.now()
	window.mouse_pos = mouse_pos()

	value := win.TRUE
	win.DwmSetWindowAttribute(window.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &value, size_of(value))
	win.RegisterHotKey(window.hwnd, 1, 0, win.VK_MEDIA_NEXT_TRACK)
	win.RegisterHotKey(window.hwnd, 2, 0, win.VK_MEDIA_PREV_TRACK)
	win.RegisterHotKey(window.hwnd, 3, 0, win.VK_MEDIA_PLAY_PAUSE)
	win.ShowWindow(window.hwnd, win.SW_SHOW)
	win.UpdateWindow(window.hwnd)

	d3d11_initialize()
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

text_input :: proc() -> []rune {
	return window.text_input[:]
}

set_cursor :: proc(cursor: Cursor) {
	window.cursor = cursor
}

set_frame_callback :: proc(cb: proc()) {
	window.frame_callback = cb
}

dpi_scale :: proc() -> f32 {
	return f32(win.GetDpiForWindow(window.hwnd)) / f32(96.0)
}

window_size_pixels :: proc() -> Vec2 {
	return Vec2(window.size)
}

window_size :: proc() -> Vec2 {
	return Vec2(window.size) / dpi_scale()
}

window_is_minimized :: proc() -> bool {
	return cast(bool)win.IsIconic(window.hwnd)
}

get_clipboard :: proc(allocator := context.temp_allocator) -> (text: string, ok: bool) {
	win.OpenClipboard(window.hwnd) or_return
	defer win.CloseClipboard()

	win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) or_return

	handle := win.GetClipboardData(win.CF_UNICODETEXT)
	(handle != nil) or_return

	global := win.HGLOBAL(handle)

	ptr := win.GlobalLock(global)
	(ptr != nil) or_return
	defer win.GlobalUnlock(global)

	str_utf8, allocator_err := win.wstring_to_utf8(win.wstring(ptr), -1, allocator)
	(allocator_err == nil) or_return

	return str_utf8, true
}

set_clipboard :: proc(text: string) -> (ok: bool) {
	win.OpenClipboard(window.hwnd) or_return
	defer win.CloseClipboard()

	text := win.utf8_to_utf16(text, context.temp_allocator)
	(text != nil) or_return

	data := win.GlobalAlloc(win.GMEM_MOVEABLE, len(text) * size_of(win.WCHAR) + 2)
	(data != nil) or_return
	defer if !ok {win.GlobalFree(data)}

	{
		data := cast([^]byte)win.GlobalLock(win.HGLOBAL(data))
		(data != nil) or_return
		defer win.GlobalUnlock(win.HGLOBAL(data))
		mem.copy_non_overlapping(data, raw_data(text), len(text) * size_of(win.WCHAR))
		data[len(text) * size_of(win.WCHAR) + 0] = 0
		data[len(text) * size_of(win.WCHAR) + 1] = 0
	}

	ret := win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(data))
	(ret != nil) or_return

	return true
}

update :: proc(poll_msg := true) -> bool {
	if poll_msg {
		if !window_is_minimized() {
			win.WaitForSingleObject(d3d11_state.swapchain.waitable_handle, win.INFINITE)
		}
	}

	for &state in window.key_state {
		state -= {.Pressed, .Released, .Repeat}
	}

	p: win.POINT
	if win.GetCursorPos(&p) {
		win.ScreenToClient(window.hwnd, &p)
	}
	window.mouse_pos = {f32(p.x), f32(p.y)} / dpi_scale()
	window.mouse_scroll = {0, 0}
	window.is_resized = false
	clear(&window.text_input)

	cur_time := time.now()
	window.frame_time = cast(f32)time.duration_seconds(time.diff(window.prev_time, cur_time))
	window.prev_time = cur_time

	if poll_msg {
		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
	}

	window.cursor = .Arrow

	begin_frame()

	return !window.should_close
}

window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()

	result := win.LRESULT(0)
	if window.hwnd == nil || window.hwnd != hwnd {
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	switch msg {
	case win.WM_DESTROY:
	case win.WM_CLOSE:
		window.should_close = true

	case win.WM_HOTKEY:
		if wparam == 1 {window.key_state[Key.Next_Track] += {.Pressed, .Held, .Repeat}}
		if wparam == 2 {window.key_state[Key.Prev_Track] += {.Pressed, .Held, .Repeat}}
		if wparam == 3 {window.key_state[Key.Play_Pause] += {.Pressed, .Held, .Repeat}}

	case win.WM_SETCURSOR:
		if (lparam & 0xFFFF) == 1 {
			hc: win.HCURSOR
			switch window.cursor {
			case .Arrow:
				hc = win.LoadCursorA(nil, win.IDC_ARROW)
			case .Hand:
				hc = win.LoadCursorA(nil, win.IDC_HAND)
			case .IBeam:
				hc = win.LoadCursorA(nil, win.IDC_IBEAM)
			case .SizeNS:
				hc = win.LoadCursorA(nil, win.IDC_SIZENS)
			case .SizeWE:
				hc = win.LoadCursorA(nil, win.IDC_SIZEWE)
			case .SizeAll:
				hc = win.LoadCursorA(nil, win.IDC_SIZEALL)
			}
			win.SetCursor(hc)
			result = 1
		} else {
			result = win.DefWindowProcW(hwnd, msg, wparam, lparam)
		}

	case win.WM_ENTERSIZEMOVE:
		win.SetTimer(hwnd, 1, 10, nil)
	case win.WM_EXITSIZEMOVE:
		win.KillTimer(hwnd, 1)
	case win.WM_TIMER:
		if wparam == 1 && window.frame_callback != nil {
			update(false)
			window.frame_callback()
		}

	case win.WM_SIZE:
		window.size.x = cast(i32)win.LOWORD(lparam)
		window.size.y = cast(i32)win.HIWORD(lparam)
		window.is_resized = true
	case win.WM_SETFOCUS:
	case win.WM_KILLFOCUS:
		for vkcode in Key {
			window.key_state[vkcode] = {}
		}

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		win.BeginPaint(hwnd, &ps)
		win.EndPaint(hwnd, &ps)

	case win.WM_LBUTTONUP:
		update_button(.Mouse_Left, false)
		win.ReleaseCapture()
	case win.WM_LBUTTONDOWN:
		update_button(.Mouse_Left, true)
		win.SetCapture(hwnd)
	case win.WM_MBUTTONUP:
		update_button(.Mouse_Middle, false)
		win.ReleaseCapture()
	case win.WM_MBUTTONDOWN:
		update_button(.Mouse_Middle, true)
		win.SetCapture(hwnd)
	case win.WM_RBUTTONUP:
		update_button(.Mouse_Right, false)
		win.ReleaseCapture()
	case win.WM_RBUTTONDOWN:
		update_button(.Mouse_Right, true)
		win.SetCapture(hwnd)

	case win.WM_MOUSEWHEEL:
		vert_scroll := cast(f32)win.GET_WHEEL_DELTA_WPARAM(wparam) / win.WHEEL_DELTA
		window.mouse_scroll.y += vert_scroll
	case win.WM_MOUSEHWHEEL:
		horz_scroll := cast(f32)win.GET_WHEEL_DELTA_WPARAM(wparam) / win.WHEEL_DELTA
		window.mouse_scroll.x += horz_scroll

	case win.WM_SYSKEYDOWN:
		if wparam == win.VK_F4 {
			window.should_close = true
			break
		}
		if wparam != win.VK_MENU && (wparam < win.VK_F1 || wparam > win.VK_F24) {
			result = win.DefWindowProcW(hwnd, msg, wparam, lparam)
		}
		fallthrough
	case win.WM_SYSKEYUP, win.WM_KEYUP, win.WM_KEYDOWN:
		is_down := (lparam & (1 << 31)) == 0
		vkcode := cast(Key) wparam

		if vkcode != .Null {
			was_down := .Held in window.key_state[vkcode]
			if is_down {
				window.key_state[vkcode] += {.Held, .Repeat}
				if !was_down {
					window.key_state[vkcode] += {.Pressed}
				}
			} else {
				if was_down {
					window.key_state[vkcode] -= {.Held}
					window.key_state[vkcode] += {.Released}
				}
			}
		}

	case win.WM_SYSCHAR:
		result = win.DefWindowProcW(hwnd, msg, wparam, lparam)
	case win.WM_CHAR:
		@(static) high_surrogate: rune
		w := cast(rune)wparam

		is_high_surrogate := (w >= 0xD800 && w <= 0xDBFF)
		is_low_surrogate := (w >= 0xDC00 && w <= 0xDFFF)

		codepoint := unicode.REPLACEMENT_CHAR
		if is_high_surrogate {
			high_surrogate = w
			break
		} else if is_low_surrogate {
			if high_surrogate != 0 {
				codepoint = utf16.decode_surrogate_pair(high_surrogate, w)
				high_surrogate = 0
			} else {
				break
			}
		} else {
			codepoint = w
			high_surrogate = 0
		}

		if codepoint == unicode.REPLACEMENT_CHAR {
			break
		}

		if unicode.is_graphic(codepoint) {
			append(&window.text_input, codepoint)
		}

	case:
		result = win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	return result
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

Key :: enum u8 {
	Null = 0,
	Mouse_Left   = 0x01,
	Mouse_Right  = 0x02,
	Mouse_Middle = 0x04,

	N0 = '0',
	N1 = '1',
	N2 = '2',
	N3 = '3',
	N4 = '4',
	N5 = '5',
	N6 = '6',
	N7 = '7',
	N8 = '8',
	N9 = '9',

	A = 'A',
	B = 'B',
	C = 'C',
	D = 'D',
	E = 'E',
	F = 'F',
	G = 'G',
	H = 'H',
	I = 'I',
	J = 'J',
	K = 'K',
	L = 'L',
	M = 'M',
	N = 'N',
	O = 'O',
	P = 'P',
	Q = 'Q',
	R = 'R',
	S = 'S',
	T = 'T',
	U = 'U',
	V = 'V',
	W = 'W',
	X = 'X',
	Y = 'Y',
	Z = 'Z',

	Backspace = 0x08,
	Tab       = 0x09,
	Enter     = 0x0D,
	Shift     = 0x10,
	Ctrl      = 0x11,
	Alt       = 0x12,
	Esc       = 0x1B,
	Space     = 0x20,

	End   = 0x23,
	Home  = 0x24,
	Left  = 0x25,
	Up    = 0x26,
	Right = 0x27,
	Down  = 0x28,
	Delete    = 0x2E,

	Left_Super    = 0x5B,
	Right_Super   = 0x5C,

	P0 = 0x60,
	P1 = 0x61,
	P2 = 0x62,
	P3 = 0x63,
	P4 = 0x64,
	P5 = 0x65,
	P6 = 0x66,
	P7 = 0x67,
	P8 = 0x68,
	P9 = 0x69,

	NumStar       = 0x6A,
	NumPlus       = 0x6B,
	NumMinus      = 0x6D,
	NumPeriod     = 0x6E,
	NumSlash      = 0x6F,

	F1  = 0x70,
	F2  = 0x71,
	F3  = 0x72,
	F4  = 0x73,
	F5  = 0x74,
	F6  = 0x75,
	F7  = 0x76,
	F8  = 0x77,
	F9  = 0x78,
	F10 = 0x79,
	F11 = 0x7A,
	F12 = 0x7B,
	F13 = 0x7C,
	F14 = 0x7D,
	F15 = 0x7E,
	F16 = 0x7F,
	F17 = 0x80,
	F18 = 0x81,
	F19 = 0x82,
	F20 = 0x83,

	Left_Shift    = 0xA0,
	Right_Shift   = 0xA1,
	Left_Ctrl     = 0xA2,
	Right_Ctrl    = 0xA3,
	Left_Alt      = 0xA4,
	Right_Alt     = 0xA5,

	Next_Track = 0xB0,
	Prev_Track = 0xB1,
	Play_Pause = 0xB3,

	Semicolon = 0xBA,
	Equal     = 0xBB,
	Comma     = 0xBC,
	Minus     = 0xBD,
	Period    = 0xBE,
	Slash     = 0xBF,
	Backtick  = 0xC0,

	PageUp   = 0x21,
	PageDown = 0x22,

	LeftBracket  = 0xDB,
	RightBracket = 0xDD,
	BackSlash     = 0xDC,
	Quote         = 0xDE,
}