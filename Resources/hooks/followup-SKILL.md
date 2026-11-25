---
name: followup
description: Add, list, or check off follow-ups in GhosttyThemePicker's session sidebar. Use when the user says "remind me to…", "add a follow-up", "follow up on…", "what's on my follow-ups", or "mark that follow-up done", or at the end of a task that leaves something to come back to (CI running, waiting on a reply, a deploy to verify).
---

<!-- Installed by GhosttyThemePicker -->

# Follow-ups

Follow-ups are a short checklist at the top of GhosttyThemePicker's session sidebar. An item added
from this session links to this session's Ghostty window, so clicking it in the sidebar brings this
window back. Reminders send a macOS notification and float the item to the top.

Everything goes through one script:

```bash
~/.claude/hooks/followup.sh add "Check CI on PR #12"                 # no reminder
~/.claude/hooks/followup.sh add "Check CI on PR #12" --in 30m        # 30m, 2h, 1d
~/.claude/hooks/followup.sh add "Reply to Sam" --at "2026-11-25 09:00"  # local time
~/.claude/hooks/followup.sh list                                     # open items, with short ids
~/.claude/hooks/followup.sh done 1a2b3c4d                            # id from list
```

## Adding

- When the user asks for one, add it right away; don't ask for confirmation.
- Titles are short and actionable, under ~60 characters, and name the specific thing:
  "Check CI on PR #12", not "Follow up on the PR". Leave out the project name, since the
  item already links to this session.
- Turn times into `--in` or `--at`. Get today's date with `date` first. "after lunch" means 1 PM,
  "tomorrow" alone means 9 AM tomorrow, "end of day" means 5 PM, "later" means no reminder.
- Don't add one on your own. At the end of a task that leaves something pending (CI running,
  waiting on review, a deploy to verify), you may offer it in one line: "Want a follow-up to check
  CI in 30 minutes?". Add it only if the user says yes.

## Listing and checking off

- "What's on my follow-ups?" → run `list` and show the result as is.
- When you've handled an item (e.g. CI is green), or the user says it's done, run `list` to find
  its id, then `done <id>`.

## Errors

If the script says GhosttyThemePicker isn't running, tell the user. Don't retry, and don't
write the follow-up anywhere else.
