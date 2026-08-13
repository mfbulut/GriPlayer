#+build linux
package smtc

// No-op stub — MPRIS integration deferred until core Linux playback is confirmed working.

Action :: enum i32 { None, Play, Pause, Next, Previous }
MediaPlaybackStatus :: enum i32 { Playing, Paused }

update_metadata :: proc(title, artist: string, cover_bytes: []byte = nil) {}
update_status   :: proc(status: MediaPlaybackStatus) {}
poll_action     :: proc() -> Action { return .None }
