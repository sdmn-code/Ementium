# Ementium

A fast image viewer for macOS that replaces Quick Look for pictures. Select an image in Finder, press **Space**, and it opens full screen over a dimmed background. Arrow keys browse the folder in exactly the order Finder shows it, **Esc** closes. Everything that isn't an image (PDF, video, documents) still opens in the regular Quick Look.

There's no Dock icon and no main window: Ementium runs in the background, and the only UI is its settings window.

The interface is in English and Russian (follows the system language). Detailed documentation is in Russian: [README.md](README.md).

## Features

- Space in Finder opens the selected image; arrows browse in Finder's order (any sorting, groups, Recents, search results). Documents between images are skipped, and Finder's selection follows the viewer.
- Zoom with `+`/`-`, pinch, double-tap; pan with two fingers or by dragging. Each image remembers its zoom until the viewer closes (optional).
- RAW (CR2, CR3, NEF, ARW, DNG, …) shows the embedded preview instantly, then the full decode. SVG is rendered as a vector. Animated GIF, WebP, APNG, HEICS and AVIF play in a loop.
- Hold `⌥` for photo info: camera, lens, exposure, date, location.
- Optional: `⌘⌫` moves the image to the Trash through Finder (undo with `⌘Z`).
- Neighbouring images are preloaded, so browsing is instant.

## Requirements

- macOS 27 or later, Apple Silicon. Ementium reads Finder's interface through Accessibility, and that has only been verified on macOS 27.

## Installation

1. Download `Ementium.dmg` from [Releases](https://github.com/sdmn-code/Ementium/releases) and drag Ementium into Applications.
2. The app isn't notarized by Apple (no paid developer account yet), so macOS will refuse to open it the first time. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Ementium. Since macOS 15 the Control-click → Open shortcut no longer works for this.
3. On first launch, Ementium explains why it needs **Accessibility** and offers a button to grant it. Interception starts by itself once access is granted — no restart needed.

To uninstall: quit Ementium (menu bar icon or settings), delete it from Applications, and remove it from **Privacy & Security → Accessibility** and **General → Login Items**.

## Keys

| Key | Action |
|---|---|
| `Space` in Finder | Open the selected image |
| `→` / `↓`, `←` / `↑` | Next / previous image, in Finder's order |
| `Esc`, `Space` | Close |
| `+` / `-` / `0` (with or without `⌘`) | Zoom in / out / fit |
| Hold `⌥` | Photo info |
| `⌘⌫` / `⌘Z` | Move to Trash / undo (if enabled) |
| `⌘,` | Settings |
| `⌘Q` | Quit Ementium |

## Privacy and security

Ementium never connects to the network and doesn't record keystrokes. It needs Accessibility to intercept Space in Finder and to read which file is selected. Image decoding runs in a separate sandboxed process (`EmentiumDecoder`) with no file or network access: the main app, which holds the Accessibility permission, never parses image files itself.

## Building from source

Xcode 27 or later:

```bash
xcodebuild -project Ementium.xcodeproj -scheme Ementium test                 # tests
scripts/install.sh                                                           # Release build into ~/Applications
```

## License

MIT — see [LICENSE](LICENSE).
