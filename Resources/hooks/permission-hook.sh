#!/bin/bash
# Permission prompt hook - marks state as "asking" when Claude needs permission
# This fires when Claude shows a permission dialog
# Installed by GhosttyThemePicker

# Read JSON input from stdin
INPUT=$(cat)

# Extract key fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Create state directory if needed
STATE_DIR="$HOME/.claude-states"
mkdir -p "$STATE_DIR"

# Permission prompts are always "asking"
STATE="asking"

# Write state file
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

exit 0
