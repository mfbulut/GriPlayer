package textbox

import "base:runtime"

import win "core:sys/windows"

Color :: [4]u8

Event :: enum {
	Enter,
	Escape,
	Backspace_On_Empty,
}

state: struct {
	parent:           win.HWND,
	hwnd:             win.HWND,
	font:             win.HFONT,
	brush:            win.HBRUSH,
	text_color:       win.COLORREF,
	background_color: win.COLORREF,
	events:           [Event]bool,
	hovered:          bool,
	visible:          bool,
	bounds:           [4]i32,
}

init :: proc(parent: win.HWND, font_size: f32, placeholder := "") {
	if state.hwnd != nil || parent == nil do return

	state.parent = parent
	hinstance := cast(win.HINSTANCE)win.GetModuleHandleW(nil)
	style := win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_LEFT | win.ES_AUTOHSCROLL
	state.hwnd = win.CreateWindowExW(0, win.WC_EDIT, "", style, 0, 0, 0, 0, parent, nil, hinstance, nil)
	if state.hwnd == nil {
		state.parent = nil
		return
	}
	state.visible = true

	scale := f32(win.GetDpiForWindow(parent)) / 96.0
	font_height := max(cast(i32)(font_size * scale), 1)
	state.font = win.CreateFontW(
		-font_height,
		0,
		0,
		0,
		win.FW_NORMAL,
		0,
		0,
		0,
		win.DEFAULT_CHARSET,
		win.OUT_DEFAULT_PRECIS,
		win.CLIP_DEFAULT_PRECIS,
		win.CLEARTYPE_QUALITY,
		win.DEFAULT_PITCH | win.FF_DONTCARE,
		"Segoe UI",
	)

	win.SendMessageW(state.hwnd, win.WM_SETFONT, cast(win.WPARAM)state.font, 1)
	win.SendMessageW(state.hwnd, win.EM_SETMARGINS, 0x0003, 0)
	win.SetWindowTheme(state.hwnd, "", "")
	win.SetWindowSubclass(state.hwnd, child_window_proc, win.UINT_PTR(1), 0)
	win.SetWindowSubclass(parent, parent_window_proc, win.UINT_PTR(2), 0)

	if placeholder != "" {
		placeholder_w := win.utf8_to_wstring(placeholder, context.temp_allocator)
		win.SendMessageW(state.hwnd, win.EM_SETCUEBANNER, 1, cast(win.LPARAM)uintptr(rawptr(placeholder_w)))
	}

	set_colors({242, 239, 232, 255}, {12, 14, 18, 255})
}

set_visible :: proc(visible: bool) {
	if state.hwnd == nil || state.visible == visible do return
	if !visible {
		blur()
		state.hovered = false
		state.events = {}
	}
	state.visible = visible
	win.ShowWindow(state.hwnd, visible ? win.SW_SHOWNA : win.SW_HIDE)
}

set_bounds :: proc(x, y, width, height: f32) {
	if state.hwnd == nil do return
	scale := f32(win.GetDpiForWindow(state.parent)) / 96.0
	bounds := [4]i32 {
		cast(i32)(x * scale),
		cast(i32)(y * scale),
		max(cast(i32)(width * scale), 0),
		max(cast(i32)(height * scale), 0),
	}
	if bounds == state.bounds do return
	state.bounds = bounds
	win.SetWindowPos(
		state.hwnd,
		win.HWND_TOP,
		bounds[0],
		bounds[1],
		bounds[2],
		bounds[3],
		win.SWP_NOACTIVATE,
	)
}

set_colors :: proc(text_color, background_color: Color) {
	if state.hwnd == nil do return

	// Zero alpha channel
	text_rgb, background_rgb: Color
	text_rgb.rgb = text_color.rgb
	background_rgb.rgb = background_color.rgb
	text_ref := transmute(win.COLORREF)text_rgb
	background_ref := transmute(win.COLORREF)background_rgb

	if state.text_color == text_ref && state.background_color == background_ref && state.brush != nil {
		return
	}

	if state.brush != nil do win.DeleteObject(win.HGDIOBJ(state.brush))
	state.text_color = text_ref
	state.background_color = background_ref
	state.brush = win.CreateSolidBrush(background_ref)
	win.InvalidateRect(state.hwnd, nil, true)
}

text :: proc(allocator := context.temp_allocator) -> string {
	if state.hwnd == nil do return ""

	length := int(win.GetWindowTextLengthW(state.hwnd))
	text_w := make([]u16, length + 1, allocator)
	if length > 0 {
		win.GetWindowTextW(state.hwnd, raw_data(text_w), cast(i32)len(text_w))
	}
	value, err := win.utf16_to_utf8(text_w[:length], allocator)
	if err != nil do return ""
	return value
}

set_text :: proc(value: string) {
	if state.hwnd == nil do return
	value_w := win.utf8_to_wstring(value, context.temp_allocator)
	win.SetWindowTextW(state.hwnd, value_w)
}

focus :: proc() {
	if state.hwnd != nil do win.SetFocus(state.hwnd)
}

blur :: proc() {
	if focused() do win.SetFocus(state.parent)
}

focused :: proc() -> bool {
	return state.hwnd != nil && win.GetFocus() == state.hwnd
}

hovered :: proc() -> bool {
	return state.hwnd != nil && state.visible && state.hovered
}

pressed :: proc(event: Event) -> bool {
	result := state.events[event]
	state.events[event] = false
	return result
}

delete_previous_word :: proc(hwnd: win.HWND) {
	selection_start, selection_end: u32
	win.SendMessageW(hwnd, win.EM_GETSEL, uintptr(&selection_start), cast(int)uintptr(&selection_end))
	if selection_start != selection_end {
		win.SendMessageW(hwnd, win.WM_CLEAR, 0, 0)
		return
	}

	caret := int(selection_start)
	if caret <= 0 do return
	length := int(win.GetWindowTextLengthW(hwnd))
	value := make([]u16, length + 1, context.temp_allocator)
	win.GetWindowTextW(hwnd, raw_data(value), cast(i32)len(value))

	delete_start := min(caret, length)
	for delete_start > 0 && (value[delete_start - 1] == ' ' || value[delete_start - 1] == '\t') {
		delete_start -= 1
	}
	for delete_start > 0 && value[delete_start - 1] != ' ' && value[delete_start - 1] != '\t' {
		delete_start -= 1
	}

	win.SendMessageW(hwnd, win.EM_SETSEL, cast(uintptr)delete_start, caret)
	win.SendMessageW(hwnd, win.WM_CLEAR, 0, 0)
}

parent_window_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	subclass_id: win.UINT_PTR,
	ref_data: win.DWORD_PTR,
) -> win.LRESULT {
	context = runtime.default_context()

	if msg == win.WM_CTLCOLOREDIT && cast(win.HWND)uintptr(lparam) == state.hwnd {
		hdc := cast(win.HDC)wparam
		win.SetTextColor(hdc, state.text_color)
		win.SetBkColor(hdc, state.background_color)
		win.SetBkMode(hdc, .OPAQUE)
		return cast(win.LRESULT)uintptr(state.brush)
	}

	return win.DefSubclassProc(hwnd, msg, wparam, lparam)
}

child_window_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	subclass_id: win.UINT_PTR,
	ref_data: win.DWORD_PTR,
) -> win.LRESULT {
	context = runtime.default_context()

	switch msg {
	case win.WM_SETCURSOR:
		win.SetCursor(win.LoadCursorA(nil, win.IDC_IBEAM))
		return 1

	case win.WM_MOUSEMOVE:
		if !state.hovered {
			state.hovered = true
			track := win.TRACKMOUSEEVENT {
				cbSize = size_of(win.TRACKMOUSEEVENT),
				dwFlags = win.TME_LEAVE,
				hwndTrack = hwnd,
			}
			win.TrackMouseEvent(&track)
		}

	case win.WM_MOUSELEAVE:
		state.hovered = false

	case win.WM_CHAR:
		if wparam == 0x01 || wparam == 0x7f || wparam == win.VK_ESCAPE || wparam == win.VK_RETURN {
			return 0
		}

	case win.WM_KEYDOWN:
		ctrl_down := (cast(u16)win.GetKeyState(win.VK_CONTROL) & 0x8000) != 0
		alt_down := (cast(u16)win.GetKeyState(win.VK_MENU) & 0x8000) != 0
		shortcut_down := ctrl_down && !alt_down
		switch wparam {
		case win.VK_A:
			if shortcut_down {
				win.SendMessageW(hwnd, win.EM_SETSEL, 0, -1)
				return 0
			}
		case win.VK_RETURN:
			state.events[.Enter] = true
			return 0
		case win.VK_ESCAPE:
			state.events[.Escape] = true
			return 0
		case win.VK_BACK:
			state.events[.Backspace_On_Empty] = win.GetWindowTextLengthW(hwnd) == 0
			if shortcut_down {
				delete_previous_word(hwnd)
				return 0
			}
		}
	}

	return win.DefSubclassProc(hwnd, msg, wparam, lparam)
}
