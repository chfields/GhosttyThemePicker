# Capture Current Window as Workstream

## Goal
Add a feature to quickly save the current Ghostty window's configuration as a new workstream, reducing the friction of creating workstreams manually.

## Use Cases
1. User has a Ghostty window open in a project directory, wants to save it for future quick access
2. User discovers a nice setup organically and wants to persist it
3. Faster workflow than manually entering directory path in workstream editor

## Feature Entry Points

### Option A: From Window Switcher
Add a "Save as Workstream" button/action next to each window in the Window Switcher (⌃⌥P).

**Pros:**
- User can see all windows and pick which one to save
- Natural workflow: "I see this window, I want to save it"

**Cons:**
- Adds UI complexity to Window Switcher
- Requires keyboard shortcut or button per row

### Option B: From Menu Bar
Add "Save Current Window as Workstream..." menu item that captures the frontmost Ghostty window.

**Pros:**
- Simple, single action
- No changes to Window Switcher UI

**Cons:**
- User must ensure correct window is frontmost
- Less discoverable

### Option C: Both
Implement both for maximum flexibility.

**Recommendation:** Start with **Option B** (menu bar) for simplicity, add Window Switcher integration later if needed.

---

## Data We Can Capture

| Field | Source | Reliability |
|-------|--------|-------------|
| **Working Directory** | `lsof -d cwd` on shell process | High - already implemented |
| **Window Title** | Accessibility API / CGWindowList | High - already implemented |
| **Theme** | `launchedWindows` or `launchedThemes` cache | High for app-launched windows |
| **Command** | Cannot detect | N/A - user must enter |

### Theme Detection

Ghostty doesn't expose the current theme via any external API. However, **we can track themes for all windows launched by our app**:

| Launch Method | Theme Source | Cache |
|---------------|--------------|-------|
| Workstream | `workstream.theme` | `launchedWindows[pid] → workstream name → theme` |
| Random Theme | Theme name at launch | `launchedThemes[pid] → theme name` |
| Favorites | Theme name at launch | `launchedThemes[pid] → theme name` |
| Recent | Theme name at launch | `launchedThemes[pid] → theme name` |
| Manually opened | Unknown | User must select |

**Implementation:** Add `launchedThemes` cache alongside existing `launchedWindows`:

```swift
// In ThemeManager.swift
@Published var launchedWindows: [pid_t: String] = [:]  // pid -> workstream name (existing)
@Published var launchedThemes: [pid_t: String] = [:]   // pid -> theme name (new)
```

Update all theme launch methods to track:
```swift
func launchWithTheme(_ theme: String, ...) {
    // ... existing launch code ...
    let pid = process.processIdentifier
    launchedThemes[pid] = theme  // Track theme by PID
}
```

**Theme lookup priority:**
1. Check `launchedWindows[pid]` → get workstream → use `workstream.theme`
2. Check `launchedThemes[pid]` → use theme directly
3. Neither → show theme picker (user manually opened the window)

---

## Implementation Plan

### Phase 1: Core Feature (Menu Bar)

#### 1.1 Add Menu Item
```swift
// In AppDelegate or main menu setup
Button("Save Frontmost Window as Workstream...") {
    saveFrontmostWindowAsWorkstream()
}
.keyboardShortcut("S", modifiers: [.command, .shift])
```

#### 1.2 Implement Window Capture
```swift
func captureFrontmostGhosttyWindow() -> CapturedWindow? {
    // 1. Get frontmost Ghostty window via CGWindowList
    // 2. Get its PID
    // 3. Get shell cwd via lsof (reuse existing getCwd function)
    // 4. Look up theme:
    //    a. Check launchedWindows[pid] → workstream → theme
    //    b. Check launchedThemes[pid] → theme directly
    //    c. Neither → nil (user picks)
    // 5. Return CapturedWindow struct
}

struct CapturedWindow {
    let directory: String
    let title: String
    let theme: String?  // nil only if window was opened outside our app
    let pid: pid_t
}

func themeForPID(_ pid: pid_t) -> String? {
    // Check workstream first
    if let wsName = themeManager.launchedWindows[pid],
       let ws = themeManager.workstreams.first(where: { $0.name == wsName }) {
        return ws.theme
    }
    // Check direct theme launch
    return themeManager.launchedThemes[pid]
}
```

#### 1.3 Show Save Dialog
Present a sheet/dialog pre-populated with captured data:

**When theme is known (launched from app):**
```
┌─────────────────────────────────────────────────┐
│ Save Window as Workstream                       │
├─────────────────────────────────────────────────┤
│ Name:      [my-project____________]             │
│            (auto-filled from directory name)    │
│                                                 │
│ Directory: /Users/me/projects/my-project        │
│            ✓ Detected from window               │
│                                                 │
│ Theme:     Dracula                              │
│            ✓ Detected from launch               │
│                                                 │
│ Command:   [____________________]               │
│            (optional, e.g., "claude")           │
│                                                 │
│        [Cancel]              [Save Workstream]  │
└─────────────────────────────────────────────────┘
```

**When theme is unknown (manually opened window):**
```
┌─────────────────────────────────────────────────┐
│ Save Window as Workstream                       │
├─────────────────────────────────────────────────┤
│ Name:      [my-project____________]             │
│            (auto-filled from directory name)    │
│                                                 │
│ Directory: /Users/me/projects/my-project        │
│            ✓ Detected from window               │
│                                                 │
│ Theme:     [Select theme...      ▾]             │
│            (required - window opened externally)│
│                                                 │
│ Command:   [____________________]               │
│            (optional, e.g., "claude")           │
│                                                 │
│        [Cancel]              [Save Workstream]  │
└─────────────────────────────────────────────────┘
```

#### 1.4 Create Workstream
On save, create a new `Workstream` and add to `ThemeManager.workstreams`.

### Phase 2: Window Switcher Integration (Optional)

#### 2.1 Add Context Action
Add a secondary action to Window Switcher rows:
- Right-click context menu, OR
- Keyboard shortcut (e.g., ⌘S when row is selected), OR
- Small "+" button on hover

#### 2.2 Pass Selected Window
Instead of detecting frontmost window, pass the selected `GhosttyWindow` to the save dialog.

---

## UI/UX Details

### Auto-Generated Name
Derive suggested name from directory:
```swift
func suggestedName(from directory: String) -> String {
    let lastComponent = URL(fileURLWithPath: directory).lastPathComponent
    // Clean up: "my-project" -> "my-project"
    // Handle home dir: "~" -> "Home"
    return lastComponent.isEmpty ? "Untitled" : lastComponent
}
```

### Duplicate Detection
Check if workstream with same directory already exists:
- If yes, offer to update existing or create duplicate
- Show warning: "A workstream for this directory already exists: [name]"

### Theme Display
Two modes based on detection:

**Theme known:** Show as read-only text with checkmark (user can still change via dropdown if desired)

**Theme unknown:** Show required dropdown picker
- Pre-select "Random" or last used theme
- Standard theme list from ThemeManager

---

## Files to Modify

### Phase 0: Theme Tracking (Prerequisite)

1. **ThemeManager.swift**
   - Add `launchedThemes: [pid_t: String]` property
   - Update `launchWithTheme()` to store `launchedThemes[pid] = theme`
   - Update `launchFavorite()` to store theme
   - Update `launchRecent()` to store theme
   - Add `themeForPID(_ pid: pid_t) -> String?` helper

### Phase 1: Core Feature

2. **GhosttyThemePickerApp.swift**
   - Add `CapturedWindow` struct
   - Add `captureFrontmostGhosttyWindow()` function
   - Add `themeForPID()` lookup function
   - Add menu item with keyboard shortcut (⌘⇧S)
   - Add `SaveWorkstreamSheet` view

3. **ThemeManager.swift**
   - Add `createWorkstreamFromCapture(_:)` method
   - Handle duplicate directory detection

### Phase 2: Window Switcher Integration (Optional)

4. **WindowSwitcherView**
   - Add context menu or action button
   - Wire up to save dialog

---

## Edge Cases

1. **No Ghostty window open** - Show alert: "No Ghostty window found"
2. **Multiple Ghostty windows** - Use frontmost (Option B) or show picker (Option A)
3. **Can't detect directory** - Show alert or let user enter manually
4. **Window already matches a workstream** - Offer to open editor for that workstream instead
5. **Ghostty app not running** - Same as #1

---

## Testing Checklist

### Theme Tracking (Phase 0)
- [x] Launch with Random Theme → verify `launchedThemes[pid]` is set
- [ ] Launch from Favorites → verify `launchedThemes[pid]` is set
- [ ] Launch from Recent → verify `launchedThemes[pid]` is set
- [x] Launch Workstream → verify `launchedWindows[pid]` is set (existing)

### Window Capture (Phase 1)
- [ ] Save window launched via Random Theme → theme auto-filled
- [ ] Save window launched via Workstream → theme auto-filled from workstream
- [ ] Save window launched via Favorites → theme auto-filled
- [ ] Save window opened manually (outside app) → theme picker shown
- [ ] Save window in home directory
- [ ] Save window in nested project directory
- [ ] Attempt save with no Ghostty windows open
- [ ] Save with duplicate directory (existing workstream)
- [ ] Verify saved workstream launches correctly
- [ ] Test keyboard shortcut (⌘⇧S)

---

## Questions to Resolve

1. Should the save dialog be a sheet on the menu bar popover, or a standalone window?
2. Should we auto-detect "claude" command if Claude was running in the captured window?
3. For manually-opened windows (theme unknown), what default? Options:
   - "Random" (matches app's primary use case)
   - Last used theme
   - Force user to pick (safest)
