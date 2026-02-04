# Window Switcher Workstream Name Caching

## Problem

Workstream names in the Window Switcher take ~1 second to appear after opening the panel. Users see window titles first, then workstream names pop in after enrichment completes.

## What's Already Fast

- **Window titles** - Instant from Accessibility API
- **Claude status from title** - Instant (checks for ✳ or spinner in title)
- `workstreamNameForPID()` lookup - Instant if PID is in `launchedWindows` cache

## What's Slow

- `getShellCwd()` - Calls `lsof` per window (~50-100ms each)
- `hasClaudeProcess()` - Process tree scan (only used as fallback when title has no indicators)

The `lsof` calls are the bottleneck. With 5 windows, that's 250-500ms delay.

## Current Caching

```swift
// ThemeManager.swift
launchedWindows: [pid_t: String] = [:]  // PID → workstream name (app-launched only)
```

**Gap:** Only contains windows launched via the app. Manually opened terminals require `lsof` to get CWD for directory matching.

## Solution: Cache Workstream Names by PID

### Strategy

1. **Show cached workstream names immediately** - Before any enrichment
2. **Cache results for manually opened windows** - After first lookup
3. **Only call `lsof` for truly unknown windows**

### Implementation

#### Step 1: Add Runtime Cache

```swift
// In WindowSwitcherViewModel
private var workstreamCache: [pid_t: String?] = [:]  // nil = checked, no match
```

#### Step 2: Apply Cache Before Display

```swift
func loadWindows() {
    let windows = loadWindowsViaAccessibilityAPI()

    // Apply cached workstream names IMMEDIATELY
    for i in windows.indices {
        let pid = windows[i].pid
        // Check app-launched windows first (always authoritative)
        if let name = themeManager?.launchedWindows[pid] {
            windows[i].workstreamName = name
        }
        // Then check our runtime cache
        else if let cached = workstreamCache[pid] {
            windows[i].workstreamName = cached
        }
    }

    // Display immediately with whatever we have
    self.windows = windows

    // Enrich only unknown windows in background
    enrichUnknownWindows(windows)
}
```

#### Step 3: Smart Enrichment

Only call `lsof` for windows not in any cache:

```swift
func enrichUnknownWindows(_ windows: [GhosttyWindow]) {
    let unknownPids = windows.filter { window in
        themeManager?.launchedWindows[window.pid] == nil &&
        workstreamCache[window.pid] == nil
    }.map { $0.pid }

    guard !unknownPids.isEmpty else {
        // Still need to check hasClaudeProcess for fallback detection
        enrichClaudeStatusOnly(windows)
        return
    }

    DispatchQueue.global(qos: .userInitiated).async {
        for pid in unknownPids {
            let cwd = self.getShellCwd(ghosttyPid: pid)
            let wsName = self.themeManager?.workstreamNameForPID(pid, shellCwd: cwd)

            // Cache the result (even if nil)
            self.workstreamCache[pid] = wsName
        }

        DispatchQueue.main.async {
            self.applyWorkstreamCache()
        }
    }
}
```

#### Step 4: Cache Cleanup

Clear stale entries when windows close:

```swift
func cleanupCache(activePids: Set<pid_t>) {
    workstreamCache = workstreamCache.filter { activePids.contains($0.key) }
}
```

### What About `hasClaudeProcess`?

The `hasClaudeProcess` fallback is only needed when:
- Window title doesn't contain ✳ (waiting) or spinner (working)
- We want to show a "Claude" badge anyway

**Options:**
1. **Skip it** - Only show Claude status when title has indicators (recommended)
2. **Cache briefly** - Cache process tree for ~5 seconds
3. **Keep as-is** - Always scan (current behavior)

**Recommendation:** Option 1. If users want Claude status, they should use Claude Code's dynamic titles. The fallback adds complexity for edge cases.

## Expected Improvement

| Scenario | Before | After |
|----------|--------|-------|
| All windows app-launched | ~500ms | Instant |
| Repeat opens (any windows) | ~500ms | Instant |
| First open with manual windows | ~500ms | ~500ms (unavoidable) |

## Summary of Changes

1. Add `workstreamCache: [pid_t: String?]` to WindowSwitcherViewModel
2. Apply cache in `loadWindows()` before displaying
3. Skip `lsof` for cached PIDs in enrichment
4. Clean up cache when windows close

## Complexity

| Change | Effort |
|--------|--------|
| Add cache dictionary | 5 min |
| Apply cache before display | 10 min |
| Skip cached in enrichment | 10 min |
| Cache cleanup | 5 min |

**Total: ~30 minutes**
