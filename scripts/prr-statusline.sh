#!/usr/bin/env bash
# prr status line for Claude Code (optional, opt-in via settings.json).
#
# Claude Code pipes a JSON status blob on stdin. We read its session_id and, if
# setup-review.sh has left a session-scoped "reviewing" file for this session,
# print it. Otherwise fall back to the working directory + git branch + model.
# Keyed by session id so parallel fan-out panes never show each other's PR. The
# line is capped so a deep path can't overrun the bar; the path is trimmed from
# the left so its deep end, the branch and the model stay visible.
#
# Portable to macOS bash 3.2 (no `${var/#pat/repl}` substitution, POSIX-only).
# No `set -e`: a status line should always emit something and never abort a render.

# Rendered-width cap. Default 90; override with PRR_STATUSLINE_WIDTH (set it in
# the environment you launch Claude Code from, same as PRR_FANOUT). A non-numeric
# or empty value falls back to the default.
MAX_WIDTH="${PRR_STATUSLINE_WIDTH:-90}"
case "$MAX_WIDTH" in ''|*[!0-9]*) MAX_WIDTH=90 ;; esac

emit() {
  # $1 = main text; optional $2 = a suffix that is always kept at the end. Capped
  # to MAX_WIDTH; when it must trim it trims $1 (with a trailing ...), never the
  # suffix.
  local body="${1%%$'\n'*}" sfx="${2:-}"
  local budget=$(( MAX_WIDTH - ${#sfx} ))
  [ "$budget" -lt 0 ] && budget=0
  if [ "${#body}" -gt "$budget" ]; then
    if [ "$budget" -ge 3 ]; then body="${body:0:$((budget - 3))}..."; else body="${body:0:budget}"; fi
  fi
  printf '%s%s' "$body" "$sfx"
}

emit_left() {
  # Like emit, but trims $1 from the LEFT (leading ...), so the deep end of a
  # path, where a worktree or project name lives, survives. The suffix (branch
  # and model) is kept whole; if it alone leaves no room, show just the suffix.
  local body="${1%%$'\n'*}" sfx="${2:-}"
  local budget=$(( MAX_WIDTH - ${#sfx} ))
  if [ "$budget" -lt 4 ]; then emit "${sfx# }"; return; fi
  if [ "${#body}" -gt "$budget" ]; then
    body="...${body:$(( ${#body} - budget + 3 ))}"
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

# Idle: home-abbreviated cwd + git branch + model. No context size: Claude Code
# already shows a token count above the prompt.
cwd="$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[ -n "${cwd:-}" ] || cwd="$PWD"
if [ "${cwd#$HOME}" != "$cwd" ]; then dir="~${cwd#$HOME}"; else dir="$cwd"; fi
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# Model label, e.g. "[Opus 5.5]". display_name is the human-facing name Claude
# Code sends; fall back to the raw id so an unfamiliar build still shows
# something. Branch on the type first: some builds send .model as a bare string,
# and indexing a string with .display_name is a jq error, not a null.
model_label="$(printf '%s' "$in" | jq -r 'if (.model | type) == "string" then .model else (.model.display_name // .model.id // empty) end' 2>/dev/null)"
# jq-free fallback, same approach as the session_id read above.
if [ -z "${model_label:-}" ]; then
  model_label="$(printf '%s' "$in" | grep -o '"display_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
model_label="${model_label%%$'\n'*}"
# Drop a trailing parenthetical: "Opus 5.5 (1M context)" -> "Opus 5.5".
model_label="${model_label%% (*}"

suffix=""
[ -n "${branch:-}" ] && suffix=" ($branch)"
[ -n "${model_label:-}" ] && suffix="$suffix [$model_label]"

emit_left "$dir" "$suffix"
