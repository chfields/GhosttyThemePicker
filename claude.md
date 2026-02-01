# GhosttyThemePicker - Development Notes

## Known Issues

### Screen Recording Permission Reset on Rebuild

**Issue**: Every time the app is rebuilt during development, macOS invalidates the Screen Recording permission and it needs to be removed and re-added.

**Why This Happens**:
- When Xcode builds the app, it generates a new code signature
- macOS tracks permissions by app bundle identifier + code signature
- A changed signature = macOS treats it as a "different" app
- The old permission entry becomes stale and needs to be cleared

**Workaround**:
1. Open **System Settings** → **Privacy & Security** → **Screen Recording**
2. Remove the old `GhosttyThemePicker` entry (if present)
3. Launch the rebuilt app
4. Grant Screen Recording permission when prompted
5. Restart the app if needed

**Permanent Solution for Development**:
To avoid this issue during development, you can:
- Use a stable Development certificate in Xcode's signing settings
- Add `com.apple.security.temporary-exception.apple-events` entitlement (though this doesn't fully solve Screen Recording)
- Sign the app with a Developer ID certificate (requires Apple Developer Program membership)

**Note**: This only affects development builds. Release builds signed with a proper Developer ID certificate won't have this issue.

## Features

### Window Switcher (⌃⌥P)
- **Arrow Keys (↑↓)**: Navigate through Ghostty windows
- **Enter**: Focus selected window and close panel
- **Esc**: Close panel without focusing
- **Search**: Type to filter windows by name
- **Visual Highlight**: Selected window shows blue accent background

### Quick Launch (⌃⌥G)
- Launch workstreams, favorites, or random themes
- Keyboard-driven workflow

## Architecture Notes

### Keyboard Navigation Implementation
- Uses custom `KeyHandlingPanel` (subclass of `NSPanel`) to intercept key events at the panel level
- This ensures arrow keys are captured even when the search TextField has focus
- `WindowSwitcherViewModel` is an `ObservableObject` that manages state and handles key events
- Panel's `sendEvent(_:)` override intercepts `.keyDown` events before they reach SwiftUI's responder chain

### Key Event Flow
1. User presses key → NSPanel receives event
2. `KeyHandlingPanel.sendEvent(_:)` intercepts event
3. Calls `keyHandler` closure (set by view)
4. Closure calls `viewModel.handleKeyDown(_:onDismiss:)`
5. If handled (arrow/enter), returns `true` to consume event
6. If not handled, passes to `super.sendEvent(_:)` for normal processing

This approach works better than `NSEvent.addLocalMonitorForEvents` because:
- Local monitors see events AFTER focused views process them
- TextField consumes arrow keys for cursor movement before monitor sees them
- Panel-level interception happens BEFORE responder chain processing
