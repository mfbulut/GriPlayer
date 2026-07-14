package fx

import "base:runtime"

import win "core:sys/windows"

text_box_init :: proc(placeholder := "") {
	if window.text_box.hwnd != nil do return

	hinstance := cast(win.HINSTANCE)win.GetModuleHandleW(nil)
	style := win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_LEFT | win.ES_AUTOHSCROLL
	window.text_box.hwnd = win.CreateWindowExW(0, win.WC_EDIT, "", style, 0, 0, 0, 0, window.hwnd, nil, hinstance, nil)
	assert(window.text_box.hwnd != nil, "Failed to create native Windows text box")
	window.text_box.visible = true

	scale := dpi_scale()
	window.text_box.font = win.CreateFontW(-cast(i32)(16 * scale), 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH | win.FF_DONTCARE, "Segoe UI")
	win.SendMessageW(window.text_box.hwnd, win.WM_SETFONT, cast(win.WPARAM)window.text_box.font, 1)
	win.SendMessageW(window.text_box.hwnd, win.EM_SETMARGINS, 0x0003, 0)
	win.SetWindowTheme(window.text_box.hwnd, "", "")
	win.SetWindowSubclass(window.text_box.hwnd, text_box_window_proc, 1, 0)

	if placeholder != "" {
		placeholder_w := win.utf8_to_wstring(placeholder, context.temp_allocator)
		win.SendMessageW(window.text_box.hwnd, win.EM_SETCUEBANNER, 0, cast(win.LPARAM)uintptr(rawptr(placeholder_w)))
	}

	text_box_set_colors({242, 239, 232, 255}, {12, 14, 18, 255})
}

text_box_set_visible :: proc(visible: bool) {
	if window.text_box.hwnd == nil || window.text_box.visible == visible do return
	if !visible do text_box_blur()
	window.text_box.visible = visible
	win.ShowWindow(window.text_box.hwnd, visible ? win.SW_SHOWNA : win.SW_HIDE)
}

text_box_set_rect :: proc(rect: Rect) {
	if window.text_box.hwnd == nil do return
	scale := dpi_scale()
	physical_rect := [4]i32 {
		cast(i32)(rect.x * scale),
		cast(i32)(rect.y * scale),
		max(cast(i32)(rect.w * scale), 0),
		max(cast(i32)(rect.h * scale), 0),
	}
	if physical_rect == window.text_box.rect do return
	window.text_box.rect = physical_rect
	win.SetWindowPos(
		window.text_box.hwnd,
		win.HWND_TOP,
		physical_rect[0],
		physical_rect[1],
		physical_rect[2],
		physical_rect[3],
		win.SWP_NOACTIVATE,
	)
}

text_box_set_colors :: proc(text, background: Color) {
	if window.text_box.hwnd == nil do return

	text_color := color_ref(text)
	background_color := color_ref(background)
	if window.text_box.text_color == text_color &&
	   window.text_box.background_color == background_color &&
	   window.text_box.brush != nil {
		return
	}

	if window.text_box.brush != nil {
		win.DeleteObject(win.HGDIOBJ(window.text_box.brush))
	}
	window.text_box.text_color = text_color
	window.text_box.background_color = background_color
	window.text_box.brush = win.CreateSolidBrush(background_color)
	win.InvalidateRect(window.text_box.hwnd, nil, true)
}

text_box_text :: proc(allocator := context.temp_allocator) -> string {
	if window.text_box.hwnd == nil do return ""

	length := int(win.GetWindowTextLengthW(window.text_box.hwnd))
	text_w := make([]u16, length + 1, allocator)
	if length > 0 {
		win.GetWindowTextW(window.text_box.hwnd, raw_data(text_w), cast(i32)len(text_w))
	}
	text, err := win.utf16_to_utf8(text_w[:length], allocator)
	if err != nil do return ""
	return text
}

text_box_set_text :: proc(text: string) {
	if window.text_box.hwnd == nil do return
	text_w := win.utf8_to_wstring(text, context.temp_allocator)
	win.SetWindowTextW(window.text_box.hwnd, text_w)
}

text_box_focus :: proc(select_all := false) {
	if window.text_box.hwnd == nil do return
	win.SetFocus(window.text_box.hwnd)
	if select_all {
		win.SendMessageW(window.text_box.hwnd, win.EM_SETSEL, 0, -1)
	}
}

text_box_blur :: proc() {
	if text_box_is_focused() {
		win.SetFocus(window.hwnd)
	}
}

text_box_is_focused :: proc() -> bool {
	return window.text_box.hwnd != nil && win.GetFocus() == window.text_box.hwnd
}

text_box_enter_pressed :: proc() -> bool {
	return window.text_box.enter_pressed
}

text_box_escape_pressed :: proc() -> bool {
	return window.text_box.escape_pressed
}

text_box_backspace_on_empty :: proc() -> bool {
	return window.text_box.backspace_on_empty
}

color_ref :: proc(color: Color) -> win.COLORREF {
	return win.COLORREF(color.r) | win.COLORREF(color.g) << 8 | win.COLORREF(color.b) << 16
}

text_box_window_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	subclass_id: win.UINT_PTR,
	ref_data: win.DWORD_PTR,
) -> win.LRESULT {
	context = runtime.default_context()

	if msg == win.WM_KEYDOWN {
		switch wparam {
		case win.VK_RETURN:
			window.text_box.enter_pressed = true
			return 0
		case win.VK_ESCAPE:
			window.text_box.escape_pressed = true
			return 0
		case win.VK_BACK:
			window.text_box.backspace_on_empty = win.GetWindowTextLengthW(hwnd) == 0
		}
	}

	return win.DefSubclassProc(hwnd, msg, wparam, lparam)
}
