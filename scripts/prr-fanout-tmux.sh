#!/usr/bin/env bash
# prr-fanout-tmux.sh — tmux backend of the prr multi-PR fan-out. Reviews several
# PRs in parallel, each in its own interactive Claude session in a tiled tmux
# pane, with the human approval gate fully intact.
#
# Selected by the prr-fanout.sh router when PRR_FANOUT=tmux (the default backend,
# and what PRR_FANOUT=true / legacy PRR_TMUX_FANOUT=true normalize to). Assumes a
# GUI session (X11/Xwayland/Wayland, or macOS) because the panes must be VISIBLE
# for you to approve each post; over SSH/headless this refuses and the skill falls
# back to sequential review.
#
# Usage (normally via the router; it blocks until every review finishes, which is
# a human-paced wait):
#   PRR_FANOUT=tmux prr-fanout-tmux.sh <PR-url-or-number> <PR-url-or-number> ...
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
# Shared helpers (prnum, init_refs, pane_cmd, remaining, print_rollup) live in
# prr-fanout-common.sh, sourced below.
#
# Config (env):
#   PRR_FANOUT               must be "tmux" (the router sets this); test-mode bypasses it
#   PRR_FANOUT_TIMEOUT_MINS  global wall-clock cap; default 240 (4h); 0 = no cap
#   PRR_FANOUT_TERMINAL      force a terminal binary, skipping auto-detection
#   PRR_FANOUT_GEOMETRY      spawned window size as COLSxROWS; default 160x50
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail
TAG="prr-fanout-tmux"
# shellcheck source-path=SCRIPTDIR source=prr-fanout-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prr-fanout-common.sh"

# --- test mode + guard -------------------------------------------------------
# `test-mode` as the first arg runs a no-Claude smoke test of the plumbing: each
# pane mocks a review by writing its own result file (no claude invoked), so you
# can exercise spawn -> tile -> detect -> close -> rollup quickly. It bypasses the
# enable gate and the claude check, but still needs tmux + a GUI.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

# Run only as the tmux backend. The router normalizes PRR_FANOUT (incl. the
# back-compat aliases) and execs us with PRR_FANOUT=tmux; a direct caller must set
# it themselves.
[[ "$TEST" -eq 1 || "${PRR_FANOUT:-}" == "tmux" ]] \
  || { echo "$TAG: not selected (PRR_FANOUT != tmux); refusing." >&2; exit 3; }
[[ $# -ge 2 ]] \
  || { echo "$TAG: need 2+ PRs to fan out (got $#)." >&2; exit 3; }

os="$(uname)"
# macOS (Aqua) has no DISPLAY; a desktop GUI is assumed present. On Linux require
# an X11/Wayland session, since the panes must be visible to approve them.
if [[ "$os" != "Darwin" ]]; then
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
    || { echo "$TAG: no GUI session (DISPLAY/WAYLAND_DISPLAY unset); cannot open panes." >&2; exit 3; }
fi
command -v tmux >/dev/null 2>&1 || { echo "$TAG: tmux not on PATH." >&2; exit 3; }
[[ "$TEST" -eq 1 ]] || command -v claude >/dev/null 2>&1 \
  || { echo "$TAG: claude not on PATH." >&2; exit 3; }

timeout_mins="${PRR_FANOUT_TIMEOUT_MINS:-240}"

# Parse refs -> numbers (shared prnum), then clear stale result files from a
# previous run so we do not read them as done.
refs=("$@")
numbers=()
for r in "${refs[@]}"; do numbers+=("$(prnum "$r")"); done
for n in "${numbers[@]}"; do rm -f "/tmp/prr-fanout-${n}.result"; done

# --- pick a terminal ---------------------------------------------------------
# macOS: built-in Terminal.app by default; PRR_FANOUT_TERMINAL overrides it
# (best-effort, see the spawn below). Linux: tilix, terminator, wezterm,
# gnome-terminal, x-terminal-emulator (the desktop default via
# update-alternatives), xterm; PRR_FANOUT_TERMINAL forces a binary.
if [[ "$os" == "Darwin" ]]; then
  term="${PRR_FANOUT_TERMINAL:-Terminal}"
else
  term=""
  for t in "${PRR_FANOUT_TERMINAL:-}" tilix terminator wezterm gnome-terminal x-terminal-emulator xterm; do
    [[ -n "$t" ]] && command -v "$t" >/dev/null 2>&1 && { term="$t"; break; }
  done
  [[ -n "$term" ]] \
    || { echo "$TAG: no supported terminal (tilix/terminator/wezterm/gnome-terminal/x-terminal-emulator/xterm)." >&2; exit 3; }
fi

session="prr-fanout-$$"

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
# (tilix/terminator/gnome-terminal --geometry=, xterm -geometry, wezterm --config
# initial_cols/initial_rows; others open default-sized).
geo="${PRR_FANOUT_GEOMETRY:-160x50}"
cols="${geo%%x*}"; rows="${geo##*x}"
attach="tmux attach -t $session"
# Capture the terminal spawn's stderr so a failed launch (e.g. a bad flag) is not
# swallowed. Single file, overwritten (truncated) on each invocation.
spawnlog="/tmp/prr-fanout-spawn.log"
if [[ "$os" == "Darwin" ]]; then
  # Open the terminal on a throwaway .command that first resizes itself via the
  # xterm "CSI 8 ; rows ; cols t" escape (honored by Terminal.app and most
  # terminals) and then attaches. `open -a` is terminal-agnostic and needs no
  # Automation permission; if an app ignores the resize it opens default-sized,
  # and the client-resized hook still keeps the panes evenly tiled once it settles.
  cmdfile="${TMPDIR:-/tmp}/prr-fanout-$$.command"
  printf '#!/bin/sh\nprintf "\\033[8;%s;%st"\nexec %s\n' "$rows" "$cols" "$attach" > "$cmdfile"
  chmod +x "$cmdfile"
  open -a "$term" "$cmdfile" 2>"$spawnlog" \
    || echo "$TAG: could not open terminal '$term' (is it installed?)." >&2
else
  if command -v setsid >/dev/null 2>&1; then SP=(setsid); else SP=(); fi
  case "$term" in
    wezterm)        "${SP[@]}" "$term" --config "initial_cols=$cols" --config "initial_rows=$rows" start --always-new-process -- tmux attach -t "$session" >"$spawnlog" 2>&1 & ;;
    tilix)          "${SP[@]}" "$term" --geometry="$geo" -e "$attach"                >"$spawnlog" 2>&1 & ;;
    terminator)     "${SP[@]}" "$term" --geometry="$geo" -e "$attach"                >"$spawnlog" 2>&1 & ;;
    gnome-terminal) "${SP[@]}" "$term" --geometry="$geo" -- tmux attach -t "$session" >"$spawnlog" 2>&1 & ;;
    xterm)          "${SP[@]}" "$term" -geometry "$geo"  -e "$attach"                >"$spawnlog" 2>&1 & ;;
    *)              "${SP[@]}" "$term" -e "$attach"                                   >"$spawnlog" 2>&1 & ;;
  esac
fi

[[ "$TEST" -eq 1 ]] && echo "$TAG: *** TEST MODE *** mocking reviews, no Claude invoked"
echo "$TAG: launched ${#refs[@]} reviews in tmux session '$session' via $term"
echo "$TAG: PRs: ${numbers[*]}"
echo "$TAG: attach manually any time with: tmux attach -t $session"
echo "$TAG: terminal spawn log: $spawnlog (check it if no window appears)"
echo "$TAG: timeout=${timeout_mins}m (0=none); waiting for reviews to finish..."

# --- poll loop (pure shell sleep; no tokens) ---------------------------------
declare -A done_map=()
deadline=$(( $(date +%s) + timeout_mins * 60 ))

while :; do
  if [[ "$timeout_mins" -ne 0 && "$(date +%s)" -ge "$deadline" ]]; then
    echo "$TAG: TIMEOUT after ${timeout_mins}m; still open: $(remaining)" >&2
    break
  fi
  tmux has-session -t "$session" 2>/dev/null \
    || { echo "$TAG: tmux session ended (panes all closed)."; break; }

  for n in "${numbers[@]}"; do
    [[ -n "${done_map[$n]:-}" ]] && continue
    rf="/tmp/prr-fanout-${n}.result"
    if [[ -f "$rf" ]]; then
      done_map[$n]="$(cat "$rf")"
      rm -f "$rf"
      if [[ -n "${pane_of[$n]:-}" ]]; then tmux kill-pane -t "${pane_of[$n]}" 2>/dev/null || true; fi
      tmux select-layout -t "$session":reviews tiled >/dev/null 2>&1 || true
      echo "$TAG: done #$n -> ${done_map[$n]}"
    fi
  done

  [[ -z "$(remaining)" ]] && { echo "$TAG: all reviews complete."; break; }
  sleep 5
done

# --- rollup ------------------------------------------------------------------
print_rollup

if [[ -z "$(remaining)" ]]; then
  tmux kill-session -t "$session" 2>/dev/null || true
else
  echo "$TAG: left open panes in place; reattach to finish: tmux attach -t $session"
fi
