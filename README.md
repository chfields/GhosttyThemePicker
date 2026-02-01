# Ghostty Theme Picker

A simple macOS menu bar app that launches [Ghostty](https://ghostty.org) with a randomly selected theme from the 300+ built-in themes.

A great way to run multiple [Claude Code](https://github.com/anthropics/claude-code) sessions with different themes to help you visually track your different workstreams.

[![Build](https://github.com/chfields/GhosttyThemePicker/actions/workflows/build.yml/badge.svg)](https://github.com/chfields/GhosttyThemePicker/actions/workflows/build.yml)
[![CodeQL](https://github.com/chfields/GhosttyThemePicker/actions/workflows/codeql.yml/badge.svg)](https://github.com/chfields/GhosttyThemePicker/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)

## Permissions & Privacy

This app requests the following macOS permissions:

| Permission | Why We Need It | How We Use It |
|------------|----------------|---------------|
| **Screen Recording** | To read window names from Ghostty | The Window Switcher feature (⌃⌥P) uses macOS's CGWindowList API to display the actual names of your open Ghostty windows. Without this permission, windows would show as "Window 1", "Window 2" instead of their actual titles. **We do not record, capture, or store any screen content.** This permission only allows us to read window metadata (names and positions) from the system. |

**Data Collection:** This app does not collect, transmit, or share any data. All settings (themes, workstreams, favorites) are stored locally on your Mac using macOS UserDefaults. No analytics, no telemetry, no network requests (except to run `ghostty +list-themes` locally).

**Open Source:** The complete source code is available in this repository. You can review exactly what the app does and build it yourself if preferred.

## Features

- **Window Switcher** - Press ⌃⌥P from anywhere to quickly switch between open Ghostty windows
- **Global Hotkey** - Press ⌃⌥G from anywhere to open Quick Launch panel
- **Random Theme** - Launch Ghostty with a random theme (⌘R) - automatically avoids recent themes
- **Workstreams** - Named presets with themes, directories, commands, and auto-launch
- **Auto-launch** - Automatically open configured workstreams when the app starts
- **Theme Preview** - Color swatches show theme colors before launching
- **Favorites** - Star themes you like for quick access
- **Exclude List** - Hide themes you don't like from random rotation
- **Import/Export** - Share workstream configurations as JSON
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

### Window Switcher (⌃⌥P)

Press **Control + Option + P** from anywhere to instantly see and switch between all your open Ghostty windows:

- **Claude state detection** - Windows where Claude is waiting for input (showing `✳`) appear at the top
- **Smart sorting** - Windows sorted by: Needs Input → Claude Running → Working → Other
- **Workstream matching** - Windows automatically matched to workstreams by working directory
- **Search windows** - Type to filter by window name or workstream name
- **Click to focus** - Select any window to bring it to the front

**Claude Code Integration:**

The Window Switcher detects Claude Code's state by reading the window title:
- `✳ Claude Code` = **Needs Input** (sorted to top with hourglass icon)
- `⠐ Claude Code` (spinner) = **Working** (shown with gear icon)
- Claude process detected = **Claude** badge (when title detection unavailable)

This works automatically when Claude Code sets dynamic window titles. Workstreams launched from this app don't use `--title`, allowing Claude to control the title and show its status.

**Workstream Detection:**

Windows are matched to workstreams in two ways:
1. **By PID** - Windows launched from this app are tracked automatically
2. **By directory** - Windows opened manually are matched by their working directory to workstream configurations

**First time setup:** The Window Switcher requires **Screen Recording** permission to read window names from macOS. When you first press ⌃⌥P, you'll see a permission prompt with:
- **Open System Settings** button - Takes you directly to Privacy & Security settings
- **Retry** button - Re-checks permission after you grant it

This permission only allows the app to read window metadata (names and positions). We do not record, capture, or store any screen content.

**Perfect for multiple Claude sessions:** When running several Claude Code workstreams, the Window Switcher shows which sessions need your attention, letting you jump to them instantly without alt-tabbing through all your other apps.

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

### Import/Export Workstreams

Share your workstream configurations:
- Open **Manage Workstreams** (⌘,)
- Click **Export...** to select which workstreams to save to a JSON file
- Click **Import...** to load workstreams from a JSON file
- Imported workstreams are added to your existing list

Great for sharing setups with teammates or backing up your configuration.

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌃⌥G | Open Quick Launch panel (global - works from any app) |
| ⌃⌥P | Open Window Switcher (global - works from any app) |
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

1. **Use the Window Switcher (⌃⌥P)** - Instantly jump between your Claude sessions without alt-tabbing through all your apps
2. **Distinct themes are automatic** - Random Theme automatically excludes your last 5 themes, so each new session looks different
3. **Set window titles** - Include the project name in the title for easy identification in the Window Switcher
4. **Use the command field** - Set `claude` to auto-start Claude Code when the terminal opens
5. **Organize by project** - Create one workstream per project with its directory pre-configured
6. **Use splits for related work** - Within a single themed window, use ⌘D to split for related tasks (e.g., running tests while coding)
7. **Auto-launch your daily setup** - Enable auto-launch on your most-used workstreams to open them automatically when the app starts

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
