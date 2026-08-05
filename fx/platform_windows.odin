package fx

import "base:runtime"
import "core:time"
import "core:mem"
import "core:unicode/utf16"
import win "core:sys/windows"
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
	hInstance:      win.HINSTANCE,
	hwnd:           win.HWND,
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

init :: proc(title: string, size := [2]u32{1280, 720}) {
	win.SetProcessDPIAware()

	window.hInstance = cast(win.HINSTANCE)win.GetModuleHandleW(nil)
	wndclass := win.WNDCLASSW{
		lpfnWndProc   = window_proc,
		style         = win.CS_OWNDC,
		hInstance     = window.hInstance,
		hIcon         = win.LoadIconW(window.hInstance, cast(win.LPCWSTR)win.MAKEINTRESOURCEW(1)),
		hCursor       = win.LoadCursorA(nil, win.IDC_ARROW),
		hbrBackground = cast(win.HBRUSH)win.GetStockObject(win.BLACK_BRUSH),
		lpszClassName = "GriPlayer",
	}

	win.RegisterClassW(&wndclass)

	window_rect: win.RECT = {
		right  = i32(size.x),
		bottom = i32(size.y),
	}

	dw_style := win.WS_OVERLAPPEDWINDOW | win.WS_CLIPCHILDREN
	ex_style := win.WS_EX_APPWINDOW
	win.AdjustWindowRectEx(&window_rect, dw_style, false, ex_style)

	window_w := window_rect.right - window_rect.left
	window_h := window_rect.bottom - window_rect.top

	xpos := (win.GetSystemMetrics(win.SM_CXSCREEN) - window_w) / 2
	ypos := (win.GetSystemMetrics(win.SM_CYSCREEN) - window_h) / 2

	title16 := win.utf8_to_wstring(title, context.temp_allocator)
	window.hwnd = win.CreateWindowExW(ex_style, "GriPlayer", title16, dw_style, xpos, ypos, window_w, window_h, nil, nil, window.hInstance, nil)

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
	window.mouse_pos = {-1, -1}
	window.size = size

	value := win.TRUE
	win.DwmSetWindowAttribute(window.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &value, size_of(value))
	win.RegisterHotKey(window.hwnd, 1, 0, win.VK_MEDIA_NEXT_TRACK)
	win.RegisterHotKey(window.hwnd, 2, 0, win.VK_MEDIA_PREV_TRACK)
	win.RegisterHotKey(window.hwnd, 3, 0, win.VK_MEDIA_PLAY_PAUSE)
	win.ShowWindow(window.hwnd, win.SW_SHOW)
	win.UpdateWindow(window.hwnd)

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
	return f32(win.GetDpiForWindow(window.hwnd)) / f32(96.0)
}

window_size :: proc() -> Vec2 {
	return Vec2(window.size) / dpi_scale()
}

window_is_minimized :: proc() -> bool {
	return cast(bool)win.IsIconic(window.hwnd)
}

text_input :: proc() -> []rune {
	return window.text_input[:]
}

get_clipboard :: proc(allocator := context.temp_allocator) -> (text: string, ok: bool) {
	win.OpenClipboard(window.hwnd) or_return
	defer win.CloseClipboard()

	handle := win.GetClipboardData(win.CF_UNICODETEXT)
	(handle != nil) or_return

	global := win.HGLOBAL(handle)

	ptr := win.GlobalLock(global)
	(ptr != nil) or_return
	defer win.GlobalUnlock(global)

	str, err := win.wstring_to_utf8(win.wstring(ptr), -1, allocator)
	(err == nil) or_return

	return str, true
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

set_always_on_top :: proc(top: bool) {
	insert_after := top ? win.HWND_TOPMOST : win.HWND_NOTOPMOST
	win.SetWindowPos(window.hwnd, insert_after, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE)
}

get_window_rect :: proc() -> Vec4 {
	rect: win.RECT
	win.GetWindowRect(window.hwnd, &rect)
	scale := dpi_scale()
	return Vec4 {
		f32(rect.left),
		f32(rect.top),
		f32(rect.right - rect.left) / scale,
		f32(rect.bottom - rect.top) / scale
	}
}

set_window_rect :: proc(rect: Vec4) {
	x := i32(rect.x)
	y := i32(rect.y)
	dw_style := cast(win.DWORD)win.GetWindowLongW(window.hwnd, win.GWL_STYLE)
	ex_style := cast(win.DWORD)win.GetWindowLongW(window.hwnd, win.GWL_EXSTYLE)

	scale := dpi_scale()
	window_rect: win.RECT = {
		x,
		y,
		x + cast(i32)(rect.z * scale),
		y + cast(i32)(rect.w * scale),
	}
	win.AdjustWindowRectEx(&window_rect, dw_style, false, ex_style)

	new_w := window_rect.right - window_rect.left
	new_h := window_rect.bottom - window_rect.top
	win.SetWindowPos(window.hwnd, nil, x, y, new_w, new_h, win.SWP_NOZORDER)
}

start_window_drag :: proc() {
	if win.GetAsyncKeyState(win.VK_LBUTTON) >= 0 {
		return
	}
	win.ReleaseCapture()
	window.key_state[Key.Mouse_Left] = {}
	win.SendMessageW(window.hwnd, win.WM_NCLBUTTONDOWN, win.HTCAPTION, 0)
}

set_window_borderless :: proc(borderless: bool) {
	style := cast(win.DWORD)win.GetWindowLongW(window.hwnd, win.GWL_STYLE)
	if borderless {
		style &= ~(win.WS_CAPTION | win.WS_THICKFRAME | win.WS_MINIMIZEBOX | win.WS_MAXIMIZEBOX | win.WS_SYSMENU)
		style |= win.WS_POPUP
	} else {
		style &= ~(win.WS_POPUP)
		style |= win.WS_OVERLAPPEDWINDOW
	}
	win.SetWindowLongW(window.hwnd, win.GWL_STYLE, cast(win.LONG)style)
	win.SetWindowPos(window.hwnd, nil, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_FRAMECHANGED)
}

update :: proc(poll_msg := true) {
	window.mouse_scroll = {0, 0}
	clear(&window.text_input)

	for &state in window.key_state {
		state -= {.Pressed, .Released, .Repeat}
	}

	if poll_msg {
		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
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

	clear(&instances)
	clear(&batches)
}

run :: proc(cb: proc()) {
	window.frame_callback = cb

	for !window.should_close {
		update()
	}
}

window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()

	result := win.LRESULT(0)

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
			case .Arrow:   hc = win.LoadCursorA(nil, win.IDC_ARROW)
			case .Hand:    hc = win.LoadCursorA(nil, win.IDC_HAND)
			case .IBeam:   hc = win.LoadCursorA(nil, win.IDC_IBEAM)
			case .SizeAll: hc = win.LoadCursorA(nil, win.IDC_SIZEALL)
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
		if wparam == 1 do update(false)

	case win.WM_SIZE:
		window.size.x = cast(u32)win.LOWORD(lparam)
		window.size.y = cast(u32)win.HIWORD(lparam)
		window.is_resized = true

	case win.WM_SETFOCUS:
	case win.WM_KILLFOCUS:
		for vkcode in Key {
			window.key_state[vkcode] = {}
		}

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

	case win.WM_MOUSEMOVE:
		x := win.GET_X_LPARAM(lparam)
		y := win.GET_Y_LPARAM(lparam)
		window.mouse_pos = {f32(x), f32(y)} / dpi_scale()

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
		vkcode := cast(Key)wparam

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

	case win.WM_CHAR:
	    @(static) high_surrogate: rune
	    w := rune(wparam)

	    switch w {
	    case 0xD800..=0xDBFF:
	        high_surrogate = w
	        break
	    case 0xDC00..=0xDFFF:
	        if high_surrogate == 0 {
	            break
	        }

	        codepoint := utf16.decode_surrogate_pair(high_surrogate, w)
	        high_surrogate = 0

	        if codepoint >= 32 && codepoint != 127 {
	            append(&window.text_input, codepoint)
	        }
	    case:
	        high_surrogate = 0

	        if w >= 32 && w != 127 {
	            append(&window.text_input, w)
	        }
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

vk_get_required_instance_extensions :: proc(allocator := context.temp_allocator) -> []cstring {
	exts := make([]cstring, 2, allocator)
	exts[0] = vk.KHR_SURFACE_EXTENSION_NAME
	exts[1] = vk.KHR_WIN32_SURFACE_EXTENSION_NAME
	return exts
}

vk_create_surface :: proc(instance: vk.Instance) -> vk.SurfaceKHR {
	surface: vk.SurfaceKHR
	surface_create_info := vk.Win32SurfaceCreateInfoKHR {
		sType = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = window.hInstance,
		hwnd = window.hwnd,
	}
	vk.CreateWin32SurfaceKHR(instance, &surface_create_info, nil, &surface)
	return surface
}