#+build linux
package fx

import "core:strconv"
import "core:strings"
import "core:time"
import xlib "vendor:x11/xlib"

Key_State :: enum { Held, Pressed, Released, Repeat }

Cursor :: enum {
	Arrow,
	Hand,
	IBeam,
	SizeAll,
}

// vendor:x11/xlib covers the real Xlib ABI; only fill in the small gaps it
// doesn't bind (XGetDefault, XA_STRING, and XF86's multimedia keysyms, which
// live outside core X11/keysymdef.h).

XA_STRING :: xlib.Atom(31)

XF86XK_AudioNext :: xlib.KeySym(0x1008FF17)
XF86XK_AudioPrev :: xlib.KeySym(0x1008FF16)
XF86XK_AudioPlay :: xlib.KeySym(0x1008FF14)

foreign import x11 "system:X11"

@(default_calling_convention = "c")
foreign x11 {
	XGetDefault :: proc(display: ^xlib.Display, program, option: cstring) -> cstring ---
}

MotifWmHints :: struct {
	flags:       u64,
	functions:   u64,
	decorations: u64,
	input_mode:  i64,
	status:      u64,
}

MWM_HINTS_DECORATIONS :: u64(1 << 1)

// ---------------------------------------------------------------------------
// Window state
// ---------------------------------------------------------------------------

window: struct {
	display:            ^xlib.Display,
	win:                xlib.Window,
	screen:             i32,
	wm_delete:          xlib.Atom,
	net_wm_state:       xlib.Atom,
	net_wm_state_above: xlib.Atom,
	net_wm_state_hidden: xlib.Atom,
	net_wm_moveresize:  xlib.Atom,
	motif_wm_hints:     xlib.Atom,
	clipboard_atom:     xlib.Atom,
	utf8_string:        xlib.Atom,
	targets_atom:       xlib.Atom,
	clipboard_text:     string,
	dpi_scale:          f32,
	size:               [2]int,
	is_resized:         bool,
	should_close:       bool,
	key_state:          [256]bit_set[Key_State],
	mouse_pos:          Vec2,
	mouse_scroll:       Vec2,
	text_input:         [dynamic; 32]rune,
	prev_time:          time.Time,
	frame_time:         f32,
	frame_callback:     proc(),
	cursor:             Cursor,
}

cursor_handles: [Cursor]xlib.Cursor

init :: proc(title: string, size := [2]int{1280, 720}) {
	window.display = xlib.OpenDisplay(nil)
	if window.display == nil do panic("Failed to open X display (is a Linux desktop running?)")

	window.screen = xlib.DefaultScreen(window.display)
	root := xlib.RootWindow(window.display, window.screen)
	black := xlib.BlackPixel(window.display, window.screen)

	window.win = xlib.CreateSimpleWindow(window.display, root, 0, 0, u32(size.x), u32(size.y), 0, black, black)

	event_mask := xlib.EventMask{
		.KeyPress, .KeyRelease, .ButtonPress, .ButtonRelease,
		.PointerMotion, .StructureNotify, .FocusChange, .PropertyChange,
	}
	xlib.SelectInput(window.display, window.win, event_mask)

	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	xlib.StoreName(window.display, window.win, title_c)

	window.wm_delete = xlib.InternAtom(window.display, "WM_DELETE_WINDOW", false)
	protocols := window.wm_delete
	xlib.SetWMProtocols(window.display, window.win, &protocols, 1)

	window.net_wm_state        = xlib.InternAtom(window.display, "_NET_WM_STATE", false)
	window.net_wm_state_above  = xlib.InternAtom(window.display, "_NET_WM_STATE_ABOVE", false)
	window.net_wm_state_hidden = xlib.InternAtom(window.display, "_NET_WM_STATE_HIDDEN", false)
	window.net_wm_moveresize   = xlib.InternAtom(window.display, "_NET_WM_MOVERESIZE", false)
	window.motif_wm_hints      = xlib.InternAtom(window.display, "_MOTIF_WM_HINTS", false)
	window.clipboard_atom      = xlib.InternAtom(window.display, "CLIPBOARD", false)
	window.utf8_string         = xlib.InternAtom(window.display, "UTF8_STRING", false)
	window.targets_atom        = xlib.InternAtom(window.display, "TARGETS", false)

	cursor_handles[.Arrow]   = xlib.CreateFontCursor(window.display, .XC_left_ptr)
	cursor_handles[.Hand]    = xlib.CreateFontCursor(window.display, .XC_hand2)
	cursor_handles[.IBeam]   = xlib.CreateFontCursor(window.display, .XC_xterm)
	cursor_handles[.SizeAll] = xlib.CreateFontCursor(window.display, .XC_fleur)

	xlib.MapWindow(window.display, window.win)
	xlib.Flush(window.display)

	// Global media-key grab, X11's analogue of Win32's RegisterHotKey.
	for keysym in ([]xlib.KeySym{XF86XK_AudioNext, XF86XK_AudioPrev, XF86XK_AudioPlay}) {
		kc := i32(xlib.KeysymToKeycode(window.display, keysym))
		if kc != 0 {
			xlib.GrabKey(window.display, kc, {.AnyModifier}, root, true, .GrabModeAsync, .GrabModeAsync)
		}
	}

	window.dpi_scale = 1.0
	if dpi_cstr := XGetDefault(window.display, "Xft", "dpi"); dpi_cstr != nil {
		if val, ok := strconv.parse_f32(string(dpi_cstr)); ok && val > 0 {
			window.dpi_scale = val / 96.0
		}
	}

	window.prev_time = time.now()
	window.mouse_pos = {-1, -1}
	window.size = size

	vk_init()
	font_load(#load("../assets/fonts/SourceSans3-Medium.bin"))
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

dpi_scale :: proc() -> f32 {
	return window.dpi_scale
}

window_size :: proc() -> Vec2 {
	return Vec2(window.size) / dpi_scale()
}

// Polls _NET_WM_STATE on every call instead of caching it off PropertyNotify
// events. Cheap local round-trip; switch to event-driven caching if
// profiling ever shows this matters.
window_is_minimized :: proc() -> bool {
	actual_type: xlib.Atom
	actual_format: i32
	nitems, bytes_after: uint
	data: rawptr
	status := xlib.GetWindowProperty(window.display, window.win, window.net_wm_state, 0, 64, false, xlib.XA_ATOM, &actual_type, &actual_format, &nitems, &bytes_after, &data)
	if status != 0 || data == nil do return false
	defer xlib.Free(data)

	atoms := (cast([^]xlib.Atom)data)[:nitems]
	for a in atoms {
		if a == window.net_wm_state_hidden do return true
	}
	return false
}

text_input :: proc() -> []rune {
	return window.text_input[:]
}

set_cursor :: proc(c: Cursor) {
	window.cursor = c
}

get_window_rect :: proc() -> Vec4 {
	attrs: xlib.XWindowAttributes
	xlib.GetWindowAttributes(window.display, window.win, &attrs)
	root_x, root_y: i32
	child: xlib.Window
	xlib.TranslateCoordinates(window.display, window.win, xlib.RootWindow(window.display, window.screen), 0, 0, &root_x, &root_y, &child)
	scale := dpi_scale()
	return Vec4{f32(root_x), f32(root_y), f32(attrs.width) / scale, f32(attrs.height) / scale}
}

set_window_rect :: proc(rect: Vec4) {
	scale := dpi_scale()
	xlib.MoveResizeWindow(window.display, window.win, i32(rect.x), i32(rect.y), u32(rect.z * scale), u32(rect.w * scale))
}

// EWMH _NET_WM_STATE client message, the X11 analogue of SetWindowPos(HWND_TOPMOST).
set_always_on_top :: proc(top: bool) {
	root := xlib.RootWindow(window.display, window.screen)
	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = window.win
	ev.xclient.message_type = window.net_wm_state
	ev.xclient.format = 32
	ev.xclient.data.l[0] = top ? 1 : 0 // _NET_WM_STATE_ADD : _NET_WM_STATE_REMOVE
	ev.xclient.data.l[1] = int(window.net_wm_state_above)
	ev.xclient.data.l[2] = 0
	xlib.SendEvent(window.display, root, false, {.SubstructureNotify, .SubstructureRedirect}, &ev)
	xlib.Flush(window.display)
}

// EWMH _NET_WM_MOVERESIZE, the X11 analogue of the Win32 WM_NCLBUTTONDOWN/HTCAPTION drag trick.
start_window_drag :: proc() {
	root := xlib.RootWindow(window.display, window.screen)
	xlib.UngrabPointer(window.display, 0)

	win_rect := get_window_rect()
	scale := dpi_scale()
	root_x := int(win_rect.x + window.mouse_pos.x * scale)
	root_y := int(win_rect.y + window.mouse_pos.y * scale)

	ev: xlib.XEvent
	ev.xclient.type = .ClientMessage
	ev.xclient.window = window.win
	ev.xclient.message_type = window.net_wm_moveresize
	ev.xclient.format = 32
	ev.xclient.data.l[0] = root_x
	ev.xclient.data.l[1] = root_y
	ev.xclient.data.l[2] = 8 // _NET_WM_MOVERESIZE_MOVE
	ev.xclient.data.l[3] = 1 // button1
	ev.xclient.data.l[4] = 0
	xlib.SendEvent(window.display, root, false, {.SubstructureNotify, .SubstructureRedirect}, &ev)
	xlib.Flush(window.display)
}

set_window_borderless :: proc(borderless: bool) {
	hints := MotifWmHints{
		flags       = MWM_HINTS_DECORATIONS,
		decorations = borderless ? 0 : 1,
	}
	xlib.ChangeProperty(window.display, window.win, window.motif_wm_hints, window.motif_wm_hints, 32, xlib.PropModeReplace, &hints, 5)
}

// Single UTF8_STRING target only (no COMPOUND_TEXT fallback) — our editor
// only ever deals in plain UTF-8 text, so that's the real ceiling here.
get_clipboard :: proc(allocator := context.temp_allocator) -> (text: string, ok: bool) {
	owner := xlib.GetSelectionOwner(window.display, window.clipboard_atom)
	if owner == 0 do return "", false

	prop := xlib.InternAtom(window.display, "GRIPLAYER_CLIPBOARD", false)
	xlib.ConvertSelection(window.display, window.clipboard_atom, window.utf8_string, prop, window.win, 0)
	xlib.Flush(window.display)

	ev: xlib.XEvent
	got := false
	for _ in 0 ..< 200 {
		if xlib.CheckTypedEvent(window.display, .SelectionNotify, &ev) {
			got = true
			break
		}
		time.sleep(500 * time.Microsecond)
	}
	if !got || ev.xselection.property == 0 do return "", false

	actual_type: xlib.Atom
	actual_format: i32
	nitems, bytes_after: uint
	data: rawptr
	xlib.GetWindowProperty(window.display, window.win, prop, 0, 1 << 20, false, window.utf8_string, &actual_type, &actual_format, &nitems, &bytes_after, &data)
	if data == nil do return "", false
	defer xlib.Free(data)
	if nitems == 0 do return "", false

	bytes := (cast([^]byte)data)[:nitems]
	return strings.clone(string(bytes), allocator), true
}

set_clipboard :: proc(text: string) -> (ok: bool) {
	delete(window.clipboard_text)
	window.clipboard_text = strings.clone(text)
	xlib.SetSelectionOwner(window.display, window.clipboard_atom, window.win, 0)
	return xlib.GetSelectionOwner(window.display, window.clipboard_atom) == window.win
}

handle_selection_request :: proc(req: ^xlib.XSelectionRequestEvent) {
	resp: xlib.XEvent
	resp.xselection.type = .SelectionNotify
	resp.xselection.requestor = req.requestor
	resp.xselection.selection = req.selection
	resp.xselection.target = req.target
	resp.xselection.time = req.time
	resp.xselection.property = 0

	if req.target == window.utf8_string || req.target == XA_STRING {
		text_bytes := transmute([]byte)window.clipboard_text
		xlib.ChangeProperty(window.display, req.requestor, req.property, req.target, 8, xlib.PropModeReplace, raw_data(text_bytes), i32(len(text_bytes)))
		resp.xselection.property = req.property
	} else if req.target == window.targets_atom {
		targets := [2]xlib.Atom{window.utf8_string, XA_STRING}
		xlib.ChangeProperty(window.display, req.requestor, req.property, xlib.XA_ATOM, 32, xlib.PropModeReplace, &targets, 2)
		resp.xselection.property = req.property
	}

	xlib.SendEvent(window.display, req.requestor, false, {}, &resp)
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

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

// Latin-1 only via XLookupString, no XIM/XIC composition — covers the
// search box's normal use. Upgrade to Xutf8LookupString+XIC for full
// Unicode/CJK input if ever needed.
handle_key :: proc(e: ^xlib.XKeyEvent, is_down: bool) {
	buf: [8]byte
	keysym: xlib.KeySym
	n := xlib.LookupString(e, raw_data(buf[:]), i32(len(buf)), &keysym, nil)

	key := keysym_to_key(keysym)
	if key != .Null {
		was_down := .Held in window.key_state[key]
		if is_down {
			window.key_state[key] += {.Held, .Repeat}
			if !was_down do window.key_state[key] += {.Pressed}
		} else if was_down {
			window.key_state[key] -= {.Held}
			window.key_state[key] += {.Released}
		}
	}

	if is_down {
		for i in 0 ..< n {
			b := buf[i]
			if b >= 32 && b != 127 {
				append(&window.text_input, rune(b))
			}
		}
	}
}

handle_button :: proc(button: int, is_down: bool) {
	switch button {
	case 1: update_button(.Mouse_Left, is_down)
	case 2: update_button(.Mouse_Middle, is_down)
	case 3: update_button(.Mouse_Right, is_down)
	case 4: if is_down do window.mouse_scroll.y += 1
	case 5: if is_down do window.mouse_scroll.y -= 1
	case 6: if is_down do window.mouse_scroll.x -= 1
	case 7: if is_down do window.mouse_scroll.x += 1
	}
}

handle_event :: proc(event: ^xlib.XEvent) {
	#partial switch event.type {
	case .ClientMessage:
		if xlib.Atom(event.xclient.data.l[0]) == window.wm_delete {
			window.should_close = true
		}
	case .KeyPress:
		handle_key(&event.xkey, true)
	case .KeyRelease:
		handle_key(&event.xkey, false)
	case .ButtonPress:
		handle_button(int(event.xbutton.button), true)
	case .ButtonRelease:
		handle_button(int(event.xbutton.button), false)
	case .MotionNotify:
		window.mouse_pos = Vec2{f32(event.xmotion.x), f32(event.xmotion.y)} / dpi_scale()
	case .ConfigureNotify:
		new_size := [2]int{int(event.xconfigure.width), int(event.xconfigure.height)}
		if new_size != window.size {
			window.size = new_size
			window.is_resized = true
		}
	case .FocusOut:
		for &state in window.key_state {
			state = {}
		}
	case .SelectionRequest:
		handle_selection_request(&event.xselectionrequest)
	}
}

apply_cursor :: proc() {
	@(static) last: Cursor
	@(static) initialized: bool
	if initialized && window.cursor == last do return
	initialized = true
	last = window.cursor
	xlib.DefineCursor(window.display, window.win, cursor_handles[window.cursor])
}

update :: proc(poll_msg := true) {
	window.mouse_scroll = {0, 0}
	clear(&window.text_input)
	reset_scissor()

	for &state in window.key_state {
		state -= {.Pressed, .Released, .Repeat}
	}

	if poll_msg {
		for xlib.Pending(window.display) > 0 {
			event: xlib.XEvent
			xlib.NextEvent(window.display, &event)
			handle_event(&event)
		}
	}

	cur_time := time.now()
	window.frame_time = cast(f32)time.duration_seconds(time.diff(window.prev_time, cur_time))
	window.prev_time = cur_time
	window.cursor = .Arrow

	if window.frame_callback != nil {
		window.frame_callback()
	}

	apply_cursor()
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

// X11 keysyms live in a different numeric space than Win32 VK codes, so
// (unlike the Windows backend) this can't be a direct cast — needs an
// explicit table.
keysym_to_key :: proc(ks: xlib.KeySym) -> Key {
	v := uint(ks)

	switch {
	case v >= '0' && v <= '9': return Key(v)
	case v >= 'a' && v <= 'z': return Key(v - 0x20)
	case v >= 'A' && v <= 'Z': return Key(v)
	case v >= uint(xlib.KeySym.XK_F1) && v <= uint(xlib.KeySym.XK_F1) + 19:
		return Key(int(Key.F1) + int(v - uint(xlib.KeySym.XK_F1)))
	case v >= uint(xlib.KeySym.XK_KP_0) && v <= uint(xlib.KeySym.XK_KP_9):
		return Key(int(Key.P0) + int(v - uint(xlib.KeySym.XK_KP_0)))
	}

	#partial switch ks {
	case .XK_BackSpace: return .Backspace
	case .XK_Tab: return .Tab
	case .XK_Return: return .Enter
	case .XK_Escape: return .Esc
	case .XK_space: return .Space
	case .XK_Home: return .Home
	case .XK_Left: return .Left
	case .XK_Up: return .Up
	case .XK_Right: return .Right
	case .XK_Down: return .Down
	case .XK_Page_Up: return .PageUp
	case .XK_Page_Down: return .PageDown
	case .XK_End: return .End
	case .XK_Delete: return .Delete
	case .XK_Shift_L: return .Left_Shift
	case .XK_Shift_R: return .Right_Shift
	case .XK_Control_L: return .Left_Ctrl
	case .XK_Control_R: return .Right_Ctrl
	case .XK_Alt_L: return .Left_Alt
	case .XK_Alt_R: return .Right_Alt
	case .XK_Super_L: return .Left_Super
	case .XK_Super_R: return .Right_Super
	case .XK_KP_Multiply: return .NumStar
	case .XK_KP_Add: return .NumPlus
	case .XK_KP_Subtract: return .NumMinus
	case .XK_KP_Decimal: return .NumPeriod
	case .XK_KP_Divide: return .NumSlash
	case .XK_semicolon: return .Semicolon
	case .XK_equal: return .Equal
	case .XK_comma: return .Comma
	case .XK_minus: return .Minus
	case .XK_period: return .Period
	case .XK_slash: return .Slash
	case .XK_grave: return .Backtick
	case .XK_bracketleft: return .LeftBracket
	case .XK_backslash: return .BackSlash
	case .XK_bracketright: return .RightBracket
	case .XK_apostrophe: return .Quote
	case XF86XK_AudioNext: return .Next_Track
	case XF86XK_AudioPrev: return .Prev_Track
	case XF86XK_AudioPlay: return .Play_Pause
	}

	return .Null
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
