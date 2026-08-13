# GriPlayer

GriPlayer is a desktop audio player built with [Odin](https://odin-lang.org/)
### [Download Latest Release](https://github.com/mfbulut/GriPlayer/releases/latest)

## Features

- **UI:** Modern, responsive interface with playlists, queue, and fuzzy search.
- **Playback:** Gapless playback with a built-in frequency visualizer.
- **Lyrics:** Search and view synchronized lyrics using `.lrc` files.
- **Equalizer:** Fine-tune audio across 10 Bands with pre-amp gain control.
- **Loudness Normalization:** [R128](https://en.wikipedia.org/wiki/EBU_R_128) loudness normalization for Opus files.
- **Listening History:** Record your play history and track the total time listened.
- **SMTC:** Full Windows System Media Transport Controls integration.
- **Vulkan & WASAPI:** Built from scratch, low latency, fast performance.
- **Supported Formats:** flac, opus, ogg

## Screenshots

<img src="https://github.com/user-attachments/assets/a10b3320-02eb-41d0-b61b-24acc2bf2a7b" />
<img src="https://github.com/user-attachments/assets/fd2930a8-27b3-41ab-8bcd-d4494fad4c8e" />
<img src="https://github.com/user-attachments/assets/63ffe76c-9ab2-48e5-9f51-00562752997e" />

## Roadmap

- [x] Cache songs
- [x] Fast lyrics search
- [x] Support for flac
- [x] Queue management
- [x] Listening History
- [x] Equalizer
- [x] Mini Player
- [x] Linux Support
- [ ] Themes
- [ ] Playlist management

## Building

- **Compiler:** [Odin Compiler](https://odin-lang.org/docs/install/)

**Windows:**
```bash
odin build . -o:speed -subsystem:windows -resource:assets/resource.rc
```

**Linux:** requires `libvulkan`, `libX11`, `alsa-lib`, and `opusfile` (e.g. on
Arch: `sudo pacman -S vulkan-icd-loader libx11 alsa-lib opusfile`)
```bash
odin build . -o:speed
```

## Recommended Tools

**Metadata:**
* https://www.foobar2000.org/
* https://picard.musicbrainz.org/

**Lyrics:**
* https://github.com/tranxuanthang/lrcget

**Album covers**
* https://covers.musichoarders.xyz/
