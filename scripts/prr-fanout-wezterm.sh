#!/usr/bin/env bash
# prr-fanout-wezterm.sh — wezterm-native (NO tmux) variant of the multi-PR
# fan-out. Same contract as the tmux backend: one visible window, one pane per PR
# each running `claude "/prr <ref>"` with the human approval gate intact, panes
# closing as each review finishes, then a consolidated rollup.
#
# Why a separate backend: tmux gives a free auto-tiling grid and cross-terminal
# portability, which is why it remains the default. This variant exists for the
# wezterm daily-driver: it drops the tmux layer and drives wezterm directly via
# `wezterm cli`. Selected by the prr-fanout.sh router when PRR_FANOUT=wezterm.
#
# Linux-only — NOT because wezterm is (it runs fine on macOS), but because this
# backend's launch + isolation mechanics are: it detaches the gui with `setsid`
# (absent on macOS) and finds the new instance's socket under the XDG runtime dir
# (`$XDG_RUNTIME_DIR/wezterm`; macOS uses a different location). On macOS the tmux
# backend drives wezterm perfectly well, so that path covers it.
#
# How it stays off the user's own wezterm windows: it starts its OWN gui instance
# (`wezterm start --class prr-fanout-<pid> --always-new-process`) and addresses it
# exclusively through that instance's private gui socket (WEZTERM_UNIX_SOCKET).
# Every `wezterm cli` call is pinned to that socket, so splits and kills can never
# touch the user's existing window. `--no-auto-start` keeps stray mux-servers from
# spawning.
#
# Layout: panes are tiled into a near-square grid (cols = ceil(sqrt(N)), rows =
# ceil(N/cols)) with explicit equal-slice percentages. There is deliberately NO
# rebalance-on-close: a finished pane's space is absorbed by its sibling and the
# grid goes a little ragged. These runs last minutes, so survivors just getting
# bigger is fine — and not re-tiling avoids yanking panes around under the reader.
#
# Shared helpers (prnum, init_refs, pane_cmd, remaining, print_rollup) live in
# prr-fanout-common.sh, sourced below.
#
# Usage (normally via the prr-fanout.sh router; blocks until every review ends):
#   PRR_FANOUT=wezterm prr-fanout-wezterm.sh <PR-url-or-number> ...
#   prr-fanout-wezterm.sh test-mode <N> <N> ...   # no-Claude plumbing smoke test
#
# Config (env):
#   PRR_FANOUT               must be "wezterm" (the router sets this); test-mode bypasses it
#   PRR_FANOUT_TIMEOUT_MINS  global wall-clock cap; default 240 (4h); 0 = no cap
#   PRR_FANOUT_GEOMETRY      initial window size COLSxROWS; default 160x50
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail
TAG="prr-fanout-wezterm"
# shellcheck source-path=SCRIPTDIR source=prr-fanout-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prr-fanout-common.sh"

# --- test mode + guards ------------------------------------------------------
# `test-mode` mocks each review (no Claude) so spawn -> tile -> detect -> close
# -> rollup can be exercised quickly; it bypasses the selection gate and the
# claude check but still needs wezterm + a GUI.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

# Run only as the wezterm backend. The router normalizes PRR_FANOUT and execs us
# with PRR_FANOUT=wezterm; a direct caller must set it themselves.
[[ "$TEST" -eq 1 || "${PRR_FANOUT:-}" == "wezterm" ]] \
  || { echo "$TAG: not selected (PRR_FANOUT != wezterm); refusing." >&2; exit 3; }
[[ $# -ge 2 ]] \
  || { echo "$TAG: need 2+ PRs to fan out (got $#)." >&2; exit 3; }
# Linux-only: this backend uses `setsid` (no macOS equivalent) and the XDG runtime
# gui sockets. On macOS use the tmux backend, which drives wezterm fine.
[[ "$(uname)" != "Darwin" ]] \
  || { echo "$TAG: native backend is Linux-only (use PRR_FANOUT=tmux on macOS)." >&2; exit 3; }
[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
  || { echo "$TAG: no GUI session (DISPLAY/WAYLAND_DISPLAY unset); cannot open panes." >&2; exit 3; }
command -v wezterm >/dev/null 2>&1 || { echo "$TAG: wezterm not on PATH." >&2; exit 3; }
[[ "$TEST" -eq 1 ]] || command -v claude >/dev/null 2>&1 \
  || { echo "$TAG: claude not on PATH." >&2; exit 3; }

timeout_mins="${PRR_FANOUT_TIMEOUT_MINS:-240}"

# Parse refs -> numbers (shared prnum), then clear stale result files from a
# previous run so we do not read them as done.
refs=("$@")
numbers=()
for r in "${refs[@]}"; do numbers+=("$(prnum "$r")"); done
for n in "${numbers[@]}"; do rm -f "/tmp/prr-fanout-${n}.result"; done
N=${#refs[@]}

# --- start an isolated wezterm gui instance, addressed by its own socket ------
geo="${PRR_FANOUT_GEOMETRY:-160x50}"
gcols="${geo%%x*}"; grows="${geo##*x}"
sockdir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wezterm"
cls="prr-fanout-$$"
spawnlog="/tmp/prr-fanout-spawn.log"   # overwritten each run; check if no window

# Pane 0 runs the first PR. A non-empty `-- <prog>` makes the gui-startup hook in
# ~/.wezterm.lua spawn a single pane (no daily-driver 2x2), which is what we want.
setsid wezterm --config "initial_cols=$gcols" --config "initial_rows=$grows" \
  start --class "$cls" --always-new-process \
  --cwd "$PWD" -- bash -lc "$(pane_cmd "${refs[0]}" 0)" >"$spawnlog" 2>&1 &

# Discover MY socket: the gui-sock whose owning pid's cmdline carries our class.
# Pinning every cli call to this socket is what isolates us from other windows.
SOCK=""
for _ in $(seq 1 50); do
  for s in "$sockdir"/gui-sock-*; do
    [[ -e "$s" ]] || continue
    pid="${s##*-}"
    if ps -o args= -p "$pid" 2>/dev/null | grep -q -- "--class $cls"; then SOCK="$s"; break; fi
  done
  [[ -n "$SOCK" ]] && WEZTERM_UNIX_SOCKET="$SOCK" wezterm cli --no-auto-start list >/dev/null 2>&1 && break
  SOCK=""; sleep 0.2
done
[[ -n "$SOCK" ]] \
  || { echo "$TAG: wezterm window never came up (see $spawnlog)." >&2; cat "$spawnlog" >&2 || true; exit 3; }
export WEZTERM_UNIX_SOCKET="$SOCK"
wzcli() { wezterm cli --no-auto-start "$@"; }

# --- tile the remaining PRs into a near-square grid ---------------------------
# cols = ceil(sqrt(N)); rows = ceil(N/cols). Bash-native, no python.
cols=1; while (( cols * cols < N )); do (( cols++ )); done
rows=$(( (N + cols - 1) / cols ))
pct() { echo $(( (100 * $1 + $2 / 2) / $2 )); }   # round(100*$1/$2), integer

split() {  # $1=parent pane-id  $2=dir(--bottom|--right)  $3=percent  $4=pane cmd
  wzcli split-pane --pane-id "$1" "$2" --percent "$3" --cwd "$PWD" -- bash -lc "$4"
}

declare -A pane_of=()
# Cell (r,c) holds command index r*cols + c. Pane 0 is cell (0,0); the instance
# has exactly one pane at this point, so the first listed pane_id is it.
pane0="$(wzcli list --format json \
         | grep -o '"pane_id": *[0-9]*' | head -1 | grep -o '[0-9]*')"
pane_of["${numbers[0]}"]="$pane0"

# Phase 1 — left column: split the chained bottom pane downward into `rows` equal
# slices. Each new pane is the leftmost cell of its row.
declare -a left=("$pane0")
cur="$pane0"
for (( r=1; r<rows; r++ )); do
  p="$(pct $((rows-r)) $((rows-r+1)))"
  idx=$(( r * cols ))
  np="$(split "$cur" --bottom "$p" "$(pane_cmd "${refs[$idx]}" "$idx")")"
  pane_of["${numbers[$idx]}"]="$np"
  left[r]="$np"; cur="$np"
done

# Phase 2 — columns: from each row's left pane, split rightward into that row's
# panes (equal widths). The last row may hold fewer than `cols` panes (ragged).
for (( r=0; r<rows; r++ )); do
  first=$(( r * cols )); (( first >= N )) && break
  w=$(( N - first )); (( w > cols )) && w=$cols   # panes in this row
  cur="${left[$r]}"
  for (( c=1; c<w; c++ )); do
    p="$(pct $((w-c)) $((w-c+1)))"
    idx=$(( first + c ))
    np="$(split "$cur" --right "$p" "$(pane_cmd "${refs[$idx]}" "$idx")")"
    pane_of["${numbers[$idx]}"]="$np"; cur="$np"
  done
done

[[ "$TEST" -eq 1 ]] && echo "$TAG: *** TEST MODE *** mocking reviews, no Claude invoked"
echo "$TAG: launched $N reviews in an isolated wezterm window (${cols}x${rows} grid)"
echo "$TAG: PRs: ${numbers[*]}"
echo "$TAG: gui socket: $SOCK"
echo "$TAG: terminal spawn log: $spawnlog (check it if no window appears)"
echo "$TAG: timeout=${timeout_mins}m (0=none); waiting for reviews to finish..."

# --- poll loop (pure shell sleep; no tokens) ---------------------------------
declare -A done_map=()
deadline=$(( $(date +%s) + timeout_mins * 60 ))

# The instance is alive while it still has at least one pane; once the last pane
# closes the gui exits and the socket goes away, so a failed `list` means gone.
instance_alive() { wzcli list >/dev/null 2>&1; }

while :; do
  if [[ "$timeout_mins" -ne 0 && "$(date +%s)" -ge "$deadline" ]]; then
    echo "$TAG: TIMEOUT after ${timeout_mins}m; still open: $(remaining)" >&2
    break
  fi
  instance_alive || { echo "$TAG: wezterm window closed (all panes gone)."; break; }

  for n in "${numbers[@]}"; do
    [[ -n "${done_map[$n]:-}" ]] && continue
    rf="/tmp/prr-fanout-${n}.result"
    if [[ -f "$rf" ]]; then
      done_map[$n]="$(cat "$rf")"
      rm -f "$rf"
      if [[ -n "${pane_of[$n]:-}" ]]; then wzcli kill-pane --pane-id "${pane_of[$n]}" 2>/dev/null || true; fi
      echo "$TAG: done #$n -> ${done_map[$n]}"
    fi
  done

  [[ -z "$(remaining)" ]] && { echo "$TAG: all reviews complete."; break; }
  sleep 5
done

# --- rollup ------------------------------------------------------------------
print_rollup

# All accounted for: close any panes still up (claude panes self-close on exit,
# but test/aborted ones may linger), which ends the instance. Otherwise leave the
# window in place so the open reviews can be finished by hand.
if [[ -z "$(remaining)" ]]; then
  if instance_alive; then
    wzcli list --format json | grep -o '"pane_id": *[0-9]*' | grep -o '[0-9]*' \
      | while read -r pid; do wzcli kill-pane --pane-id "$pid" 2>/dev/null || true; done
  fi
else
  echo "$TAG: left the wezterm window open; finish the remaining reviews there."
fi
