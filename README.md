# Ghostty Theme Picker

A simple macOS menu bar app that launches [Ghostty](https://ghostty.org) with a randomly selected theme from the 300+ built-in themes.

A great way to run multiple [Claude Code](https://github.com/anthropics/claude-code) sessions with different themes to help you visually track your different workstreams.

[![Build](https://github.com/chfields/GhosttyThemePicker/actions/workflows/build.yml/badge.svg)](https://github.com/chfields/GhosttyThemePicker/actions/workflows/build.yml)
[![CodeQL](https://github.com/chfields/GhosttyThemePicker/actions/workflows/codeql.yml/badge.svg)](https://github.com/chfields/GhosttyThemePicker/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)

## Features

- **Global Hotkey** - Press ⌃⌥G from anywhere to open Quick Launch panel
- **Random Theme** - Launch Ghostty with a random theme (⌘R) - automatically avoids recent themes
- **Workstreams** - Named presets with themes, directories, commands, and auto-launch
- **Auto-launch** - Automatically open configured workstreams when the app starts
- **Theme Preview** - Color swatches show theme colors before launching
- **Favorites** - Star themes you like for quick access
- **Exclude List** - Hide themes you don't like from random rotation
- **Recent Themes** - Quick access to your last 5 themes
- **Menu Bar Only** - Lives in your menu bar, no Dock icon

## Usage

### Quick Start

Click the terminal icon in your menu bar and select **Random Theme** to launch Ghostty with a random theme. Each click gives you a different theme.

### Global Hotkey (⌃⌥G)

Press **Control + Option + G** from anywhere to instantly open the Quick Launch panel:

- **Random Theme** - Launch with a random theme
- **Workstreams** - Your saved presets with themes and directories
- **Favorites** - Your starred themes
- **Recent** - Recently used themes

Select an option to launch Ghostty, or press **Esc** to close. No need to click the menu bar!

### Workstreams

Workstreams are saved presets for different projects or tasks. Perfect for running multiple Claude Code sessions with distinct visual identities.

**To create a workstream:**
1. Click the menu bar icon → **Manage Workstreams...**
2. Click **Add Workstream**
3. Configure your workstream:

| Field | Description | Example |
|-------|-------------|---------|
| **Name** | Display name in the menu | `Backend API` |
| **Theme** | Ghostty theme to use | `Dracula` |
| **Working Directory** | Start in this folder | `/Users/me/projects/api` |
| **Window Title** | Custom window title | `Claude - Backend` |
| **Command to Run** | Command to execute on launch | `claude` |
| **Extra Ghostty Options** | Additional CLI flags | `--font-size=14` |
| **Auto-launch** | Open this workstream when app starts | Toggle on/off |

**Example workstream setups:**

```
Name: Claude - Backend
Theme: Dracula
Directory: ~/projects/backend
Command: claude
Title: Claude Backend

Name: Claude - Frontend
Theme: Solarized Light
Directory: ~/projects/frontend
Command: claude
Title: Claude Frontend

Name: Quick Terminal
Theme: Tokyo Night
Directory: ~
Command: (empty - uses default shell)
```

### Favorites

Star themes you like for quick access:
- After launching with a random theme, the theme name appears at the bottom of the menu
- Open **Recent** submenu and click **Add to Favorites** to save it
- Favorited themes appear in the **Favorites** submenu

### Exclude List

Hide themes you don't want from random rotation:
- Open **Recent** submenu and click **Exclude '[theme]' from Random**
- Excluded themes will never appear when using Random Theme
- View excluded themes in the **Excluded** submenu
- Click any excluded theme to re-include it, or **Clear All Excluded** to reset

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌃⌥G | Open Quick Launch panel (global - works from any app) |
| ⌘R | Launch with random theme (from menu) |
| ⌘, | Manage Workstreams |
| ⌘Q | Quit |

### Extra Ghostty Options

The **Extra Ghostty Options** field accepts any valid Ghostty CLI flags. Some useful ones:

```bash
--font-size=14              # Set font size
--window-padding-x=10       # Horizontal padding
--window-padding-y=10       # Vertical padding
--background-opacity=0.95   # Transparent background
--cursor-style=block        # Cursor style (block, bar, underline)
```

See [Ghostty documentation](https://ghostty.org/docs) for all available options.

### Creating Splits

Once Ghostty is open, you can create splits using these keybindings:

| Shortcut | Action |
|----------|--------|
| ⌘D | Split right (vertical) |
| ⌘⇧D | Split down (horizontal) |
| ⌘⇧Enter | Toggle zoom on current split |
| ⌘] | Focus next split |
| ⌘[ | Focus previous split |
| ⌘W | Close current split |

Note: Splits are created within Ghostty, not via CLI options. Each split shares the same theme as the window.

### Tips for Multiple Claude Sessions

1. **Distinct themes are automatic** - Random Theme automatically excludes your last 5 themes, so each new session looks different
2. **Set window titles** - Include the project name in the title for easy switching
3. **Use the command field** - Set `claude` to auto-start Claude Code when the terminal opens
4. **Organize by project** - Create one workstream per project with its directory pre-configured
5. **Use splits for related work** - Within a single themed window, use ⌘D to split for related tasks (e.g., running tests while coding)
6. **Auto-launch your daily setup** - Enable auto-launch on your most-used workstreams to open them automatically when the app starts

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

1. On launch, fetches available themes via `ghostty +list-themes`
2. Themes, workstreams, and favorites are stored in macOS UserDefaults
3. When launching Ghostty, passes CLI arguments like:
   ```bash
   ghostty --theme=Dracula --working-directory=/path/to/project --title="My Terminal" -e claude
   ```

## Security

This app is open source and scanned with CodeQL. See [SECURITY.md](SECURITY.md) for details on what the app does and doesn't do.

## License

MIT
