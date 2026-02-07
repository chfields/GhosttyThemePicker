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

# Create state directory if needed
STATE_DIR="$HOME/.claude-states"
mkdir -p "$STATE_DIR"

# Default state
STATE="waiting"

# If we have a transcript, analyze Claude's last message
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Get the last assistant message from the transcript
    # The transcript is JSONL format with conversation turns
    LAST_ASSISTANT_MSG=$(tail -100 "$TRANSCRIPT_PATH" | jq -s '
        [.[] | select(.type == "assistant" or .role == "assistant")] | last |
        if .message then .message.content
        elif .content then .content
        else null end
    ' 2>/dev/null)

    # Check if the message ends with a question mark or contains question patterns
    if [ -n "$LAST_ASSISTANT_MSG" ] && [ "$LAST_ASSISTANT_MSG" != "null" ]; then
        # Extract text content (handle array of content blocks)
        TEXT_CONTENT=$(echo "$LAST_ASSISTANT_MSG" | jq -r '
            if type == "array" then
                [.[] | select(.type == "text") | .text] | join(" ")
            elif type == "string" then
                .
            else
                ""
            end
        ' 2>/dev/null)

        # Check for question indicators
        # - Ends with ?
        # - Contains question patterns like "Would you like", "Do you want", "Should I"
        if echo "$TEXT_CONTENT" | grep -qE '\?\s*$'; then
            STATE="asking"
        elif echo "$TEXT_CONTENT" | grep -qiE '(would you like|do you want|should i|shall i|can you|could you|may i|let me know|please confirm|which.*prefer|what.*like)'; then
            STATE="asking"
        fi
    fi
fi

# Write state file with session info
# Use CWD to derive a unique identifier for the terminal/project
CWD_HASH=$(echo "$CWD" | md5 | cut -c1-8)
STATE_FILE="$STATE_DIR/state-$CWD_HASH.json"

cat > "$STATE_FILE" << EOF
{
  "state": "$STATE",
  "session_id": "$SESSION_ID",
  "cwd": "$CWD",
  "timestamp": $(date +%s)
}
EOF

# Exit successfully (don't block Claude from stopping)
exit 0
