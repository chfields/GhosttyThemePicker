# Feature Ideas

## Implemented

| Feature | Description | Status |
|---------|-------------|--------|
| Random Theme | Launch with random theme (⌘R) | ✅ Done |
| Distinct Themes | Random excludes last 5 themes | ✅ Done |
| Workstreams | Named presets with theme, directory, title, command, extra args | ✅ Done |
| Favorites | Star themes for quick access | ✅ Done |
| Recent Themes | Last 5 themes used | ✅ Done |
| Launch in Directory | Open in specific folder | ✅ Done |
| Menu Bar Only | No dock icon (LSUIElement) | ✅ Done |
| Global Hotkey | ⌃⌥G opens Quick Launch panel from anywhere | ✅ Done |
| Theme Preview | Color swatches in Quick Launch panel and theme picker (with tooltips) | ✅ Done |
| Auto-launch | Configured workstreams open automatically on app startup | ✅ Done |
| Theme Categories | Filter themes by Dark/Light in theme picker | ✅ Done |
| Exclude List | Hide themes from random rotation | ✅ Done |
| Window Switching | List and switch between Ghostty windows | ⏸️ Paused (needs code signing) |

## Not Yet Implemented

### High Priority

| Feature | Description | Complexity |
|---------|-------------|------------|
| Copy Theme Name | Copy current theme to clipboard | Easy |

### Low Priority / Future

| Feature | Description | Complexity |
|---------|-------------|------------|
| Theme Search | Search all themes in menu | Easy |
| Import/Export | Share workstream configurations | Easy |
| Sync | iCloud sync for workstreams/favorites | Hard |

## Technical Notes

### Window Switching
- Requires Accessibility permission
- Uses AppleScript to list windows via System Events
- Unsigned apps have issues with Accessibility permissions
- May need code signing to work reliably

### Global Hotkey (Implemented)
- Uses Carbon API `RegisterEventHotKey` (works without Accessibility permission!)
- NSEvent.addGlobalMonitorForEvents requires Accessibility - Carbon does not
- Opens a floating Quick Launch panel with workstreams, favorites, and recent themes
- Panel dismisses on selection or Esc key

### Theme Categories
- Would need to parse theme files or maintain a curated list
- Ghostty themes are at `/Applications/Ghostty.app/Contents/Resources/themes/`
- Could analyze colors to auto-categorize

## User Requests
- "distinct themes" - avoid similar themes for running sessions
- "splits" - documented Ghostty keybindings (⌘D, ⌘⇧D)
- "jump between sessions" - window switching feature
