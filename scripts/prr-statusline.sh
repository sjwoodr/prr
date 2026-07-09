#!/usr/bin/env bash
# prr status line for Claude Code (optional, opt-in via settings.json).
#
# Claude Code pipes a JSON status blob on stdin. We read its session_id and, if
# setup-review.sh has left a session-scoped "reviewing" file for this session,
# print it. Otherwise fall back to the working directory + git branch (no model).
# Keyed by session id so parallel fan-out panes never show each other's PR.
# Output is capped so a very long branch name or deep path can't overrun the bar.
#
# No `set -e`: a status line should always emit something and never abort a render.

MAX_WIDTH=65

emit() {
  # Single line, capped to MAX_WIDTH with a trailing ... marker when trimmed.
  local s="${1%%$'\n'*}"
  if [ "${#s}" -gt "$MAX_WIDTH" ]; then
    s="${s:0:$((MAX_WIDTH - 3))}..."
  fi
  printf '%s' "$s"
}

in="$(cat)"

sid="$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)"
# jq-free fallback if jq is not on PATH for the status-line invocation.
if [ -z "${sid:-}" ]; then
  sid="$(printf '%s' "$in" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi

state="/tmp/prr-status-${sid:-nosession}"
if [ -f "$state" ]; then
  emit "$(cat "$state")"
  exit 0
fi

# Idle: home-abbreviated cwd + git branch (no model).
cwd="$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[ -n "${cwd:-}" ] || cwd="$PWD"
dir="${cwd/#$HOME/\~}"
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -n "${branch:-}" ]; then
  emit "$dir ($branch)"
else
  emit "$dir"
fi
