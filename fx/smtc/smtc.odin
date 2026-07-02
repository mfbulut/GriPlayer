package smtc

import "core:sys/windows"
import "core:unicode/utf16"

HSTRING :: distinct rawptr
EventRegistrationToken :: struct { value: i64 }

foreign import runtimeobject "system:runtimeobject.lib"
@(default_calling_convention="system")
foreign runtimeobject {
	WindowsCreateString :: proc(sourceString: [^]u16, length: u32, string: ^HSTRING) -> windows.HRESULT ---
	WindowsDeleteString :: proc(string: HSTRING) -> windows.HRESULT ---
	RoGetActivationFactory :: proc(activatableClassId: HSTRING, iid: ^windows.IID, factory: ^rawptr) -> windows.HRESULT ---
	RoInitialize :: proc(initType: i32) -> windows.HRESULT ---
}

foreign import shcore "system:Shcore.lib"
@(default_calling_convention="system")
foreign shcore {
    CreateRandomAccessStreamOverStream :: proc(stream: rawptr, options: i32, riid: ^windows.IID, ppv: ^rawptr) -> windows.HRESULT ---
}

foreign import shlwapi "system:Shlwapi.lib"
@(default_calling_convention="system")
foreign shlwapi {
    SHCreateMemStream :: proc(pInit: [^]u8, cbInit: u32) -> rawptr ---
}

IInspectable_UUID := &windows.IID{0xAF86E2E0, 0xB12D, 0x4C6A, {0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90}}
IInspectable :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using iinspectable_vtable: ^IInspectable_VTable,
}
IInspectable_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetIids: proc "system" (this: ^IInspectable, iidCount: ^u32, iids: ^^windows.IID) -> windows.HRESULT,
	GetRuntimeClassName: proc "system" (this: ^IInspectable, className: ^HSTRING) -> windows.HRESULT,
	GetTrustLevel: proc "system" (this: ^IInspectable, trustLevel: ^i32) -> windows.HRESULT,
}

ISystemMediaTransportControlsInterop_UUID := &windows.IID{0xddb0472d, 0xc911, 0x4a1f, {0x86, 0xd9, 0xdc, 0x3d, 0x71, 0xa9, 0x5f, 0x5a}}
ISystemMediaTransportControlsInterop :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using ismtc_interop_vtable: ^ISystemMediaTransportControlsInterop_VTable,
}
ISystemMediaTransportControlsInterop_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	GetForWindow: proc "system" (this: ^ISystemMediaTransportControlsInterop, appWindow: windows.HWND, riid: ^windows.IID, mediaTransportControl: ^^ISystemMediaTransportControls) -> windows.HRESULT,
}

MediaPlaybackStatus :: enum i32 {
	Closed = 0,
	Changing = 1,
	Stopped = 2,
	Playing = 3,
	Paused = 4,
}

ISystemMediaTransportControls_UUID := &windows.IID{0x99FA3FF4, 0x1742, 0x42A6, {0x90, 0x2E, 0x08, 0x7D, 0x41, 0xF9, 0x65, 0xEC}}
ISystemMediaTransportControls :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using ismtc_vtable: ^ISystemMediaTransportControls_VTable,
}
ISystemMediaTransportControls_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	get_PlaybackStatus: proc "system" (this: ^ISystemMediaTransportControls, value: ^MediaPlaybackStatus) -> windows.HRESULT,
	put_PlaybackStatus: proc "system" (this: ^ISystemMediaTransportControls, value: MediaPlaybackStatus) -> windows.HRESULT,
	get_DisplayUpdater: proc "system" (this: ^ISystemMediaTransportControls, value: ^^ISystemMediaTransportControlsDisplayUpdater) -> windows.HRESULT,
	get_SoundLevel: proc "system" (this: ^ISystemMediaTransportControls, value: ^i32) -> windows.HRESULT,
	get_IsEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsPlayEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsPlayEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsStopEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsStopEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsPauseEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsPauseEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsRecordEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsRecordEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsFastForwardEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsFastForwardEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsRewindEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsRewindEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsPreviousEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsPreviousEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsNextEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsNextEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsChannelUpEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsChannelUpEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	get_IsChannelDownEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: ^b8) -> windows.HRESULT,
	put_IsChannelDownEnabled: proc "system" (this: ^ISystemMediaTransportControls, value: b8) -> windows.HRESULT,
	add_ButtonPressed: proc "system" (this: ^ISystemMediaTransportControls, handler: ^ITypedEventHandler, token: ^EventRegistrationToken) -> windows.HRESULT,
	remove_ButtonPressed: proc "system" (this: ^ISystemMediaTransportControls, token: EventRegistrationToken) -> windows.HRESULT,
	add_PropertyChanged: proc "system" (this: ^ISystemMediaTransportControls, handler: rawptr, token: ^EventRegistrationToken) -> windows.HRESULT,
	remove_PropertyChanged: proc "system" (this: ^ISystemMediaTransportControls, token: EventRegistrationToken) -> windows.HRESULT,
}

MediaPlaybackType :: enum i32 {
	Unknown = 0,
	Music = 1,
	Video = 2,
	Image = 3,
}

ISystemMediaTransportControlsDisplayUpdater :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using updater_vtable: ^ISystemMediaTransportControlsDisplayUpdater_VTable,
}
ISystemMediaTransportControlsDisplayUpdater_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	get_Type: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: ^MediaPlaybackType) -> windows.HRESULT,
	put_Type: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: MediaPlaybackType) -> windows.HRESULT,
	get_AppMediaId: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: ^HSTRING) -> windows.HRESULT,
	put_AppMediaId: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: HSTRING) -> windows.HRESULT,
	get_Thumbnail: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: ^rawptr) -> windows.HRESULT,
	put_Thumbnail: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: rawptr) -> windows.HRESULT,
	get_MusicProperties: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: ^^IMusicDisplayProperties) -> windows.HRESULT,
	get_VideoProperties: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: ^rawptr) -> windows.HRESULT,
	get_ImageProperties: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, value: ^rawptr) -> windows.HRESULT,
	CopyFromFileAsync: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, type: MediaPlaybackType, source: rawptr, operation: ^rawptr) -> windows.HRESULT,
	ClearAll: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater) -> windows.HRESULT,
	Update: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater) -> windows.HRESULT,
}

IMusicDisplayProperties :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using musicprops_vtable: ^IMusicDisplayProperties_VTable,
}
IMusicDisplayProperties_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	get_Title: proc "system" (this: ^IMusicDisplayProperties, value: ^HSTRING) -> windows.HRESULT,
	put_Title: proc "system" (this: ^IMusicDisplayProperties, value: HSTRING) -> windows.HRESULT,
	get_AlbumArtist: proc "system" (this: ^IMusicDisplayProperties, value: ^HSTRING) -> windows.HRESULT,
	put_AlbumArtist: proc "system" (this: ^IMusicDisplayProperties, value: HSTRING) -> windows.HRESULT,
	get_Artist: proc "system" (this: ^IMusicDisplayProperties, value: ^HSTRING) -> windows.HRESULT,
	put_Artist: proc "system" (this: ^IMusicDisplayProperties, value: HSTRING) -> windows.HRESULT,
}

SystemMediaTransportControlsButton :: enum i32 {
	Play = 0,
	Pause = 1,
	Stop = 2,
	Record = 3,
	FastForward = 4,
	Rewind = 5,
	Next = 6,
	Previous = 7,
	ChannelUp = 8,
	ChannelDown = 9,
}

ISystemMediaTransportControlsButtonPressedEventArgs :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using args_vtable: ^ISystemMediaTransportControlsButtonPressedEventArgs_VTable,
}
ISystemMediaTransportControlsButtonPressedEventArgs_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	get_Button: proc "system" (this: ^ISystemMediaTransportControlsButtonPressedEventArgs, value: ^SystemMediaTransportControlsButton) -> windows.HRESULT,
}

ITypedEventHandler_UUID := &windows.IID{0x5734A1B3, 0xB66E, 0x51E2, {0x80, 0x2A, 0x53, 0x05, 0x82, 0x01, 0x93, 0xFC}} // Generated generic IID for button handler (may need testing, usually we just return S_OK for any IID in our custom COM object)

ITypedEventHandler :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using handler_vtable: ^ITypedEventHandler_VTable,
}
ITypedEventHandler_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	Invoke: proc "system" (this: ^ITypedEventHandler, sender: ^ISystemMediaTransportControls, args: ^ISystemMediaTransportControlsButtonPressedEventArgs) -> windows.HRESULT,
}

SMTC_Handler :: struct {
	using handler: ITypedEventHandler,
	ref_count: i32,
}

smtc_handler_query_interface :: proc "system" (this: ^windows.IUnknown, riid: ^windows.IID, ppvObject: ^rawptr) -> windows.HRESULT {
	if ppvObject == nil do return windows.HRESULT(-2147467261) // E_POINTER

	is_supported := false
	if riid.Data1 == 0x00000000 && riid.Data2 == 0x0000 && riid.Data3 == 0x0000 do is_supported = true // IUnknown
	if riid.Data1 == 0x94ea2b94 && riid.Data2 == 0xe9cc && riid.Data3 == 0x49e0 do is_supported = true // IAgileObject
	if riid.Data1 == 0x0557e996 && riid.Data2 == 0x7b23 && riid.Data3 == 0x5bae do is_supported = true // ITypedEventHandler

	if !is_supported {
		ppvObject^ = nil
		return windows.HRESULT(-2147467262) // E_NOINTERFACE
	}

	ppvObject^ = this
	this->AddRef()
	return windows.S_OK
}

smtc_handler_add_ref :: proc "system" (this: ^windows.IUnknown) -> u32 {
	handler := cast(^SMTC_Handler)this
	handler.ref_count += 1
	return u32(handler.ref_count)
}

smtc_handler_release :: proc "system" (this: ^windows.IUnknown) -> u32 {
	handler := cast(^SMTC_Handler)this
	handler.ref_count -= 1
	return u32(handler.ref_count)
}

smtc_handler_invoke :: proc "system" (this: ^ITypedEventHandler, sender: ^ISystemMediaTransportControls, args: ^ISystemMediaTransportControlsButtonPressedEventArgs) -> windows.HRESULT {
	button: SystemMediaTransportControlsButton
	if args->get_Button(&button) == windows.S_OK {
		if button == .Play || button == .Pause {
			action_pending = 0
		} else if button == .Next {
			action_pending = 1
		} else if button == .Previous {
			action_pending = 2
		}
	}
	return windows.S_OK
}

global_handler_vtable: ITypedEventHandler_VTable
global_handler: SMTC_Handler

g_smtc: ^ISystemMediaTransportControls

IRandomAccessStreamReference_UUID := &windows.IID{0x33ee3134, 0x1dd6, 0x4e3a, {0x80, 0x67, 0xd1, 0xc1, 0x62, 0xe8, 0x64, 0x2b}}
IRandomAccessStreamReference :: struct #raw_union {
    #subtype iinspectable: IInspectable,
    using streamref_vtable: ^IRandomAccessStreamReference_VTable,
}
IRandomAccessStreamReference_VTable :: struct {
    using iinspectable_vtable: IInspectable_VTable,
    OpenReadAsync: rawptr,
}

IRandomAccessStreamReferenceStatics_UUID := &windows.IID{0x857309dc, 0x3fbf, 0x4e7d, {0x98, 0x6f, 0xef, 0x3b, 0x1a, 0x07, 0xa9, 0x64}}
IRandomAccessStreamReferenceStatics :: struct #raw_union {
    #subtype iinspectable: IInspectable,
    using statics_vtable: ^IRandomAccessStreamReferenceStatics_VTable,
}
IRandomAccessStreamReferenceStatics_VTable :: struct {
    using iinspectable_vtable: IInspectable_VTable,
    CreateFromFile: rawptr,
    CreateFromUri: rawptr,
    CreateFromStream: proc "system" (this: ^IRandomAccessStreamReferenceStatics, stream: rawptr, streamReference: ^^IRandomAccessStreamReference) -> windows.HRESULT,
}

IRandomAccessStream_UUID := &windows.IID{0x905a0fe1, 0xbc53, 0x11df, {0x8c, 0x49, 0x00, 0x1e, 0x4f, 0xc6, 0x86, 0xda}}

create_hstring :: proc(str: string) -> HSTRING {
	if len(str) == 0 do return nil
	utf16_buf := make([]u16, len(str), context.temp_allocator)
	utf16_len := utf16.encode_string(utf16_buf, str)
	utf16_str := utf16_buf[:utf16_len]
	hstr: HSTRING
	WindowsCreateString(raw_data(utf16_str), u32(len(utf16_str)), &hstr)
	return hstr
}

init :: proc(hwnd: windows.HWND) {
	RoInitialize(1)

	global_handler_vtable.QueryInterface = smtc_handler_query_interface
	global_handler_vtable.AddRef = smtc_handler_add_ref
	global_handler_vtable.Release = smtc_handler_release
	global_handler_vtable.Invoke = smtc_handler_invoke

	global_handler.handler_vtable = &global_handler_vtable
	global_handler.ref_count = 1

	class_name := create_hstring("Windows.Media.SystemMediaTransportControls")
	defer WindowsDeleteString(class_name)

	interop: ^ISystemMediaTransportControlsInterop
	hr := RoGetActivationFactory(class_name, ISystemMediaTransportControlsInterop_UUID, cast(^rawptr)&interop)
	if hr == windows.S_OK && interop != nil {
		hr = interop->GetForWindow(hwnd, ISystemMediaTransportControls_UUID, &g_smtc)
		if hr == windows.S_OK && g_smtc != nil {
			g_smtc->put_IsPlayEnabled(true)
			g_smtc->put_IsPauseEnabled(true)
			g_smtc->put_IsNextEnabled(true)
			g_smtc->put_IsPreviousEnabled(true)

			token: EventRegistrationToken
			g_smtc->add_ButtonPressed(&global_handler.handler, &token)
		}
		interop->Release()
	}
}

action_pending: int = -1

poll_action :: proc() -> int {
	action := action_pending
	action_pending = -1
	return action
}

update_metadata :: proc(title: string, artist: string, cover_bytes: []byte = nil) {
	if g_smtc == nil do return

	updater: ^ISystemMediaTransportControlsDisplayUpdater
	if g_smtc->get_DisplayUpdater(&updater) == windows.S_OK && updater != nil {
		updater->ClearAll()
		updater->put_Type(.Music)

		if len(cover_bytes) > 0 {
			istream := SHCreateMemStream(raw_data(cover_bytes), u32(len(cover_bytes)))
			if istream != nil {
				random_access_stream: rawptr
				hr_cras := CreateRandomAccessStreamOverStream(istream, 0, IRandomAccessStream_UUID, &random_access_stream)
				if hr_cras == windows.S_OK {
					ref_class_hstr := create_hstring("Windows.Storage.Streams.RandomAccessStreamReference")
					defer if ref_class_hstr != nil do WindowsDeleteString(ref_class_hstr)

					ref_statics: ^IRandomAccessStreamReferenceStatics
					if RoGetActivationFactory(ref_class_hstr, IRandomAccessStreamReferenceStatics_UUID, cast(^rawptr)&ref_statics) == windows.S_OK {
						stream_ref: ^IRandomAccessStreamReference
						if ref_statics->CreateFromStream(random_access_stream, &stream_ref) == windows.S_OK {
							updater->put_Thumbnail(cast(rawptr)stream_ref)
							stream_ref->Release()
						}
						ref_statics->Release()
					}

					iunk := cast(^windows.IUnknown)random_access_stream
					iunk->Release()
				}

				iunk_stream := cast(^windows.IUnknown)istream
				iunk_stream->Release()
			}
		}

		music_props: ^IMusicDisplayProperties
		if updater->get_MusicProperties(&music_props) == windows.S_OK && music_props != nil {

			title_hstr := create_hstring(title)
			defer if title_hstr != nil do WindowsDeleteString(title_hstr)

			artist_hstr := create_hstring(artist)
			defer if artist_hstr != nil do WindowsDeleteString(artist_hstr)

			music_props->put_Title(title_hstr)
			music_props->put_Artist(artist_hstr)

			music_props->Release()
		}

		updater->Update()
		updater->Release()
	}
}

update_status :: proc(status: int) {
	if g_smtc == nil do return

	play_status := MediaPlaybackStatus.Stopped
	if status == 1 do play_status = .Playing
	else if status == 2 do play_status = .Paused

	g_smtc->put_PlaybackStatus(play_status)
}
