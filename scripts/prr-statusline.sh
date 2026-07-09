#!/usr/bin/env bash
# prr status line for Claude Code (optional, opt-in via settings.json).
#
# Claude Code pipes a JSON status blob on stdin. We read its session_id and, if
# setup-review.sh has left a session-scoped "reviewing" file for this session,
# print it. Otherwise fall back to the working directory + git branch + the
# current context size (no model). Keyed by session id so parallel fan-out panes
# never show each other's PR. Output is capped so a very long branch name or deep
# path can't overrun the bar; the token count is protected from that trim.
#
# Portable to macOS bash 3.2 (no `${var/#pat/repl}` substitution, POSIX-only).
# No `set -e`: a status line should always emit something and never abort a render.

# Rendered-width cap. Default 70; override with PRR_STATUSLINE_WIDTH (set it in
# the environment you launch Claude Code from, same as PRR_FANOUT). A non-numeric
# or empty value falls back to the default.
MAX_WIDTH="${PRR_STATUSLINE_WIDTH:-70}"
case "$MAX_WIDTH" in ''|*[!0-9]*) MAX_WIDTH=70 ;; esac

emit() {
  # $1 = main text; optional $2 = a suffix that is always kept at the end. Capped
  # to MAX_WIDTH; when it must trim it trims $1 (with a trailing ...), never the
  # suffix, so an appended token count is never cut off.
  local body="${1%%$'\n'*}" sfx="${2:-}"
  local budget=$(( MAX_WIDTH - ${#sfx} ))
  [ "$budget" -lt 0 ] && budget=0
  if [ "${#body}" -gt "$budget" ]; then
    if [ "$budget" -ge 3 ]; then body="${body:0:$((budget - 3))}..."; else body="${body:0:budget}"; fi
  fi
  printf '%s%s' "$body" "$sfx"
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

# Idle: home-abbreviated cwd + git branch + current context size (no model).
cwd="$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[ -n "${cwd:-}" ] || cwd="$PWD"
if [ "${cwd#$HOME}" != "$cwd" ]; then dir="~${cwd#$HOME}"; else dir="$cwd"; fi
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# Current context size = the most recent assistant turn's input tokens (fresh +
# cache-read + cache-creation) from the session transcript, shown as e.g. "877k".
# Best-effort: omitted if the transcript path is absent/unreadable or jq missing.
tokens=""
tp="$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null)"
if [ -n "${tp:-}" ] && [ -f "$tp" ]; then
  t="$(tail -n 200 "$tp" 2>/dev/null | jq -rs '
    [ .[] | select(.message.usage != null) | .message.usage
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) ]
    | last // empty' 2>/dev/null)"
  case "${t:-}" in
    ''|*[!0-9]*) : ;;
    *) if [ "$t" -ge 1000 ]; then tokens="$((t / 1000))k"; else tokens="$t"; fi ;;
  esac
fi

main="$dir"
[ -n "${branch:-}" ] && main="$main ($branch)"
if [ -n "${tokens:-}" ]; then
  emit "$main" " $tokens"
else
  emit "$main"
fi
