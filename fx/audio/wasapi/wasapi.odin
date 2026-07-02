package wasapi

import win "core:sys/windows"

CLSID_MMDeviceEnumerator := win.GUID{0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}}
IID_IMMDeviceEnumerator  := win.GUID{0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}}
IID_IAudioClient         := win.GUID{0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}}
IID_IAudioRenderClient   := win.GUID{0xf294acfc, 0x3146, 0x4483, {0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2}}
IID_ISimpleAudioVolume   := win.GUID{0x87ce5498, 0x68d6, 0x44e5, {0x92, 0x15, 0x6d, 0xa4, 0x7e, 0xf8, 0x83, 0xd8}}

EDataFlow :: enum win.c_int {
	eRender,
	eCapture,
	eAll,
	EDataFlow_enum_count,
}

ERole :: enum win.c_int {
	eConsole,
	eMultimedia,
	eCommunications,
	ERole_enum_count,
}

AUDCLNT_SHAREMODE :: enum win.c_int {
	AUDCLNT_SHAREMODE_SHARED,
	AUDCLNT_SHAREMODE_EXCLUSIVE,
}

AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: win.DWORD : 0x80000000
AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: win.DWORD : 0x08000000

IMMDeviceEnumerator :: struct {
	using vtable: ^IMMDeviceEnumeratorVtbl,
}

IMMDeviceEnumeratorVtbl :: struct {
	using iunknown: win.IUnknownVtbl,
	EnumAudioEndpoints: proc "system" (this: ^IMMDeviceEnumerator, dataFlow: EDataFlow, dwStateMask: win.DWORD, ppDevices: ^rawptr) -> win.HRESULT,
	GetDefaultAudioEndpoint: proc "system" (this: ^IMMDeviceEnumerator, dataFlow: EDataFlow, role: ERole, ppEndpoint: ^^IMMDevice) -> win.HRESULT,
	GetDevice: proc "system" (this: ^IMMDeviceEnumerator, pwstrId: win.LPCWSTR, ppDevice: ^^IMMDevice) -> win.HRESULT,
	RegisterEndpointNotificationCallback: proc "system" (this: ^IMMDeviceEnumerator, pClient: rawptr) -> win.HRESULT,
	UnregisterEndpointNotificationCallback: proc "system" (this: ^IMMDeviceEnumerator, pClient: rawptr) -> win.HRESULT,
}

IMMDevice :: struct {
	using vtable: ^IMMDeviceVtbl,
}

IMMDeviceVtbl :: struct {
	using iunknown: win.IUnknownVtbl,
	Activate: proc "system" (this: ^IMMDevice, iid: ^win.GUID, dwClsCtx: win.DWORD, pActivationParams: rawptr, ppInterface: ^rawptr) -> win.HRESULT,
	OpenPropertyStore: proc "system" (this: ^IMMDevice, stgmAccess: win.DWORD, ppProperties: ^rawptr) -> win.HRESULT,
	GetId: proc "system" (this: ^IMMDevice, ppstrId: ^win.LPWSTR) -> win.HRESULT,
	GetState: proc "system" (this: ^IMMDevice, pdwState: ^win.DWORD) -> win.HRESULT,
}

IAudioClient :: struct {
	using vtable: ^IAudioClientVtbl,
}

REFERENCE_TIME :: win.LONGLONG

IAudioClientVtbl :: struct {
	using iunknown: win.IUnknownVtbl,
	Initialize: proc "system" (this: ^IAudioClient, ShareMode: AUDCLNT_SHAREMODE, StreamFlags: win.DWORD, hnsBufferDuration: REFERENCE_TIME, hnsPeriodicity: REFERENCE_TIME, pFormat: ^win.WAVEFORMATEX, AudioSessionGuid: ^win.GUID) -> win.HRESULT,
	GetBufferSize: proc "system" (this: ^IAudioClient, pNumBufferFrames: ^win.UINT32) -> win.HRESULT,
	GetStreamLatency: proc "system" (this: ^IAudioClient, phnsLatency: ^REFERENCE_TIME) -> win.HRESULT,
	GetCurrentPadding: proc "system" (this: ^IAudioClient, pNumPaddingFrames: ^win.UINT32) -> win.HRESULT,
	IsFormatSupported: proc "system" (this: ^IAudioClient, ShareMode: AUDCLNT_SHAREMODE, pFormat: ^win.WAVEFORMATEX, ppClosestMatch: ^^win.WAVEFORMATEX) -> win.HRESULT,
	GetMixFormat: proc "system" (this: ^IAudioClient, ppDeviceFormat: ^^win.WAVEFORMATEX) -> win.HRESULT,
	GetDevicePeriod: proc "system" (this: ^IAudioClient, phnsDefaultDevicePeriod: ^REFERENCE_TIME, phnsMinimumDevicePeriod: ^REFERENCE_TIME) -> win.HRESULT,
	Start: proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Stop: proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Reset: proc "system" (this: ^IAudioClient) -> win.HRESULT,
	SetEventHandle: proc "system" (this: ^IAudioClient, eventHandle: win.HANDLE) -> win.HRESULT,
	GetService: proc "system" (this: ^IAudioClient, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT,
}

IAudioRenderClient :: struct {
	using vtable: ^IAudioRenderClientVtbl,
}

IAudioRenderClientVtbl :: struct {
	using iunknown: win.IUnknownVtbl,
	GetBuffer: proc "system" (this: ^IAudioRenderClient, NumFramesRequested: win.UINT32, ppData: ^^win.BYTE) -> win.HRESULT,
	ReleaseBuffer: proc "system" (this: ^IAudioRenderClient, NumFramesWritten: win.UINT32, dwFlags: win.DWORD) -> win.HRESULT,
}

ISimpleAudioVolume :: struct {
	using vtable: ^ISimpleAudioVolumeVtbl,
}

ISimpleAudioVolumeVtbl :: struct {
	using iunknown: win.IUnknownVtbl,
	SetMasterVolume: proc "system" (this: ^ISimpleAudioVolume, fLevel: f32, EventContext: ^win.GUID) -> win.HRESULT,
	GetMasterVolume: proc "system" (this: ^ISimpleAudioVolume, pfLevel: ^f32) -> win.HRESULT,
	SetMute: proc "system" (this: ^ISimpleAudioVolume, bMute: win.BOOL, EventContext: ^win.GUID) -> win.HRESULT,
	GetMute: proc "system" (this: ^ISimpleAudioVolume, pbMute: ^win.BOOL) -> win.HRESULT,
}
