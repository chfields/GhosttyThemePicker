# Ghostty Theme Picker

A simple macOS menu bar app that launches [Ghostty](https://ghostty.org) with a randomly selected theme from the 300+ built-in themes.

A great way to run multiple [Claude Code](https://github.com/anthropics/claude-code) sessions with different themes to help you visually track your different workstreams.

[![Build](https://github.com/chfields/GhosttyThemePicker/actions/workflows/build.yml/badge.svg)](https://github.com/chfields/GhosttyThemePicker/actions/workflows/build.yml)
[![CodeQL](https://github.com/chfields/GhosttyThemePicker/actions/workflows/codeql.yml/badge.svg)](https://github.com/chfields/GhosttyThemePicker/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)

## Features

- **Random Theme** - Launch Ghostty with a random theme (⌘R)
- **Recent Themes** - Quick access to your last 5 themes
- **Theme Count** - Shows how many themes are available
- **Menu Bar Only** - Lives in your menu bar, no Dock icon

## Installation

1. Download `GhosttyThemePicker.dmg` from the [Releases](../../releases) page
2. Open the DMG and drag `GhosttyThemePicker.app` to Applications
3. Launch from Applications or Spotlight

### Opening an Unsigned App

This app is not signed with an Apple Developer certificate. macOS will block it by default. To open it:

**Option 1: Right-click to Open**
1. Right-click (or Control-click) on `GhosttyThemePicker.app`
2. Select "Open" from the context menu
3. Click "Open" in the dialog that appears

**Option 2: System Settings**
1. Try to open the app normally (it will be blocked)
2. Go to **System Settings → Privacy & Security**
3. Scroll down to find the message about GhosttyThemePicker being blocked
4. Click "Open Anyway"

You only need to do this once. After that, the app will open normally.

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

## Security

This app is open source and scanned with CodeQL. See [SECURITY.md](SECURITY.md) for details on what the app does and doesn't do.

## License

MIT
