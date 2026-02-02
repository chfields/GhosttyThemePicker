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

## Releasing New Versions

### 1. Build Release DMG
```bash
xcodebuild -scheme GhosttyThemePicker -configuration Release -derivedDataPath build clean build
mkdir -p /tmp/dmg-staging
cp -r build/Build/Products/Release/GhosttyThemePicker.app /tmp/dmg-staging/
hdiutil create -volname "GhosttyThemePicker" -srcfolder /tmp/dmg-staging -ov -format UDZO /tmp/GhosttyThemePicker.dmg
```

### 2. Create GitHub Release
```bash
# Tag the release
git tag -a v1.X.0 -m "v1.X.0 - Description"
git push origin v1.X.0

# Create release with DMG
gh release create v1.X.0 /tmp/GhosttyThemePicker.dmg --title "v1.X.0 - Title" --notes "Release notes here"
```

### 3. Update Homebrew Cask
```bash
# Calculate SHA256 of the new DMG
shasum -a 256 /tmp/GhosttyThemePicker.dmg

# Update the cask formula in homebrew-tap repo
cd /path/to/homebrew-tap
# Edit Casks/ghostty-theme-picker.rb:
#   - Update `version "1.X.0"`
#   - Update `sha256 "new-checksum-here"`
git add Casks/ghostty-theme-picker.rb
git commit -m "Update ghostty-theme-picker to v1.X.0"
git push
```

### Homebrew Tap
- **Repo:** https://github.com/chfields/homebrew-tap
- **Install:** `brew install --cask chfields/tap/ghostty-theme-picker`
