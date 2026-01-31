# Ghostty Theme Picker

A simple macOS menu bar app that launches [Ghostty](https://ghostty.org) with a randomly selected theme from the 300+ built-in themes.

![Menu Bar](https://img.shields.io/badge/macOS-13%2B-blue)

## Features

- **Random Theme** - Launch Ghostty with a random theme (⌘R)
- **Recent Themes** - Quick access to your last 5 themes
- **Theme Count** - Shows how many themes are available
- **Menu Bar Only** - Lives in your menu bar, no Dock icon

## Installation

1. Download `GhosttyThemePicker.dmg` from the [Releases](../../releases) page
2. Open the DMG and drag `GhosttyThemePicker.app` to Applications
3. Launch from Applications or Spotlight

## Requirements

- macOS 13 or later
- [Ghostty](https://ghostty.org) installed at `/Applications/Ghostty.app`

## Building from Source

```bash
git clone https://github.com/chfields/GhosttyThemePicker.git
cd GhosttyThemePicker
xcodebuild -scheme GhosttyThemePicker -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/GhosttyThemePicker-*/Build/Products/Release/`

## How It Works

1. Fetches available themes via `ghostty +list-themes`
2. Picks a random theme when you click "Random Theme"
3. Launches Ghostty with `--theme=<selected-theme>`

## License

MIT
