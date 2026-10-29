#!/bin/bash
# Claude state hook - writes whether Claude is "asking" vs "waiting"
# This fires when Claude stops responding
# Installed by GhosttyThemePicker

# Read JSON input from stdin
INPUT=$(cat)

# Extract key fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')

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

# Default state
STATE="waiting"
PROMPT="null"

# A submitted prompt answers whatever was pending, so UserPromptSubmit always clears to "waiting".
# Otherwise (Stop), analyze Claude's last message
if [ "$EVENT" != "UserPromptSubmit" ]; then
    # Claude Code passes the final reply in the hook input; prefer it, since the transcript
    # may not have the reply written yet when this hook runs
    TEXT_CONTENT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')

    # Older Claude Code: get the last assistant message from the transcript (JSONL)
    if [ -z "$TEXT_CONTENT" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        TEXT_CONTENT=$(tail -100 "$TRANSCRIPT_PATH" | jq -s -r '
            [.[] | select(.type == "assistant" or .role == "assistant")] | last |
            (if .message then .message.content elif .content then .content else null end) |
            if type == "array" then
                [.[] | select(.type == "text") | .text] | join(" ")
            elif type == "string" then
                .
            else
                ""
            end
        ' 2>/dev/null)
    fi

    if [ -n "$TEXT_CONTENT" ]; then
        # Check for question indicators in the last non-empty line, where Claude asks (matching the
        # whole reply flags long answers that merely mention "can you" or "let me know" somewhere)
        # - Ends with ?
        # - Contains question patterns like "Would you like", "Do you want", "Should I"
        LAST_LINE=$(printf '%s\n' "$TEXT_CONTENT" | grep -E '\S' | tail -1)
        if echo "$LAST_LINE" | grep -qE '\?\s*$'; then
            STATE="asking"
        elif echo "$LAST_LINE" | grep -qiE '(would you like|do you want|should i|shall i|can you|could you|may i|let me know|please confirm|which.*prefer|what.*like)'; then
            STATE="asking"
        fi

        # Preview for the session sidebar: the question (last non-empty line), or else a recap
        # (the end of the reply, where the outcome and next step usually are, minus markdown
        # markers and code fences)
        if [ "$STATE" = "asking" ]; then
            PROMPT=$(jq -cn --arg text "$TEXT_CONTENT" '
                ($text | split("\n") | map(select(test("\\S"))) | last // "") as $line |
                {kind: "question", text: $line, options: [], more: 0}
            ')
        else
            PROMPT=$(jq -cn --arg text "$TEXT_CONTENT" '
                ($text | split("\n")
                    | map(select(test("\\S") and (test("^\\s*```") | not))
                          | gsub("\\*\\*"; "") | sub("^\\s*#+\\s*"; ""))
                    | join("\n") | .[-800:]) as $recap |
                if $recap == "" then null else {kind: "recap", text: $recap, options: [], more: 0} end
            ')
        fi
    fi
fi

# One state file per Claude process (or per directory if it can't be found)
if [ -n "$CLAUDE_PID" ]; then
    STATE_FILE="$STATE_DIR/state-pid-$CLAUDE_PID.json"
    # Per-process files pile up as sessions end; drop ones untouched for 2 days
    find "$STATE_DIR" -name 'state-pid-*.json' -mtime +2 -delete 2>/dev/null
else
    CWD_HASH=$(echo "$CWD" | md5 | cut -c1-8)
    STATE_FILE="$STATE_DIR/state-$CWD_HASH.json"
fi

# Write atomically so the app never reads a half-written file
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

# Exit successfully (don't block Claude from stopping)
exit 0
