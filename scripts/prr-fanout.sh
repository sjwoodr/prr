#!/usr/bin/env bash
# prr-fanout.sh — prr skill: review several PRs in parallel, each in its own
# interactive Claude session in a tiled tmux pane, with the human approval gate
# fully intact.
#
# Opt-in via PRR_TMUX_FANOUT=true. Assumes a GUI session (X11/Xwayland or
# Wayland) because the panes must be VISIBLE for you to approve each post; over
# SSH/headless this refuses and the skill falls back to sequential review.
#
# Usage (run in the BACKGROUND from the skill — it blocks until every review
# finishes, which is a human-paced wait):
#   PRR_TMUX_FANOUT=true prr-fanout.sh <PR-url-or-number> <PR-url-or-number> ...
#
# Lifecycle:
#   1. Open ONE terminal running tmux with one tiled pane per PR, each pane
#      running `claude "/prr <ref>"` with PRR_FANOUT_PANE=1 set.
#   2. Poll for each PR's /tmp/prr-fanout-<number>.result file (written by
#      post-review.sh when that PR's review finishes — posted, declined, or
#      self-review), closing each pane as its result lands. The poll is a pure
#      shell sleep loop: it costs CPU only, never tokens, so an idle wait is free.
#   3. When all PRs are accounted for (result file, or pane/session gone), print
#      a consolidated rollup and exit. The terminal closes itself when tmux ends.
#
# Config (env):
#   PRR_TMUX_FANOUT          must be "true" to run (else refuse with exit 3)
#   PRR_FANOUT_TIMEOUT_MINS  global wall-clock cap; default 240 (4h); 0 = no cap
#   PRR_FANOUT_TERMINAL      force a terminal binary, skipping auto-detection
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

# --- test mode + guards ------------------------------------------------------
# `test-mode` as the first arg runs a no-Claude smoke test of the plumbing: each
# pane mocks a review by writing its own result file (no claude invoked), so you
# can exercise spawn -> tile -> detect -> close -> rollup quickly. It bypasses the
# PRR_TMUX_FANOUT flag and the claude check, but still needs tmux + a GUI.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

[[ "$TEST" -eq 1 || "${PRR_TMUX_FANOUT:-}" == "true" ]] \
  || { echo "prr-fanout: PRR_TMUX_FANOUT is not 'true'; not fanning out." >&2; exit 3; }
[[ $# -ge 2 ]] \
  || { echo "prr-fanout: need 2+ PRs to fan out (got $#)." >&2; exit 3; }
os="$(uname)"
# macOS (Aqua) has no DISPLAY; a desktop GUI is assumed present. On Linux require
# an X11/Wayland session, since the panes must be visible to approve them.
if [[ "$os" != "Darwin" ]]; then
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
    || { echo "prr-fanout: no GUI session (DISPLAY/WAYLAND_DISPLAY unset); cannot open panes." >&2; exit 3; }
fi
command -v tmux >/dev/null 2>&1 || { echo "prr-fanout: tmux not on PATH." >&2; exit 3; }
[[ "$TEST" -eq 1 ]] || command -v claude >/dev/null 2>&1 \
  || { echo "prr-fanout: claude not on PATH." >&2; exit 3; }

timeout_mins="${PRR_FANOUT_TIMEOUT_MINS:-240}"

# --- parse each ref to a PR number (same rule as setup/post-review.sh) --------
prnum() {
  if [[ "$1" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
  else
    echo "prr-fanout: '$1' is neither a PR URL nor a number." >&2; return 2
  fi
}

refs=("$@")
numbers=()
for r in "${refs[@]}"; do numbers+=("$(prnum "$r")"); done

# Clear any stale result files from a previous run so we do not read them as done.
for n in "${numbers[@]}"; do rm -f "/tmp/prr-fanout-${n}.result"; done

# --- pick a terminal ---------------------------------------------------------
# macOS: built-in Terminal.app by default; PRR_FANOUT_TERMINAL overrides it
# (best-effort, see the spawn below). Linux: tilix, gnome-terminal,
# x-terminal-emulator (the desktop default via update-alternatives), xterm;
# PRR_FANOUT_TERMINAL forces a binary.
if [[ "$os" == "Darwin" ]]; then
  term="${PRR_FANOUT_TERMINAL:-Terminal}"
else
  term=""
  for t in "${PRR_FANOUT_TERMINAL:-}" tilix gnome-terminal x-terminal-emulator xterm; do
    [[ -n "$t" ]] && command -v "$t" >/dev/null 2>&1 && { term="$t"; break; }
  done
  [[ -n "$term" ]] \
    || { echo "prr-fanout: no supported terminal (tilix/gnome-terminal/x-terminal-emulator/xterm)." >&2; exit 3; }
fi

session="prr-fanout-$$"

pane_cmd() {  # $1 = PR ref, $2 = index -> the command string a pane runs
  local ref="$1" idx="$2"
  if [[ "$TEST" -eq 1 ]]; then
    # Mock a review: banner, a staggered wait (so panes close one by one), then
    # write the result file the launcher polls, then idle until it kills the pane.
    local n="${numbers[$idx]}" delay=$(( 3 + idx * 2 ))
    printf 'echo "[TEST MODE] mock review of PR %s; finishing in %ss"; sleep %s; echo "pr=%s status=test comments=%s" > /tmp/prr-fanout-%s.result; echo "[TEST MODE] PR %s result written; waiting for launcher to close this pane"; sleep 600' \
      "$n" "$delay" "$delay" "$n" "$idx" "$n" "$n"
  else
    printf 'PRR_FANOUT_PANE=1 claude "/prr %s"' "$ref"
  fi
}

# Build the session detached with a large virtual size so tiling many panes does
# not hit "no space for new pane"; it resizes to the real terminal on attach.
# -c "$PWD" so bare-number PRs resolve against the repo you launched from.
declare -A pane_of=()
first_pane="$(tmux new-session -d -s "$session" -n reviews -x 250 -y 60 -c "$PWD" \
              -P -F '#{pane_id}' "$(pane_cmd "${refs[0]}" 0)")"
pane_of["${numbers[0]}"]="$first_pane"
for i in "${!refs[@]}"; do
  (( i == 0 )) && continue
  p="$(tmux split-window -t "$session":reviews -c "$PWD" -P -F '#{pane_id}' "$(pane_cmd "${refs[$i]}" "$i")")"
  pane_of["${numbers[$i]}"]="$p"
  tmux select-layout -t "$session":reviews tiled >/dev/null
done
tmux set-option -t "$session" remain-on-exit off >/dev/null
# Re-tile evenly whenever the window attaches or is resized, so manually resizing
# the spawned window keeps the panes equal instead of leaving them lopsided.
tmux set-hook -t "$session" client-resized  'select-layout tiled' >/dev/null 2>&1 || true
tmux set-hook -t "$session" client-attached 'select-layout tiled' >/dev/null 2>&1 || true

# Open ONE visible terminal attached to the session, sized to PRR_FANOUT_GEOMETRY
# (COLSxROWS); tmux resizes the panes to fit on attach. macOS drives Terminal.app
# via AppleScript (no -e/--geometry there); Linux uses per-terminal flags
# (tilix/gnome-terminal --geometry=, xterm -geometry; others open default-sized).
geo="${PRR_FANOUT_GEOMETRY:-160x50}"
cols="${geo%%x*}"; rows="${geo##*x}"
attach="tmux attach -t $session"
if [[ "$os" == "Darwin" ]]; then
  # Open the terminal on a throwaway .command that (1) self-resizes via the xterm
  # "CSI 8 ; rows ; cols t" escape (honored by Terminal.app), (2) attaches, and
  # (3) once tmux ends, closes its own Terminal.app window (matched by tty) so it
  # doesn't linger on "[Process completed]". `open -a` needs no Automation perms;
  # the self-close does (one-time prompt) and is best-effort. It's gated to
  # Apple_Terminal so an overridden terminal never accidentally launches Terminal.
  cmdfile="${TMPDIR:-/tmp}/prr-fanout-$$.command"
  cat > "$cmdfile" <<EOF
#!/bin/sh
printf '\033[8;${rows};${cols}t'
export PRR_FANOUT_TTY="\$(tty)"
tmux attach -t ${session}
if [ "\$TERM_PROGRAM" = "Apple_Terminal" ]; then
  osascript >/dev/null 2>&1 <<'OSA' || true
tell application "Terminal"
  set tt to (system attribute "PRR_FANOUT_TTY")
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is tt then
        close w saving no
        return
      end if
    end repeat
  end repeat
end tell
OSA
fi
EOF
  chmod +x "$cmdfile"
  open -a "$term" "$cmdfile" \
    || echo "prr-fanout: could not open terminal '$term' (is it installed?)." >&2
else
  if command -v setsid >/dev/null 2>&1; then SP=(setsid); else SP=(); fi
  case "$term" in
    tilix)          "${SP[@]}" "$term" --geometry="$geo" -e "$attach"                >/dev/null 2>&1 & ;;
    gnome-terminal) "${SP[@]}" "$term" --geometry="$geo" -- tmux attach -t "$session" >/dev/null 2>&1 & ;;
    xterm)          "${SP[@]}" "$term" -geometry "$geo"  -e "$attach"                >/dev/null 2>&1 & ;;
    *)              "${SP[@]}" "$term" -e "$attach"                                   >/dev/null 2>&1 & ;;
  esac
fi

[[ "$TEST" -eq 1 ]] && echo "prr-fanout: *** TEST MODE *** mocking reviews, no Claude invoked"
echo "prr-fanout: launched ${#refs[@]} reviews in tmux session '$session' via $term"
echo "prr-fanout: PRs: ${numbers[*]}"
echo "prr-fanout: attach manually any time with: tmux attach -t $session"
echo "prr-fanout: timeout=${timeout_mins}m (0=none); waiting for reviews to finish..."

# --- poll loop (pure shell sleep; no tokens) ---------------------------------
declare -A done_map=()
deadline=$(( $(date +%s) + timeout_mins * 60 ))

remaining() {
  local out=()
  for n in "${numbers[@]}"; do [[ -n "${done_map[$n]:-}" ]] || out+=("$n"); done
  echo "${out[*]}"
}

while :; do
  if [[ "$timeout_mins" -ne 0 && "$(date +%s)" -ge "$deadline" ]]; then
    echo "prr-fanout: TIMEOUT after ${timeout_mins}m; still open: $(remaining)" >&2
    break
  fi
  tmux has-session -t "$session" 2>/dev/null \
    || { echo "prr-fanout: tmux session ended (panes all closed)."; break; }

  for n in "${numbers[@]}"; do
    [[ -n "${done_map[$n]:-}" ]] && continue
    rf="/tmp/prr-fanout-${n}.result"
    if [[ -f "$rf" ]]; then
      done_map[$n]="$(cat "$rf")"
      rm -f "$rf"
      [[ -n "${pane_of[$n]:-}" ]] && tmux kill-pane -t "${pane_of[$n]}" 2>/dev/null || true
      tmux select-layout -t "$session":reviews tiled >/dev/null 2>&1 || true
      echo "prr-fanout: done #$n -> ${done_map[$n]}"
    fi
  done

  [[ -z "$(remaining)" ]] && { echo "prr-fanout: all reviews complete."; break; }
  sleep 5
done

# --- rollup ------------------------------------------------------------------
echo
echo "===== prr-fanout rollup ====="
for n in "${numbers[@]}"; do
  if [[ -n "${done_map[$n]:-}" ]]; then
    echo "  #$n  ${done_map[$n]}"
  else
    echo "  #$n  (no result — still open or aborted)"
  fi
done

if [[ -z "$(remaining)" ]]; then
  tmux kill-session -t "$session" 2>/dev/null || true
else
  echo "prr-fanout: left open panes in place; reattach to finish: tmux attach -t $session"
fi
