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

# Current context size vs the window, shown as e.g. "270k/1M". The count is the
# real input-token occupancy (system prompt + tools + injected context + history,
# not just conversation text). Best-effort: omitted if neither source is readable.
fmt_k() { # integer tokens -> compact label: 1500000->1.5M, 226000->226k, 500->500
  if [ "$1" -ge 1000000 ]; then
    if [ $(($1 % 1000000)) -eq 0 ]; then printf '%dM' "$(($1 / 1000000))"
    else printf '%d.%dM' "$(($1 / 1000000))" "$((($1 % 1000000) / 100000))"; fi
  elif [ "$1" -ge 1000 ]; then printf '%dk' "$(($1 / 1000))"
  else printf '%d' "$1"; fi
}

tokens=""
# Authoritative path: Claude Code hands us both numbers in the context_window
# block (its own live accounting + the true window size), so no transcript
# parsing or window guessing is needed.
ctoks="$(printf '%s' "$in" | jq -r '.context_window.total_input_tokens // empty' 2>/dev/null)"
csize="$(printf '%s' "$in" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)"
case "${ctoks:-x}" in *[!0-9]*|x) ctoks="" ;; esac
case "${csize:-x}" in *[!0-9]*|x) csize="" ;; esac

if [ -n "$ctoks" ] && [ -n "$csize" ]; then
  if [ "$ctoks" -lt "$csize" ]; then tokens="$(fmt_k "$ctoks")/$(fmt_k "$csize")"; else tokens="$(fmt_k "$ctoks")"; fi
else
  # Fallback for older Claude Code without context_window: sum the latest
  # main-thread (non-sidechain) usage from the transcript, and infer the window.
  t=""
  tp="$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null)"
  if [ -n "${tp:-}" ] && [ -f "$tp" ]; then
    t="$(tail -n 200 "$tp" 2>/dev/null | jq -rs '
      [ .[] | select(.isSidechain != true) | select(.message.usage != null) | .message.usage
        | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) ]
      | last // empty' 2>/dev/null)"
  fi
  case "${t:-}" in ''|*[!0-9]*) t="" ;; esac

  # Infer the window: PRR_STATUSLINE_CONTEXT_MAX override ("1M"/"1000000"/"200k"),
  # else a "1m" model marker or exceeds_200k_tokens or a >=200k measurement (only
  # a >200k window allows that), else default 200k.
  ctxmax=""
  case "${PRR_STATUSLINE_CONTEXT_MAX:-}" in
    '') : ;;
    *[Mm]) n="${PRR_STATUSLINE_CONTEXT_MAX%[Mm]}"; case "$n" in ''|*[!0-9]*) ;; *) ctxmax=$((n * 1000000)) ;; esac ;;
    *[Kk]) n="${PRR_STATUSLINE_CONTEXT_MAX%[Kk]}"; case "$n" in ''|*[!0-9]*) ;; *) ctxmax=$((n * 1000)) ;; esac ;;
    *[!0-9]*) : ;;
    *) ctxmax="$PRR_STATUSLINE_CONTEXT_MAX" ;;
  esac
  if [ -z "$ctxmax" ]; then
    model="$(printf '%s' "$in" | jq -r '[ .model.id?, .model.display_name?, (.model | select(type == "string")) ] | map(select(. != null)) | join(" ") | ascii_downcase' 2>/dev/null)"
    ex="$(printf '%s' "$in" | jq -r '.exceeds_200k_tokens // empty' 2>/dev/null)"
    case "$model" in
      *1m*) ctxmax=1000000 ;;
      *) if [ "$ex" = "true" ] || { [ -n "$t" ] && [ "$t" -ge 200000 ]; }; then ctxmax=1000000; else ctxmax=200000; fi ;;
    esac
  fi

  if [ -n "$t" ]; then
    if [ "$t" -lt "$ctxmax" ]; then tokens="$(fmt_k "$t")/$(fmt_k "$ctxmax")"; else tokens="$(fmt_k "$t")"; fi
  fi
fi

main="$dir"
[ -n "${branch:-}" ] && main="$main ($branch)"
if [ -n "${tokens:-}" ]; then
  emit "$main" " $tokens"
else
  emit "$main"
fi
