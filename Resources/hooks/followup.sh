#!/bin/bash
# followup.sh - add, list, or check off follow-ups in GhosttyThemePicker's session sidebar
# Installed by GhosttyThemePicker
#
#   followup.sh add "Check CI on PR #12" [--in 30m|2h|1d] [--at "YYYY-MM-DD HH:MM"]
#   followup.sh list
#   followup.sh done <id>        (the short id that list prints)
#
# Run from a Claude Code session, a new item links to that session's Ghostty window.

set -u

die() { echo "followup: $*" >&2; exit 1; }

command -v jq >/dev/null || die "needs jq (brew install jq)"

# The app's API port: the port file, else probe the range it picks from (the file goes missing
# when a second copy of the app quits)
api_port() {
    local port
    port=$(cat "$HOME/.ghostty-api-port" 2>/dev/null)
    if [ -n "$port" ] && curl -s -m 1 "http://127.0.0.1:$port/api/health" >/dev/null; then
        echo "$port"; return 0
    fi
    for port in $(seq 49876 49885); do
        if curl -s -m 1 "http://127.0.0.1:$port/api/health" | grep -q '"ok"'; then
            echo "$port"; return 0
        fi
    done
    return 1
}

PORT=$(api_port) || die "GhosttyThemePicker isn't running (no API on ports 49876-49885)"
BASE="http://127.0.0.1:$PORT/api/followups"

# The Claude process this runs under, which the app maps to its Ghostty window
claude_pid() {
    local p=$PPID
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
        if [ "$(basename "$(ps -o comm= -p "$p")")" = "claude" ]; then
            echo "$p"; return
        fi
        p=$(ps -o ppid= -p "$p" | tr -d ' ')
    done
}

# Print a follow-up (JSON on stdin) as "abcd1234  Title  ↳ session  ⏰ time"
format='"\(.shortId)  \(.title)"
    + (if .session then "  ↳ \(.session)\(if .sessionOpen then "" else " (closed)" end)" else "" end)
    + (if .remindAt then "  ⏰ \(.remindAt | fromdateiso8601 | strflocaltime("%a %b %-d %-I:%M %p"))" else "" end)'

# Fail on an API error, printing its message
check() {
    local body=$1
    local err
    err=$(echo "$body" | jq -r '.error // empty' 2>/dev/null)
    [ -n "$err" ] && die "$err"
    [ -z "$body" ] && die "no response from the app"
    return 0
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
    add)
        title=""
        remind=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --in)
                    [ $# -ge 2 ] || die "--in needs a duration like 30m, 2h or 1d"
                    n=${2%[mhd]}; unit=${2: -1}
                    [[ "$n" =~ ^[0-9]+$ ]] || die "bad duration '$2' (use 30m, 2h, 1d)"
                    case "$unit" in m) secs=$((n * 60));; h) secs=$((n * 3600));; d) secs=$((n * 86400));; *) die "bad duration '$2'";; esac
                    remind=$(date -u -r $(( $(date +%s) + secs )) +%Y-%m-%dT%H:%M:%SZ)
                    shift 2;;
                --at)
                    [ $# -ge 2 ] || die "--at needs a local time like \"2026-11-25 09:00\""
                    epoch=$(date -j -f "%Y-%m-%d %H:%M" "$2" +%s 2>/dev/null) || die "bad time '$2' (use \"YYYY-MM-DD HH:MM\", local time)"
                    remind=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)
                    shift 2;;
                *)
                    title="${title:+$title }$1"
                    shift;;
            esac
        done
        [ -n "$title" ] || die "usage: followup.sh add \"title\" [--in 2h | --at \"YYYY-MM-DD HH:MM\"]"

        pid=$(claude_pid)
        payload=$(jq -cn --arg title "$title" --arg remind "$remind" --arg pid "$pid" --arg cwd "$PWD" '
            {title: $title, cwd: $cwd}
            + (if $remind != "" then {remindAt: $remind} else {} end)
            + (if $pid != "" then {claudePid: ($pid | tonumber)} else {} end)')
        body=$(curl -s -m 5 -X POST -H 'Content-Type: application/json' --data "$payload" "$BASE")
        check "$body"
        echo "Added: $(echo "$body" | jq -r "$format")"
        ;;
    list)
        body=$(curl -s -m 5 "$BASE")
        check "$body"
        if [ "$(echo "$body" | jq '.followups | length')" = "0" ]; then
            echo "No open follow-ups."
        else
            echo "$body" | jq -r ".followups[] | $format"
        fi
        ;;
    done)
        [ $# -ge 1 ] || die "usage: followup.sh done <id>"
        body=$(curl -s -m 5 -X POST "$BASE/$1/done")
        check "$body"
        echo "Done: $(echo "$body" | jq -r "$format")"
        ;;
    *)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        [ -z "$cmd" ] || [ "$cmd" = "help" ] || [ "$cmd" = "-h" ] || exit 1
        ;;
esac
