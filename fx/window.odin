package fx

import "base:runtime"

import "core:mem"
import "core:time"
import "core:unicode"
import "core:unicode/utf16"

import win "core:sys/windows"

window: struct {
	hwnd:                 win.HWND,
	frame_callback:       proc(),
	size_last_frame:      [2]i32,
	size_this_frame:      [2]i32,
	is_resized:           bool,
	btns_last_frame:      [Mouse_Button]bool,
	btns_this_frame:      [Mouse_Button]bool,
	btns_down_count:      i32,
	keys_last_frame:      [Key]bool,
	keys_this_frame:      [Key]bool,
	keys_pressed_repeat:  [Key]bool,
	should_close:         bool,
	mouse_scroll:         Vec2,
	mouse_pos_last_frame: Vec2,
	mouse_pos_this_frame: Vec2,
	text_input:           [dynamic]rune,
	current_cursor:       Cursor,
	time_start:           time.Time,
	time_last_frame:      time.Time,
	time_this_frame:      time.Time,
	frame_time:           f32,
	total_time:           f32,
}

Cursor :: enum {
	Arrow,
	Hand,
	IBeam,
	SizeNS,
	SizeWE,
	SizeAll,
}

dpi_scale :: proc() -> f32 {return f32(win.GetDpiForWindow(window.hwnd)) / f32(96.0)}
window_size_pixels :: proc() -> Vec2 {return Vec2(window.size_this_frame)}
window_size :: proc() -> Vec2 {return Vec2(window.size_this_frame) / dpi_scale()}
window_minimize :: proc() {win.ShowWindow(window.hwnd, win.SW_MINIMIZE)}
window_maximize :: proc() {win.ShowWindow(window.hwnd, win.SW_MAXIMIZE)}
window_restore :: proc() {win.ShowWindow(window.hwnd, win.SW_RESTORE)}
window_is_minimized :: proc() -> bool {return cast(bool)win.IsIconic(window.hwnd)}
window_is_maximized :: proc() -> bool {return cast(bool)win.IsZoomed(window.hwnd)}
window_is_focused :: proc() -> bool {return win.GetActiveWindow() == window.hwnd}
window_set_focus :: proc() {
	win.SetForegroundWindow(window.hwnd)
	win.SetFocus(window.hwnd)
}
window_set_title :: proc(title: string) {
	title16 := win.utf8_to_wstring(title, context.temp_allocator)
	win.SetWindowTextW(window.hwnd, title16)
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

	if win.RegisterClassW(&wndclass) == 0 {
		panic("[ERROR] Failed to registrate WNDCLASSW")
	}

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

	hwnd := win.CreateWindowExW(
		ex_style,
		"fMusic",
		title16,
		dw_style,
		xpos,
		ypos,
		window_w,
		window_h,
		nil,
		nil,
		hInstance,
		nil,
	)

	if hwnd == nil {
		panic("[ERROR] Failed to create HWND")
	}

	window.hwnd = hwnd

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
		win.SetWindowPos(hwnd, nil, new_x, new_y, new_w, new_h, win.SWP_NOZORDER)
	}

	r: win.RECT
	win.GetClientRect(hwnd, &r)
	client_w := r.right - r.left
	client_h := r.bottom - r.top

	window.hwnd = hwnd
	window.size_last_frame = {client_w, client_h}
	window.size_this_frame = {client_w, client_h}

	window.time_start = time.now()
	window.time_last_frame = window.time_start
	window.time_this_frame = window.time_start
	window.mouse_pos_this_frame = mouse_pos()
	window.mouse_pos_last_frame = window.mouse_pos_this_frame

	value: win.BOOL = true
	win.DwmSetWindowAttribute(hwnd, 20, &value, size_of(value))
	win.RegisterHotKey(hwnd, 1, 0, win.VK_MEDIA_NEXT_TRACK)
	win.RegisterHotKey(hwnd, 2, 0, win.VK_MEDIA_PREV_TRACK)
	win.RegisterHotKey(hwnd, 3, 0, win.VK_MEDIA_PLAY_PAUSE)

	win.ShowWindow(hwnd, win.SW_SHOW)
	win.UpdateWindow(hwnd)

	d3d11_initialize()
	renderer_initialize()
}

mouse_scroll :: proc() -> Vec2 {return window.mouse_scroll}
mouse_delta :: proc() -> Vec2 {return window.mouse_pos_this_frame - window.mouse_pos_last_frame}

mouse_pos :: proc() -> Vec2 {
	p: win.POINT
	if win.GetCursorPos(&p) {
		win.ScreenToClient(window.hwnd, &p)
	}
	return {f32(p.x), f32(p.y)} / dpi_scale()
}

mouse_is_down :: proc(btn: Mouse_Button) -> bool {
	return window.btns_this_frame[btn]
}
mouse_is_pressed :: proc(btn: Mouse_Button) -> bool {
	was_down := window.btns_last_frame[btn]
	is_down := window.btns_this_frame[btn]
	return is_down && !was_down
}
mouse_is_released :: proc(btn: Mouse_Button) -> bool {
	was_down := window.btns_last_frame[btn]
	is_down := window.btns_this_frame[btn]
	return !is_down && was_down
}

key_is_down :: proc(key: Key) -> bool {
	return window.keys_this_frame[key]
}
key_is_pressed :: proc(key: Key) -> bool {
	was_down := window.keys_last_frame[key]
	is_down := window.keys_this_frame[key]
	return is_down && !was_down
}
key_is_pressed_repeat :: proc(key: Key) -> bool {
	return window.keys_pressed_repeat[key]
}
key_is_released :: proc(key: Key) -> bool {
	was_down := window.keys_last_frame[key]
	is_down := window.keys_this_frame[key]
	return !is_down && was_down
}

frame_time :: proc() -> f32 {return min(window.frame_time, 1.0 / 60.0)}
total_time :: proc() -> f32 {return window.total_time}
text_input :: proc() -> []rune {return window.text_input[:]}

set_cursor :: proc(cursor: Cursor) {
	window.current_cursor = cursor
}

set_frame_callback :: proc(cb: proc()) {
	window.frame_callback = cb
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

update :: proc() -> bool {
	if !window_is_minimized() {
		win.WaitForSingleObject(d3d11_state.swapchain.waitable_handle, win.INFINITE)
	}

	for it in Mouse_Button {
		down_up := window.btns_this_frame[it]
		window.btns_last_frame[it] = down_up
	}
	for it in Key {
		down_up := window.keys_this_frame[it]
		window.keys_last_frame[it] = down_up
		window.keys_pressed_repeat[it] = false
	}

	clear(&window.text_input)
	window.is_resized = false
	window.mouse_scroll = {0, 0}

	window.mouse_pos_last_frame = window.mouse_pos_this_frame
	window.mouse_pos_this_frame = mouse_pos()

	window.time_last_frame = window.time_this_frame
	window.time_this_frame = time.now()
	window.frame_time = cast(f32)time.duration_seconds(
		time.diff(window.time_last_frame, window.time_this_frame),
	)
	window.total_time = cast(f32)time.duration_seconds(
		time.diff(window.time_start, window.time_this_frame),
	)

	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	window.current_cursor = .Arrow

	if window.should_close {
		return false
	}

	begin_frame()

	return true
}

present :: proc(sync := u32(1)) {
	flush_batch()
	d3d11_state.swapchain.swapchain1->Present(sync, nil)
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
		if wparam == 1 {window.keys_this_frame[.Next_Track] = true}
		if wparam == 2 {window.keys_this_frame[.Prev_Track] = true}
		if wparam == 3 {window.keys_this_frame[.Play_Pause] = true}

	case win.WM_SETCURSOR:
		if (lparam & 0xFFFF) == 1 {
			hc: win.HCURSOR
			switch window.current_cursor {
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
			window.time_last_frame = window.time_this_frame
			window.time_this_frame = time.now()
			window.frame_time = cast(f32)time.duration_seconds(
				time.diff(window.time_last_frame, window.time_this_frame),
			)
			window.total_time = cast(f32)time.duration_seconds(
				time.diff(window.time_start, window.time_this_frame),
			)
			begin_frame()
			window.frame_callback()
		}

	case win.WM_SIZE:
		window.size_this_frame.x = cast(i32)win.LOWORD(lparam)
		window.size_this_frame.y = cast(i32)win.HIWORD(lparam)
		if window.size_this_frame != window.size_last_frame {
			window.is_resized = true
			window.size_last_frame = window.size_this_frame
		}
	case win.WM_SETFOCUS:
	case win.WM_KILLFOCUS:
		for vkcode in Key {
			if window.keys_this_frame[vkcode] {
				window.keys_this_frame[vkcode] = false
			}
		}
		for button in Mouse_Button {
			if window.btns_this_frame[button] {
				update_button(button, false)
			}
		}
		window.btns_down_count = 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		win.BeginPaint(hwnd, &ps)
		win.EndPaint(hwnd, &ps)

	case win.WM_LBUTTONUP:
		update_button(.Left, false)
	case win.WM_LBUTTONDOWN:
		update_button(.Left, true)
	case win.WM_MBUTTONUP:
		update_button(.Middle, false)
	case win.WM_MBUTTONDOWN:
		update_button(.Middle, true)
	case win.WM_RBUTTONUP:
		update_button(.Right, false)
	case win.WM_RBUTTONDOWN:
		update_button(.Right, true)
	case win.WM_XBUTTONUP:
		update_button(win.HIWORD(wparam) == 1 ? .XButton1 : .XButton2, false)
		result = 1
	case win.WM_XBUTTONDOWN:
		update_button(win.HIWORD(wparam) == 1 ? .XButton1 : .XButton2, true)
		result = 1

	case win.WM_MOUSEWHEEL:
		vert_scroll := cast(f32)win.GET_WHEEL_DELTA_WPARAM(wparam) / f32(120.0)
		window.mouse_scroll.y += vert_scroll
	case win.WM_MOUSEHWHEEL:
		horz_scroll := cast(f32)win.GET_WHEEL_DELTA_WPARAM(wparam) / f32(120.0)
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
		vkcode := vkcode_to_key(cast(u32)wparam)

		if vkcode != .Null {
			window.keys_this_frame[vkcode] = is_down
			if is_down {
				window.keys_pressed_repeat[vkcode] = true
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

update_button :: proc(button: Mouse_Button, down_up: bool) {
	if window.btns_this_frame[button] != down_up {
		window.btns_this_frame[button] = down_up

		if down_up {
			if window.btns_down_count == 0 {
				win.SetCapture(window.hwnd)
			}
			window.btns_down_count += 1
		} else {
			window.btns_down_count -= 1
			if window.btns_down_count <= 0 && win.GetCapture() == window.hwnd {
				win.ReleaseCapture()
				window.btns_down_count = 0
			}
		}
	}
}

vkcode_to_key :: proc(vk: u32) -> Key {
	switch vk {
	case 'A':
		return .A
	case 'B':
		return .B
	case 'C':
		return .C
	case 'D':
		return .D
	case 'E':
		return .E
	case 'F':
		return .F
	case 'G':
		return .G
	case 'H':
		return .H
	case 'I':
		return .I
	case 'J':
		return .J
	case 'K':
		return .K
	case 'L':
		return .L
	case 'M':
		return .M
	case 'N':
		return .N
	case 'O':
		return .O
	case 'P':
		return .P
	case 'Q':
		return .Q
	case 'R':
		return .R
	case 'S':
		return .S
	case 'T':
		return .T
	case 'U':
		return .U
	case 'V':
		return .V
	case 'W':
		return .W
	case 'X':
		return .X
	case 'Y':
		return .Y
	case 'Z':
		return .Z
	case '0' ..= '9':
		return ._0 + cast(Key)(vk - '0')
	case win.VK_NUMPAD0 ..= win.VK_NUMPAD9:
		return .Num0 + cast(Key)(vk - win.VK_NUMPAD0)
	case win.VK_F1 ..= win.VK_F24:
		return .F1 + cast(Key)(vk - win.VK_F1)
	case win.VK_SPACE:
		return .Space
	case win.VK_OEM_3:
		return .Backtick
	case win.VK_OEM_MINUS:
		return .Minus
	case win.VK_OEM_PLUS:
		return .Equal
	case win.VK_OEM_4:
		return .LeftBracket
	case win.VK_OEM_6:
		return .RightBracket
	case win.VK_OEM_1:
		return .Semicolon
	case win.VK_OEM_7:
		return .Quote
	case win.VK_OEM_COMMA:
		return .Comma
	case win.VK_OEM_PERIOD:
		return .Period
	case win.VK_OEM_2:
		return .Slash
	case win.VK_OEM_5:
		return .BackSlash
	case win.VK_TAB:
		return .Tab
	case win.VK_PAUSE:
		return .Pause
	case win.VK_ESCAPE:
		return .Esc
	case win.VK_UP:
		return .Up
	case win.VK_LEFT:
		return .Left
	case win.VK_DOWN:
		return .Down
	case win.VK_RIGHT:
		return .Right
	case win.VK_BACK:
		return .Backspace
	case win.VK_RETURN:
		return .Enter
	case win.VK_DELETE:
		return .Delete
	case win.VK_INSERT:
		return .Insert
	case win.VK_PRIOR:
		return .PageUp
	case win.VK_NEXT:
		return .PageDown
	case win.VK_HOME:
		return .Home
	case win.VK_END:
		return .End
	case win.VK_CAPITAL:
		return .CapsLock
	case win.VK_NUMLOCK:
		return .NumLock
	case win.VK_LWIN, win.VK_RWIN:
		return .Super
	case win.VK_SCROLL:
		return .ScrollLock
	case win.VK_APPS:
		return .Menu
	case win.VK_CONTROL, win.VK_LCONTROL, win.VK_RCONTROL:
		return .Ctrl
	case win.VK_SHIFT, win.VK_LSHIFT, win.VK_RSHIFT:
		return .Shift
	case win.VK_MENU, win.VK_LMENU, win.VK_RMENU:
		return .Alt
	case win.VK_DIVIDE:
		return .NumSlash
	case win.VK_MULTIPLY:
		return .NumStar
	case win.VK_SUBTRACT:
		return .NumMinus
	case win.VK_ADD:
		return .NumPlus
	case win.VK_DECIMAL:
		return .NumPeriod
	case win.VK_MEDIA_NEXT_TRACK:
		return .Next_Track
	case win.VK_MEDIA_PREV_TRACK:
		return .Prev_Track
	case win.VK_MEDIA_PLAY_PAUSE:
		return .Play_Pause
	}
	return .Null
}

Mouse_Button :: enum {
	Left,
	Middle,
	Right,
	XButton1,
	XButton2,
}

Key :: enum u32 {
	Null = 0,
	Esc,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	Backtick,
	_0,
	_1,
	_2,
	_3,
	_4,
	_5,
	_6,
	_7,
	_8,
	_9,
	Minus,
	Equal,
	Backspace,
	Tab,
	Q,
	W,
	E,
	R,
	T,
	Y,
	U,
	I,
	O,
	P,
	LeftBracket,
	RightBracket,
	BackSlash,
	CapsLock,
	A,
	S,
	D,
	F,
	G,
	H,
	J,
	K,
	L,
	Semicolon,
	Quote,
	Enter,
	Shift,
	Z,
	X,
	C,
	V,
	B,
	N,
	M,
	Comma,
	Period,
	Slash,
	Ctrl,
	Alt,
	Space,
	Menu,
	Super,
	ScrollLock,
	Pause,
	Insert,
	Home,
	PageUp,
	Delete,
	End,
	PageDown,
	Up,
	Left,
	Down,
	Right,
	NumLock,
	NumSlash,
	NumStar,
	NumMinus,
	NumPlus,
	NumPeriod,
	Num0,
	Num1,
	Num2,
	Num3,
	Num4,
	Num5,
	Num6,
	Num7,
	Num8,
	Num9,
	Next_Track,
	Prev_Track,
	Play_Pause,
}
