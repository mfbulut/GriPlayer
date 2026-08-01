# GriPlayer

GriPlayer is a desktop audio player built with [Odin](https://odin-lang.org/)
### [Download Latest Release](https://github.com/mfbulut/GriPlayer/releases/latest)

## Features

- **UI:** Modern, responsive interface with playlists, queue, and fuzzy search.
- **Playback:** Gapless playback with a built-in frequency visualizer.
- **Lyrics:** Search View synchronized lyrics using `.lrc` files.
- **Equalizer:** Fine-tune audio across 10 Bands with pre-amp gain control.
- **Loudness Normalization:** R128 loudness normalization for Opus files.
- **Listening History:** Record your listen history and track total time listened.
- **SMTC:** Full Windows System Media Transport Controls integration.
- **Vulkan & WASAPI:** Built from scratch, low latency, fast performance.
- **Supported Formats:** mp3, flac, wav, opus, ogg

## Screenshots

<img src="https://github.com/user-attachments/assets/121e9e6d-66c9-4741-b4de-e8f691472a50" />
<img src="https://github.com/user-attachments/assets/f21cac38-d0a9-4d93-bb56-26f7d70ac44c" />

## Roadmap

- [x] Cache songs
- [x] Fast lyrics search
- [x] Support for mp3 and flac
- [x] Queue management
- [x] Listening History
- [x] Equalizer
- [x] Mini Player
- [ ] Themes
- [ ] Playlist management
- [ ] Linux Support

## Building

- **OS:** Windows
- **Compiler:** [Odin Compiler](https://odin-lang.org/docs/install/)

```bash
odin build . -o:speed -subsystem:windows -resource:assets/resource.rc
```

## Recommended Tools

**Metadata:**
* https://www.foobar2000.org/
* https://picard.musicbrainz.org/

**Lyrics:**
* https://github.com/tranxuanthang/lrcget

**Album covers**
* https://covers.musichoarders.xyz/