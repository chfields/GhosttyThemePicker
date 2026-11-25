# Plan: Follow-ups in the Session Sidebar

## Goal
A short checklist pinned at the top of the session sidebar, for things to come back to ("check CI on #12",
"reply to Sam"). Items can link to a session; clicking a linked item focuses that window. Items survive
window closes and app restarts. Later, Claude sessions add items themselves via a skill.

Shipped in two PRs.

## PR 1 — Store + sidebar section (manual entry)

### Data model — `FollowUps.swift` (new file, added to the Xcode project)
```swift
struct FollowUp: Codable, Identifiable {
    let id: UUID
    var title: String
    var createdAt: Date
    var doneAt: Date?
    var remindAt: Date?
    var link: SessionLink?
}

struct SessionLink: Codable, Equatable {
    var workstreamName: String?   // preferred: stable across relaunches
    var cwd: String?              // fallback for windows with no workstream
    var label: String             // last-known displayName, shown when the window is closed
}
```

`FollowUpStore` (`ObservableObject`, `shared`):
- `@Published items`, saved as JSON to `~/Library/Application Support/GhosttyThemePicker/followups.json`
  on every change (atomic write). Loaded at init; a corrupt file is moved aside, not overwritten.
- `add(title:link:remindAt:)`, `update`, `toggleDone`, `delete`, `setReminder`.
- `window(for link:, in windows:)` resolves a link to a live `GhosttyWindow`: workstream name match first,
  then `shellCwd` match. That gives "reconnect when the session reopens" for free.
- Done items hide after ~3s. Items done more than 7 days ago are pruned at load.

### Reminders
- `remindAt` presets: 1 hour, 4 hours, tomorrow 9 AM.
- Scheduled as `UNNotificationRequest` with the item's id; cancelled on done/delete/re-schedule.
  Authorization is requested the first time a reminder is set (not at launch).
- A due item (remindAt ≤ now, not done) sorts to the top with an orange dot. A 30s timer refreshes this.

### Sidebar UI — `SessionSidebar.swift`
Section above the session groups (under the filter field):

```
FOLLOW-UPS (3)              ＋  ▾
○ Check CI on PR #12
  ↳ GhosttyThemePicker   · 2h
○ Reply to Sam re: deploy
                      ⏰ 3:00 PM
```

- Header: title + open count, ＋ (add), ▾/▸ collapse. Collapsed shows `FOLLOW-UPS ③ next: <title>`.
  Collapse state in `@AppStorage`.
- Hidden entirely when there are no open items and the add field is closed; ＋ moves to the sidebar
  header then, so the section costs no space when unused.
- Add field: text field (↩ adds, Esc cancels), link picker (None + current sessions), reminder picker.
- Row: circle = toggle done; click text = focus linked window (if open); "(closed)" suffix otherwise.
- Context menu: Edit, Remind in… (1h / 4h / Tomorrow / Clear), Unlink, Delete.
- Session rows: right-click → "Add Follow-up…" (opens the add field pre-linked); a 📌 count badge on rows
  that have open follow-ups.
- The filter field also filters follow-ups by title.

Order: due items first, then by creation (oldest first). Drag-to-reorder is deferred.

## PR 2 — API + Claude skill

### API (`APIServer.swift`)
- `GET  /api/followups` → open items
- `POST /api/followups` `{title, remindAt?, claudePid?, cwd?}` → app maps `claudePid` to its Ghostty
  window (same mapping the state hook uses) and stores a `SessionLink`; falls back to `cwd`.
- `POST /api/followups/<id>/done`

### Skill (installed by `HookInstaller` into `~/.claude/skills/followup/`)
- `followup.sh add|list|done` — walks up to the `claude` PID like `claude-state-hook.sh`, reads the port
  from `~/.ghostty-api-port`, curls the API. Works from any shell too.
- `SKILL.md` — when to use it ("remind me…", "add a follow-up", "what's on my follow-ups"), write
  short titles, convert "after lunch"/"tomorrow" to times, offer (never silently add) a follow-up at
  the end of a task, mark items done once handled.
- Same installed/needs-update check as the hooks.

## Testing
- Manual in the Debug build: add/edit/done/delete, link + focus, closed-window label, reopen reconnects,
  collapse, reminder notification fires, restart keeps items.
- PR 2: `followup.sh` against a running app; skill invoked from a Claude session.
