# GriPlayer

GriPlayer is a desktop audio player built with [Odin](https://odin-lang.org/)
### [Download Latest Release](https://github.com/mfbulut/GriPlayer/releases/latest)

## Features

- **UI:** Modern, dark-themed interface with playlists, queue, and search.
- **Playback:** Gapless playback with a built-in frequency visualizer.
- **Lyrics:** Search View synchronized lyrics using `.lrc` files.
- **SMTC:** Full Windows System Media Transport Controls integration.
- **DirectX 11 & WASAPI:** Built from scratch, low latency, fast performance.
- **Supported Formats:** mp3, flac, wav, opus, ogg

## Screenshots

<img src="https://github.com/user-attachments/assets/aa094b43-3a5f-4049-9fec-81bb8541a2f6" />
<img src="https://github.com/user-attachments/assets/f7e86e30-c689-4171-8d6e-abd47466d240" />

## Roadmap

- [x] Cache songs
- [x] Fast lyrics search
- [x] Support for mp3 and flac
- [x] Queue management
- [ ] Themes
- [ ] Mini Player
- [ ] Playlist management

## Building

- **OS:** Windows
- **Compiler:** [Odin Compiler](https://odin-lang.org/docs/install/)

```bash
odin build . -o:speed -subsystem:windows -resource:assets/resource.rc
```
