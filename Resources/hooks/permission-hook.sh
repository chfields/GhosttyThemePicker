#!/bin/bash
# Permission prompt hook - marks state as "asking" when Claude needs permission
# This fires when Claude shows a permission dialog (Notification) or asks a
# question with AskUserQuestion (PreToolUse). Also records what is being asked
# so the session sidebar can preview it.
# Installed by GhosttyThemePicker

# Read JSON input from stdin
INPUT=$(cat)

# Extract key fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Create state directory if needed
STATE_DIR="$HOME/.claude-states"
mkdir -p "$STATE_DIR"

# The Claude process this hook runs under: the app maps it to its Ghostty window, so sessions
# sharing a directory don't share a state
CLAUDE_PID=""
p=$PPID
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    if [ "$(basename "$(ps -o comm= -p "$p")")" = "claude" ]; then
        CLAUDE_PID=$p
        break
    fi
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
done

# Permission prompts are always "asking"
STATE="asking"

# What is being asked: {"kind", "text", "options", "more"}
PROMPT="null"
if [ "$EVENT" = "PreToolUse" ]; then
    # AskUserQuestion: first question, its option labels, and how many more questions follow
    PROMPT=$(echo "$INPUT" | jq -c '
        .tool_input.questions as $qs |
        if ($qs | type) == "array" and ($qs | length) > 0 then
            {kind: "question",
             text: ($qs[0].question // ""),
             options: [($qs[0].options // [])[] | .label // empty],
             more: (($qs | length) - 1)}
        else null end
    ' 2>/dev/null)
elif [ "$EVENT" = "Notification" ]; then
    # The permission request should be for the last tool call in the transcript; the message
    # only names the tool ("Claude needs your permission to use Bash"), so use it to check
    MESSAGE=$(echo "$INPUT" | jq -r '.message // empty')
    TOOL=""
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        TOOL=$(tail -50 "$TRANSCRIPT_PATH" | jq -s -r '
            [.[] | (.message.content // .content // empty)
                 | if type == "array" then .[] else empty end
                 | select(.type? == "tool_use")] | last //
            empty |
            .name + ": " + (
                .input.command // .input.file_path // .input.notebook_path //
                .input.url // .input.pattern // .input.query //
                ([.input[]? | strings] | first) // ""
            )
        ' 2>/dev/null)
    fi
    # Fall back to the message if the transcript's last tool call isn't the one being asked about
    TOOL_NAME="${TOOL%%:*}"
    if [ -z "$TOOL" ] || ! echo "$MESSAGE" | grep -qw -- "$TOOL_NAME"; then
        TOOL=""
    fi
    PROMPT=$(jq -cn --arg tool "$TOOL" --arg msg "$MESSAGE" '
        {kind: "permission", text: (if $tool != "" then $tool else $msg end), options: [], more: 0}
    ')
fi
[ -z "$PROMPT" ] && PROMPT="null"

# Write state file atomically so the app never reads a half-written file
if [ -n "$CLAUDE_PID" ]; then
    STATE_FILE="$STATE_DIR/state-pid-$CLAUDE_PID.json"
    # Per-process files pile up as sessions end; drop ones untouched for 2 days
    find "$STATE_DIR" -name 'state-pid-*.json' -mtime +2 -delete 2>/dev/null
else
    CWD_HASH=$(echo "$CWD" | md5 | cut -c1-8)
    STATE_FILE="$STATE_DIR/state-$CWD_HASH.json"
fi

jq -n \
    --arg state "$STATE" \
    --arg session "$SESSION_ID" \
    --arg cwd "$CWD" \
    --argjson timestamp "$(date +%s)" \
    --argjson prompt "$PROMPT" \
    --argjson claude_pid "${CLAUDE_PID:-null}" \
    --arg transcript "$TRANSCRIPT_PATH" \
    '{state: $state, session_id: $session, cwd: $cwd, timestamp: $timestamp, prompt: $prompt, claude_pid: $claude_pid, transcript_path: $transcript}' \
    > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

exit 0
