# Detect Claude Waiting for Input in Ghostty Windows

## Goal
Surface Ghostty windows where Claude is waiting for user input at the top of the Window Switcher (⌃⌥P), making it easy to quickly respond to Claude.

## Current State
- Window Switcher lists all Ghostty windows via Accessibility API
- Shows window titles (which Ghostty sets to current directory or custom title)
- Can match windows to workstreams by `windowTitle`
- Requires Screen Recording permission

## Detection Approaches

### Option 1: Parse Window/Tab Title (Simplest)
**How it works**: Claude Code sets specific terminal titles when in different states.

**Pros**:
- Already have access to window titles via Accessibility API
- No additional permissions needed
- Fast and lightweight

**Cons**:
- Requires Claude Code to set a specific title (need to verify behavior)
- May not work if user has custom shell prompt that overrides title

**Investigation needed**:
- [ ] Check what title Claude Code sets when waiting for input
- [ ] Test with `echo -ne "\033]0;Claude Waiting\007"` to see if Ghostty respects it

---

### Option 2: Screen Content OCR (Most Reliable)
**How it works**: Capture window content, OCR it, look for Claude's prompt pattern.

**Pros**:
- Works regardless of title settings
- Can detect exact prompt state (e.g., `>` character at end of output)
- Already have Screen Recording permission

**Cons**:
- Performance cost (screenshot + OCR per window)
- Need Vision framework or third-party OCR
- May be slow with many windows

**Implementation sketch**:
```swift
func hasClaudeWaitingPrompt(windowElement: AXUIElement) -> Bool {
    // 1. Get window bounds
    // 2. Capture CGWindowListCreateImage for that rect
    // 3. Run VNRecognizeTextRequest on image
    // 4. Check if last line matches Claude prompt pattern
}
```

---

### Option 3: Process Tree Analysis (Medium Complexity)
**How it works**: Find Claude processes, trace parent PIDs back to Ghostty windows.

**Pros**:
- Detects Claude running (vs other programs)
- Could detect idle vs busy state via process state

**Cons**:
- Doesn't distinguish "waiting for input" from "running"
- Complex PID → window mapping
- Claude subprocess might not be visible if running inside container/shell

**Implementation sketch**:
```bash
# Find claude processes
ps aux | grep -E 'claude|node.*claude'
# Get parent PID chain to find terminal
```

---

### Option 4: Terminal Content via Accessibility (Ideal if Possible)
**How it works**: Query Ghostty's text content via AXUIElement.

**Pros**:
- Direct access to terminal text
- No screenshot/OCR needed
- Real-time

**Cons**:
- Ghostty may not expose terminal content via Accessibility
- Need to investigate AXUIElement attributes available

**Investigation needed**:
- [ ] Query all AXUIElement attributes on Ghostty window
- [ ] Check for AXValue, AXText, or similar containing terminal content

---

### Option 5: Claude Code Status File/Socket (Most Elegant)
**How it works**: Claude Code writes state to a known location, app reads it.

**Pros**:
- Explicit, reliable signal
- No heuristics or parsing
- Could include rich metadata (session ID, last prompt, etc.)

**Cons**:
- Requires Claude Code to support this (feature request)
- Not available today

**Potential file location**:
- `~/.claude/status/<session-id>.json`
- `/tmp/claude-code-<pid>.status`

---

## Recommended Approach

### Phase 1: Window Title Detection (Ship First)
1. Investigate what titles Claude Code sets in different states
2. Add `isClaudeWaiting` computed property to `GhosttyWindow`
3. Sort windows with Claude waiting at top
4. Add visual indicator (icon or badge)

### Phase 2: Fallback to OCR (If Title Unreliable)
1. For windows without detectable Claude title, optionally OCR
2. Cache results to avoid repeated scanning
3. Add refresh button to re-scan

### Phase 3: Request Claude Code Feature
1. File issue requesting explicit "waiting for input" signal
2. Could be env var, file, or accessibility label

---

## UI Changes to Window Switcher

```
┌─────────────────────────────────────────────┐
│ 🪟 Switch Window                       ⌃⌥P │
├─────────────────────────────────────────────┤
│ [Search windows...]                         │
├─────────────────────────────────────────────┤
│ ── Claude Waiting ──                        │
│ ⏳ 🖥️ claude-code ~/projects/foo            │  ← Blue highlight, waiting icon
│ ⏳ 🖥️ DevWorkstream                         │
├─────────────────────────────────────────────┤
│ ── Other Windows ──                         │
│ 🖥️ ~/projects/bar                           │
│ 🖥️ npm running...                           │
├─────────────────────────────────────────────┤
│ ↑↓ Navigate • Enter Select • Esc Close      │
└─────────────────────────────────────────────┘
```

---

## Experiment Results (2024)

### Finding 1: Claude Code Uses Window Title for State!

Claude Code sets the terminal window title with a prefix character indicating state:

| Character | Unicode | Meaning |
|-----------|---------|---------|
| `✳` | U+2733 (Eight Spoked Asterisk) | **Waiting for input** |
| `⠐⠂⠁⠄⠈⠠⡀⢀` | U+2810, U+2802, etc. (Braille) | **Working** (animated spinner) |

**Example titles observed:**
- `✳ Claude Code` - idle, waiting for user input
- `⠐ Claude Code` - actively processing

### Finding 2: CGWindowList API Works

Can reliably get window titles via `CGWindowListCopyWindowInfo`:
```swift
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
// Filter for Ghostty, read kCGWindowName
```

### Finding 3: Accessibility API Needs App Permission

Command-line swift can't access Accessibility API, but the app already has this working via `AXUIElementCopyAttributeValue` with `kAXTitleAttribute`.

### Finding 4: Custom Window Titles Block Claude's Title Updates

Ghostty's `--title` option sets a **fixed** title that ignores escape sequences. Workstreams using `windowTitle` won't show Claude's `✳` prefix.

**Ghostty docs confirm:**
> "This will force the title of the window to be this title at all times and Ghostty will ignore any set title escape sequences programs may send."

### Finding 5: Process Tree Detection Works!

Can trace Claude processes back to their parent Ghostty window PID:

```
Claude → Ghostty Mapping:
  Claude 76316 → Ghostty 76312 ("L1-Backend")
  Claude 61852 → Ghostty 61850 ("Frontend")
  Claude 20772 → Ghostty 20118 ("✳ Claude Code")
  ...
```

**Method:**
1. Get all Ghostty window PIDs via `CGWindowListCopyWindowInfo`
2. Find all `claude` processes via `ps`
3. Walk up parent PID chain using `sysctl(KERN_PROC_PID)`
4. Stop when we find a Ghostty PID

**Limitation:** Can detect that Claude is **running** in a window, but cannot distinguish "waiting for input" from "processing" for windows with custom titles.

---

## Implementation Plan

### Phase 1: Full Detection (Title + Process Tree + Directory Matching)

**Strategy:**
1. **Remove `--title` from workstream launches** - Let Claude control the title
2. **Track launched windows by PID** - Store PID → workstream name at launch
3. **Match orphan windows by directory** - Get shell cwd, match to workstream.directory
4. **Detect Claude status from title** - `✳` = waiting, Braille = working

**Data model:**
```swift
enum ClaudeState {
    case notRunning       // No Claude in this window
    case running          // Claude detected via process tree (can't tell state)
    case waiting          // Claude waiting for input (✳ detected in title)
    case working          // Claude processing (spinner in title)
}

struct GhosttyWindow: Identifiable {
    let id: Int
    let name: String              // Window title (e.g., "✳ Claude Code")
    let axIndex: Int
    let pid: pid_t
    var workstreamName: String?   // Matched workstream (via PID cache or directory)
    var shellCwd: String?         // Current working directory of shell
    var hasClaudeProcess: Bool = false

    var claudeState: ClaudeState {
        // Check title for exact state (works when no --title override)
        if let firstChar = name.first {
            if firstChar == "✳" && name.contains("Claude") {
                return .waiting
            }
            let spinnerChars: Set<Character> = ["⠁", "⠂", "⠄", "⠈", "⠐", "⠠", "⡀", "⢀"]
            if spinnerChars.contains(firstChar) && name.contains("Claude") {
                return .working
            }
        }
        // Fall back to process detection
        return hasClaudeProcess ? .running : .notRunning
    }

    var displayName: String {
        // Prefer workstream name, fall back to title
        workstreamName ?? name
    }
}
```

**Workstream matching (for windows not launched by app):**
```swift
func matchWorkstreamByDirectory(cwd: String, workstreams: [Workstream]) -> String? {
    // Exact match
    if let ws = workstreams.first(where: { $0.directory == cwd }) {
        return ws.name
    }
    // Subdirectory match (window in child of workstream dir)
    if let ws = workstreams.first(where: {
        guard let dir = $0.directory else { return false }
        return cwd.hasPrefix(dir + "/")
    }) {
        return ws.name
    }
    return nil
}
```

**Getting shell cwd:**
```swift
func getShellCwd(ghosttyPid: pid_t) -> String? {
    // 1. Find login child: ps -eo pid,ppid,comm | grep login
    // 2. Find shell under login
    // 3. Get cwd: lsof -a -p <shell_pid> -d cwd -F n
    // 4. Parse output for "n/path/to/dir"
}
```

**Window loading flow:**
```swift
func loadWindows() {
    // 1. Get all Ghostty windows via CGWindowList/Accessibility API
    // 2. For each window:
    //    a. Check launchedWindowsCache[pid] for workstream name
    //    b. If not found, get shell cwd and match to workstream.directory
    //    c. Scan process tree for claude child
    // 3. Sort by claudeState priority
}
```

**Sorting priority:**
1. `.waiting` - Claude needs your input (highest)
2. `.running` - Claude detected but state unknown
3. `.working` - Claude processing (spinner)
4. `.notRunning` - No Claude

**UI Display:**
```
┌─────────────────────────────────────────────────┐
│ ── Needs Input ──                               │
│ ⏳ Frontend           ✳ Claude Code             │
│ ⏳ L1-Backend         ✳ Claude Code             │
├─────────────────────────────────────────────────┤
│ ── Working ──                                   │
│ ⚙️ Voicescribe        ⠐ Claude Code             │
├─────────────────────────────────────────────────┤
│ ── Other ──                                     │
│    job-workers        ~/projects/workers        │
│    (unknown)          ~/Desktop                 │
└─────────────────────────────────────────────────┘
```

**UI Indicators:**
| State | Icon | Shows |
|-------|------|-------|
| waiting | ⏳ | `[Workstream] ✳ Claude Code` |
| running | 🤖 | `[Workstream] (Claude)` |
| working | ⚙️ | `[Workstream] ⠐ Claude Code` |
| notRunning | - | `[Workstream] [cwd or title]` |

---

## Questions Resolved

1. **What title does Claude Code set when waiting?**
   - ✅ `✳ Claude Code` when waiting, Braille spinner when working

2. **Does custom title break detection?**
   - ✅ Yes - Ghostty's `--title` sets a fixed title, ignores escape sequences
   - Workaround: Use process tree detection for windows with custom titles

3. **Can we map Claude processes to windows?**
   - ✅ Yes - Walk parent PID chain from claude process to Ghostty PID

4. **Can we detect "waiting" for custom-titled windows?**
   - ❌ No - Process state (sleeping vs running) isn't reliable
   - Accept this limitation: show "Claude running" instead of exact state

---

## Next Steps

- [x] Experiment: Check Claude Code window title behavior
- [x] Experiment: Verify custom titles block title updates
- [x] Experiment: Implement process tree detection
- [x] Experiment: Implement directory → workstream matching

### Implementation Tasks

1. **Modify workstream launch** (ThemeManager.swift)
   - [x] Remove `--title` argument from `launchWorkstream()`
   - [x] Store launched PID in a cache: `launchedWindows[pid] = workstreamName`
   - [ ] Persist cache (or rebuild on app launch) - skipped for now, cache resets on app restart

2. **Add directory matching** (ThemeManager.swift + WindowSwitcherViewModel)
   - [x] Implement `getShellCwd(ghosttyPid:)` using lsof
   - [x] Implement `workstreamForDirectory()` and `workstreamNameForPID()`

3. **Update GhosttyWindow model** (GhosttyThemePickerApp.swift)
   - [x] Add `ClaudeState` enum with `.notRunning`, `.working`, `.running`, `.waiting`
   - [x] Add `workstreamName`, `shellCwd`, `hasClaudeProcess` fields
   - [x] Add `claudeState` computed property (checks title for ✳/spinner, falls back to process detection)
   - [x] Add `displayName` computed property

4. **Update window loading** (GhosttyThemePickerApp.swift)
   - [x] Add `enrichWindows()` to populate workstream names and Claude detection
   - [x] Add process tree scan for Claude detection (`hasClaudeProcess()`, `traceToGhostty()`)
   - [x] Sort windows by claudeState priority (waiting > running > working > notRunning)

5. **Update UI** (GhosttyThemePickerApp.swift)
   - [x] Add section headers (Needs Input / Claude / Working)
   - [x] Add state icons (hourglass, terminal, gearshape)
   - [x] Show `[Workstream] [Title]` format with badge for "running" state

6. **Testing**
   - [ ] Test with windows launched from app (PID cache)
   - [ ] Test with windows opened manually (directory matching)
   - [ ] Test with Claude in various states
   - [ ] Test with non-Claude windows
