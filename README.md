# GriPlayer

GriPlayer is a desktop audio player built with [Odin](https://odin-lang.org/)

## Features

- **UI:** Modern, dark-themed interface with playlists, context menus, and search.
- **Playback:** Gapless playback with a built-in frequency visualizer.
- **Synced Lyrics:** View synchronized lyrics as your songs play using `.lrc` files.
- **SMTC:** Full Windows System Media Transport Controls integration.
- **Supported Formats:** .opus
  
<img width="1282" height="752" alt="image" src="https://github.com/user-attachments/assets/d6477ecc-e0ae-43cc-b2d4-c6e215616377" />
<img width="1282" height="752" alt="image" src="https://github.com/user-attachments/assets/e4a92605-fa0d-40d5-8435-586da8f1c706" />

## Roadmap

- [ ] More themes
- [ ] Progressive loading
- [ ] Fast lyrics search
- [ ] Support for mp3, flac, and wav
- [ ] Mini-player mode
- [ ] Playlist management

## Building

- **OS:** Windows
- **Compiler:** [Odin Compiler](https://odin-lang.org/docs/install/)

```bash
odin build src -o:speed -subsystem:windows -resource:assets/resource.rc
```
