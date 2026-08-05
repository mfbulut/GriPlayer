package smtc

import "core:sync"
import "core:sys/windows"
import "core:unicode/utf16"

Action :: enum i32 {
	None,
	Play,
	Pause,
	Next,
	Previous,
}

SMTC_Handler :: struct {
	using handler: ITypedEventHandler,
	ref_count: i32,
}

g_smtc: ^ISystemMediaTransportControls
g_handler_vtable: ITypedEventHandler_VTable
g_handler: SMTC_Handler
pending_action: Action

smtc_handler_query_interface :: proc "system" (
	this: ^windows.IUnknown,
	riid: ^windows.IID,
	result: ^rawptr,
) -> windows.HRESULT {
	if result == nil do return transmute(windows.HRESULT)u32(windows.E_POINTER)

	iid_equal :: proc "contextless" (a, b: ^windows.IID) -> bool {
		return a != nil && b != nil && a^ == b^
	}

	if !iid_equal(riid, &IUnknown_UUID) &&
	   !iid_equal(riid, &IAgileObject_UUID) &&
	   !iid_equal(riid, &ITypedEventHandler_UUID) {
		result^ = nil
		return transmute(windows.HRESULT)u32(windows.E_NOINTERFACE)
	}

	result^ = cast(rawptr)this
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

smtc_handler_invoke :: proc "system" (
	this: ^ITypedEventHandler,
	sender: ^ISystemMediaTransportControls,
	args: ^ISystemMediaTransportControlsButtonPressedEventArgs,
) -> windows.HRESULT {
	if args == nil do return transmute(windows.HRESULT)u32(windows.E_POINTER)

	button: SystemMediaTransportControlsButton
	if windows.FAILED(args->get_Button(&button)) do return transmute(windows.HRESULT)u32(windows.E_FAIL)

	action: Action
	#partial switch button {
	case .Play:     action = .Play
	case .Pause:    action = .Pause
	case .Next:     action = .Next
	case .Previous: action = .Previous
	}
	if action == .None do return windows.S_OK

	sync.atomic_store(&pending_action, action)
	return windows.S_OK
}

create_hstring :: proc(str: string) -> HSTRING {
	if len(str) == 0 do return nil

	buffer := make([]u16, len(str), context.temp_allocator)
	length := utf16.encode_string(buffer, str)
	result: HSTRING
	if windows.FAILED(WindowsCreateString(raw_data(buffer), u32(length), &result)) {
		return nil
	}
	return result
}

init :: proc(hwnd: rawptr) {
	if g_smtc != nil || hwnd == nil do return

	ro_result := RoInitialize(1)
	if windows.FAILED(ro_result) do return

	g_handler_vtable = ITypedEventHandler_VTable {
		QueryInterface = smtc_handler_query_interface,
		AddRef = smtc_handler_add_ref,
		Release = smtc_handler_release,
		Invoke = smtc_handler_invoke,
	}
	g_handler.vtable = &g_handler_vtable
	g_handler.ref_count = 1

	class_name := create_hstring("Windows.Media.SystemMediaTransportControls")
	if class_name == nil do return
	defer WindowsDeleteString(class_name)

	interop: ^ISystemMediaTransportControlsInterop
	result := RoGetActivationFactory(
		class_name,
		&ISystemMediaTransportControlsInterop_UUID,
		cast(^rawptr)&interop,
	)
	if windows.FAILED(result) || interop == nil do return
	defer interop->Release()

	result = interop->GetForWindow(cast(windows.HWND)hwnd, &ISystemMediaTransportControls_UUID, &g_smtc)
	if windows.FAILED(result) || g_smtc == nil do return

	controls_ready :=
		windows.SUCCEEDED(g_smtc->put_IsEnabled(true)) &&
		windows.SUCCEEDED(g_smtc->put_IsPlayEnabled(true)) &&
		windows.SUCCEEDED(g_smtc->put_IsPauseEnabled(true)) &&
		windows.SUCCEEDED(g_smtc->put_IsNextEnabled(true)) &&
		windows.SUCCEEDED(g_smtc->put_IsPreviousEnabled(true))
	if !controls_ready {
		g_smtc->Release()
		g_smtc = nil
		return
	}

	button_token: EventRegistrationToken
	if windows.FAILED(g_smtc->add_ButtonPressed(&g_handler.handler, &button_token)) {
		g_smtc->put_IsEnabled(false)
		g_smtc->Release()
		g_smtc = nil
	}
}

poll_action :: proc() -> Action {
	if g_smtc == nil do return .None 
	return sync.atomic_exchange(&pending_action, .None)
}

update_metadata :: proc(title, artist: string, cover_bytes: []byte = nil) {
	if g_smtc == nil do return

	updater: ^ISystemMediaTransportControlsDisplayUpdater
	if windows.FAILED(g_smtc->get_DisplayUpdater(&updater)) || updater == nil do return
	defer updater->Release()

	if windows.FAILED(updater->ClearAll()) ||
	   windows.FAILED(updater->put_Type(.Music)) {
		return
	}

	if len(cover_bytes) > 0 {
		if stream := SHCreateMemStream(raw_data(cover_bytes), u32(len(cover_bytes))); stream != nil {
			defer (cast(^windows.IUnknown)stream)->Release()

			random_access_stream: rawptr
			if windows.SUCCEEDED(CreateRandomAccessStreamOverStream(
				stream,
				0,
				&IRandomAccessStream_UUID,
				&random_access_stream,
			)) && random_access_stream != nil {
				defer (cast(^windows.IUnknown)random_access_stream)->Release()

				class_name := create_hstring("Windows.Storage.Streams.RandomAccessStreamReference")
				if class_name != nil {
					defer WindowsDeleteString(class_name)

					statics: ^IRandomAccessStreamReferenceStatics
					if windows.SUCCEEDED(RoGetActivationFactory(
						class_name,
						&IRandomAccessStreamReferenceStatics_UUID,
						cast(^rawptr)&statics,
					)) && statics != nil {
						defer statics->Release()

						stream_reference: ^IRandomAccessStreamReference
						if windows.SUCCEEDED(statics->CreateFromStream(
							random_access_stream,
							&stream_reference,
						)) && stream_reference != nil {
							defer stream_reference->Release()
							updater->put_Thumbnail(cast(rawptr)stream_reference)
						}
					}
				}
			}
		}
	}

	properties: ^IMusicDisplayProperties
	if windows.SUCCEEDED(updater->get_MusicProperties(&properties)) && properties != nil {
		defer properties->Release()

		title_string := create_hstring(title)
		defer if title_string != nil do WindowsDeleteString(title_string)

		artist_string := create_hstring(artist)
		defer if artist_string != nil do WindowsDeleteString(artist_string)

		properties->put_Title(title_string)
		properties->put_Artist(artist_string)
	}

	updater->Update()
}

update_status :: proc(status: MediaPlaybackStatus) {
	if g_smtc == nil do return
	g_smtc->put_PlaybackStatus(status)
}
