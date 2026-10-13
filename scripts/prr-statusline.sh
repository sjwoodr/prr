#!/usr/bin/env bash
# prr status line for Claude Code (optional, opt-in via settings.json).
#
# Claude Code pipes a JSON status blob on stdin. We read its session_id and, if
# setup-review.sh has left a session-scoped "reviewing" file for this session,
# print it. Otherwise fall back to the working directory + git branch + model,
# plus the context size when it fits.
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

# Second line: how the last turn went. On by default; PRR_STATUSLINE_TIMINGS=0
# (or false/no/off) turns it off.
#   ⏱ last turn 47.2s · 8 calls · out 3.1k · new in 12k · cache hit 98%
# Read from the session transcript Claude Code names on stdin, so no hooks are
# needed. A turn runs from the last prompt you typed to the last reply; while it
# is still going (the last entry is a tool call or its result) it reads
# "so far". Calls are distinct assistant messages; "new in" is input that was
# not read from the prompt cache (uncached + cache writes), summed over the
# turn; "cache hit" is cached input over all input. Only the transcript's tail
# is read (transcripts reach hundreds of MB), read as raw lines (-R) so the cut
# first line is skipped by fromjson?, and any failure prints nothing rather
# than disturbing the main line. Needs jq. Coloured light blue by default;
# PRR_STATUSLINE_TIMINGS_COLOR picks another (see color_code).
timings_line() {
  case "${PRR_STATUSLINE_TIMINGS:-1}" in 0|false|no|off) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  local tp
  tp="$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null)"
  [ -n "${tp:-}" ] && [ -f "$tp" ] || return 0
  local stats
  stats="$(tail -c 4000000 "$tp" 2>/dev/null | tail -n +2 | jq -R -n -r '
    def secs: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
      + ((capture("\\.(?<f>[0-9]+)Z$").f // "0") | "0." + . | tonumber);
    def text_of: if (.message.content | type) == "string" then .message.content
      else ([.message.content[]? | select(.type == "text") | .text] | first // null) end;
    # A prompt you typed: Claude Code marks it origin.kind "human". Older
    # transcripts lack that, so fall back to user text that is neither a tool
    # result nor system-injected (those start with "<").
    def is_prompt: .type == "user" and (.isMeta != true)
      and (if .origin.kind? then .origin.kind == "human"
           else ([.message.content[]? | select(type == "object" and .type == "tool_result")] | length) == 0
             and (text_of | type) == "string" and ((text_of | ltrimstr(" ") | startswith("<")) | not)
           end);
    [inputs | fromjson? | select(.isSidechain != true and (.type == "user" or .type == "assistant"))] as $e
    | ($e | map(is_prompt) | indices(true) | last) as $start
    | if $start == null then empty else
        $e[$start:] as $turn
        | ($turn | map(select(.type == "assistant" and .message.usage != null))
                 | group_by(.message.id) | map(last)) as $calls
        | ($turn | last) as $end
        | ($end.type == "user"
           or ([$end.message.content[]? | select(type == "object" and .type == "tool_use")] | length) > 0) as $running
        | ((if $running then now else ($end.timestamp | secs) end) - ($turn[0].timestamp | secs)) as $dur
        | [$calls[].message.usage] as $u
        | [ ($dur * 10 | round / 10), (if $running then 1 else 0 end), ($calls | length),
            ([$u[].output_tokens // 0] | add // 0),
            ([$u[] | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)] | add // 0),
            ([$u[].cache_read_input_tokens // 0] | add // 0) ] | @tsv
      end' 2>/dev/null)" || return 0
  [ -n "$stats" ] || return 0
  local dur running calls out new cached
  IFS="$(printf '\t')" read -r dur running calls out new cached <<EOF
$stats
EOF
  case "$calls$out$new$cached" in *[!0-9]*) return 0 ;; esac
  local label="last turn"
  [ "$running" = 1 ] && label="so far"
  local t="⏱ $label $(fmt_dur "$dur")"
  [ "$calls" -gt 0 ] && t="$t · $calls call$([ "$calls" = 1 ] || printf s)"
  [ "$out" -gt 0 ] && t="$t · out $(fmt_k "$out")"
  [ "$new" -gt 0 ] && t="$t · new in $(fmt_k "$new")"
  if [ $((new + cached)) -gt 0 ] && [ "$cached" -gt 0 ]; then
    t="$t · cache hit $((cached * 100 / (new + cached)))%"
  fi
  printf '\n%s' "$(paint "${PRR_STATUSLINE_TIMINGS_COLOR:-75}" "$t")"
}

# paint COLOR TEXT: TEXT wrapped in COLOR's escape codes (plain when none).
paint() {
  local sgr
  sgr="$(color_code "$1")"
  if [ -n "$sgr" ] && [ -n "$2" ]; then printf '\033[%sm%s\033[0m' "$sgr" "$2"; else printf '%s' "$2"; fi
}

# A colour setting to an ANSI SGR code: a name (blue, brightblue, grey, ...), a
# 256-colour number (0-255), a hex #rrggbb for true-colour terminals, or none.
# Anything unrecognised means no colour rather than garbage, and NO_COLOR (the
# common convention) turns every colour off.
color_code() {
  [ -n "${NO_COLOR:-}" ] && return 0
  local c
  c="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$c" in
    ''|none|off) return 0 ;;
    black) echo 30 ;; red) echo 31 ;; green) echo 32 ;; yellow) echo 33 ;;
    blue) echo 34 ;; magenta) echo 35 ;; cyan) echo 36 ;; white) echo 37 ;;
    grey|gray) echo 90 ;;
    brightred) echo 91 ;; brightgreen) echo 92 ;; brightyellow) echo 93 ;;
    brightblue) echo 94 ;; brightmagenta) echo 95 ;; brightcyan) echo 96 ;; brightwhite) echo 97 ;;
    \#[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      printf '38;2;%d;%d;%d\n' "0x${c:1:2}" "0x${c:3:2}" "0x${c:5:2}" ;;
    *[!0-9]*) return 0 ;;
    *) [ "$c" -le 255 ] && echo "38;5;$c" ;;
  esac
}

fmt_dur() { # 47.2 -> 47.2s, 350.3 -> 5m50s, 3900 -> 1h05m
  local whole="${1%%.*}"
  case "$whole" in ''|*[!0-9]*) printf '%ss' "$1"; return ;; esac
  if [ "$whole" -lt 60 ]; then printf '%ss' "$1"
  elif [ "$whole" -lt 3600 ]; then printf '%dm%02ds' "$((whole / 60))" "$((whole % 60))"
  else printf '%dh%02dm' "$((whole / 3600))" "$(((whole % 3600) / 60))"; fi
}

fmt_k() { # 1500000->1.5M, 226000->226k, 3100->3.1k, 500->500
  if [ "$1" -ge 1000000 ]; then
    if [ $(($1 % 1000000)) -eq 0 ]; then printf '%dM' "$(($1 / 1000000))"
    else printf '%d.%dM' "$(($1 / 1000000))" "$((($1 % 1000000) / 100000))"; fi
  elif [ "$1" -ge 10000 ]; then printf '%dk' "$(($1 / 1000))"
  elif [ "$1" -ge 1000 ]; then printf '%d.%dk' "$(($1 / 1000))" "$((($1 % 1000) / 100))"
  else printf '%d' "$1"; fi
}

# The review line ("prr: reviewing #1861 - [IBX-3763] Title") is trimmed as
# plain text first, like the idle line, then coloured in parts: "prr: <verb>",
# the PR number, a leading ticket key in the title; the title itself stays the
# terminal's default colour. A line that does not have that shape (an older
# setup-review.sh, a hand-written file) is printed plain.
review_line() {
  local plain re
  plain="$(emit "$1")"
  re='^(prr: [a-z-]+) (#[0-9]+)( - )?(\[[A-Z][A-Z0-9]*-[0-9]+\])?(.*)$'
  if [[ "$plain" =~ $re ]]; then
    local out
    out="$(paint "${PRR_STATUSLINE_REVIEW_COLOR:-179}" "${BASH_REMATCH[1]}") $(paint "${PRR_STATUSLINE_PR_COLOR:-114}" "${BASH_REMATCH[2]}")${BASH_REMATCH[3]}"
    [ -n "${BASH_REMATCH[4]}" ] && out="$out$(paint "${PRR_STATUSLINE_TICKET_COLOR:-73}" "${BASH_REMATCH[4]}")"
    printf '%s' "$out${BASH_REMATCH[5]}"
  else
    printf '%s' "$plain"
  fi
}

state="/tmp/prr-status-${sid:-nosession}"
if [ -f "$state" ]; then
  review_line "$(cat "$state")"
  timings_line
  exit 0
fi

# Idle: home-abbreviated cwd + git branch + model, then the context size if the
# line has room for it.
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

line="$(emit_left "$dir" "$suffix")"

# Context size vs the window, e.g. "123k/1M", from Claude Code's context_window
# block. Appended only when it fits whole, so it is dropped before the path is
# trimmed. Claude Code shows its own count above the prompt in some layouts only.
ctoks="$(printf '%s' "$in" | jq -r '.context_window.total_input_tokens // empty' 2>/dev/null)"
csize="$(printf '%s' "$in" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)"
case "${ctoks:-x}" in *[!0-9]*|x) ctoks="" ;; esac
case "${csize:-x}" in *[!0-9]*|x) csize="" ;; esac
if [ -n "$ctoks" ] && [ -n "$csize" ]; then
  tokens=" $(fmt_k "$ctoks")/$(fmt_k "$csize")"
  [ $(( ${#line} + ${#tokens} )) -le "$MAX_WIDTH" ] && line="$line$tokens"
fi

# Colour each part only now: the width cap counts characters, so the line is
# measured and trimmed as plain text first. What survived the trim is split
# back into its parts (the suffix is never trimmed, only the path, or the path
# is dropped entirely when the branch and model alone fill the cap).
shown="$line"
ctx_part=""
if [ -n "${tokens:-}" ] && [ "${shown%"$tokens"}" != "$shown" ]; then
  shown="${shown%"$tokens"}"
  ctx_part="$tokens"
fi
if [ -z "$suffix" ]; then
  dir_part="$shown"
elif [ "${shown%"$suffix"}" != "$shown" ]; then
  dir_part="${shown%"$suffix"}"
else
  dir_part=""  # only the suffix fitted (emit_left printed it without its space)
fi
out=""
[ -n "$dir_part" ] && out="$(paint "${PRR_STATUSLINE_DIR_COLOR:-73}" "$dir_part")"
if [ -n "${branch:-}" ]; then
  [ -n "$out" ] && out="$out "
  out="$out($(paint "${PRR_STATUSLINE_BRANCH_COLOR:-114}" "$branch"))"
fi
if [ -n "${model_label:-}" ]; then
  [ -n "$out" ] && out="$out "
  out="$out[$(paint "${PRR_STATUSLINE_MODEL_COLOR:-176}" "$model_label")]"
fi
[ -n "$ctx_part" ] && out="$out $(paint "${PRR_STATUSLINE_CONTEXT_COLOR:-179}" "${ctx_part# }")"
[ -n "$out" ] || out="$line"

printf '%s' "$out"
timings_line
