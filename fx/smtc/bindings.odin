package smtc

import "core:sys/windows"

HSTRING :: distinct rawptr

EventRegistrationToken :: struct {
	value: i64,
}

foreign import runtimeobject "system:runtimeobject.lib"
@(default_calling_convention="system")
foreign runtimeobject {
	WindowsCreateString :: proc(source_string: [^]u16, length: u32, string: ^HSTRING) -> windows.HRESULT ---
	WindowsDeleteString :: proc(string: HSTRING) -> windows.HRESULT ---
	RoGetActivationFactory :: proc(activatable_class_id: HSTRING, iid: ^windows.IID, factory: ^rawptr) -> windows.HRESULT ---
	RoInitialize :: proc(init_type: i32) -> windows.HRESULT ---
	RoUninitialize :: proc() ---
}

foreign import shcore "system:Shcore.lib"
@(default_calling_convention="system")
foreign shcore {
	CreateRandomAccessStreamOverStream :: proc(stream: rawptr, options: i32, riid: ^windows.IID, result: ^rawptr) -> windows.HRESULT ---
}

foreign import shlwapi "system:Shlwapi.lib"
@(default_calling_convention="system")
foreign shlwapi {
	SHCreateMemStream :: proc(initial_data: [^]u8, size: u32) -> rawptr ---
}

IUnknown_UUID := windows.IID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IAgileObject_UUID := windows.IID{0x94EA2B94, 0xE9CC, 0x49E0, {0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90}}
IInspectable_UUID := windows.IID{0xAF86E2E0, 0xB12D, 0x4C6A, {0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90}}

IInspectable :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IInspectable_VTable,
}

IInspectable_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetIids: proc "system" (this: ^IInspectable, iid_count: ^u32, iids: ^^windows.IID) -> windows.HRESULT,
	GetRuntimeClassName: proc "system" (this: ^IInspectable, class_name: ^HSTRING) -> windows.HRESULT,
	GetTrustLevel: proc "system" (this: ^IInspectable, trust_level: ^i32) -> windows.HRESULT,
}

ISystemMediaTransportControlsInterop_UUID := windows.IID{0xDDB0472D, 0xC911, 0x4A1F, {0x86, 0xD9, 0xDC, 0x3D, 0x71, 0xA9, 0x5F, 0x5A}}

ISystemMediaTransportControlsInterop :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^ISystemMediaTransportControlsInterop_VTable,
}

ISystemMediaTransportControlsInterop_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	GetForWindow: proc "system" (
		this: ^ISystemMediaTransportControlsInterop,
		app_window: windows.HWND,
		riid: ^windows.IID,
		controls: ^^ISystemMediaTransportControls,
	) -> windows.HRESULT,
}

MediaPlaybackStatus :: enum i32 {
	Closed   = 0,
	Changing = 1,
	Stopped  = 2,
	Playing  = 3,
	Paused   = 4,
}

ISystemMediaTransportControls_UUID := windows.IID{0x99FA3FF4, 0x1742, 0x42A6, {0x90, 0x2E, 0x08, 0x7D, 0x41, 0xF9, 0x65, 0xEC}}

ISystemMediaTransportControls :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^ISystemMediaTransportControls_VTable,
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
	Music   = 1,
	Video   = 2,
	Image   = 3,
}

ISystemMediaTransportControlsDisplayUpdater :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^ISystemMediaTransportControlsDisplayUpdater_VTable,
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
	CopyFromFileAsync: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater, media_type: MediaPlaybackType, source: rawptr, operation: ^rawptr) -> windows.HRESULT,
	ClearAll: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater) -> windows.HRESULT,
	Update: proc "system" (this: ^ISystemMediaTransportControlsDisplayUpdater) -> windows.HRESULT,
}

IMusicDisplayProperties :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^IMusicDisplayProperties_VTable,
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
	Play        = 0,
	Pause       = 1,
	Stop        = 2,
	Record      = 3,
	FastForward = 4,
	Rewind      = 5,
	Next        = 6,
	Previous    = 7,
	ChannelUp   = 8,
	ChannelDown = 9,
}

ISystemMediaTransportControlsButtonPressedEventArgs :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^ISystemMediaTransportControlsButtonPressedEventArgs_VTable,
}

ISystemMediaTransportControlsButtonPressedEventArgs_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	get_Button: proc "system" (
		this: ^ISystemMediaTransportControlsButtonPressedEventArgs,
		value: ^SystemMediaTransportControlsButton,
	) -> windows.HRESULT,
}

ITypedEventHandler_UUID := windows.IID{0x0557E996, 0x7B23, 0x5BAE, {0xAA, 0x81, 0xEA, 0x0D, 0x67, 0x11, 0x43, 0xA4}}

ITypedEventHandler :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^ITypedEventHandler_VTable,
}

ITypedEventHandler_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	Invoke: proc "system" (
		this: ^ITypedEventHandler,
		sender: ^ISystemMediaTransportControls,
		args: ^ISystemMediaTransportControlsButtonPressedEventArgs,
	) -> windows.HRESULT,
}

IRandomAccessStreamReference_UUID := windows.IID{0x33EE3134, 0x1DD6, 0x4E3A, {0x80, 0x67, 0xD1, 0xC1, 0x62, 0xE8, 0x64, 0x2B}}

IRandomAccessStreamReference :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^IRandomAccessStreamReference_VTable,
}

IRandomAccessStreamReference_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	OpenReadAsync: rawptr,
}

IRandomAccessStreamReferenceStatics_UUID := windows.IID{0x857309DC, 0x3FBF, 0x4E7D, {0x98, 0x6F, 0xEF, 0x3B, 0x1A, 0x07, 0xA9, 0x64}}

IRandomAccessStreamReferenceStatics :: struct #raw_union {
	#subtype iinspectable: IInspectable,
	using vtable: ^IRandomAccessStreamReferenceStatics_VTable,
}

IRandomAccessStreamReferenceStatics_VTable :: struct {
	using iinspectable_vtable: IInspectable_VTable,
	CreateFromFile: rawptr,
	CreateFromUri: rawptr,
	CreateFromStream: proc "system" (
		this: ^IRandomAccessStreamReferenceStatics,
		stream: rawptr,
		stream_reference: ^^IRandomAccessStreamReference,
	) -> windows.HRESULT,
}

IRandomAccessStream_UUID := windows.IID{0x905A0FE1, 0xBC53, 0x11DF, {0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA}}
