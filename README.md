# GriPlayer

> [!WARNING]
> GriPlayer is in early development and currently only supports `.opus` audio files.

GriPlayer is a desktop audio player built with [Odin](https://odin-lang.org/)

## Features

- **UI:** Modern, dark-themed interface with playlists, context menus, and search.
- **Playback:** Gapless playback with a built-in frequency visualizer.
- **Lyrics:** View synchronized lyrics as your songs play using `.lrc` files.
- **SMTC:** Full Windows System Media Transport Controls integration.
- **DirectX 11 & WASAPI:** Built from scratch, low latency, fast performance.
- **Supported Formats:** .opus

## Roadmap

- [ ] Fast lyrics search
- [ ] Progressive loading
- [ ] Playlist management
- [ ] Support for ogg, mp3, flac, and wav

## Building

- **OS:** Windows
- **Compiler:** [Odin Compiler](https://odin-lang.org/docs/install/)

```bash
odin build src -o:speed -subsystem:windows -resource:assets/resource.rc
```