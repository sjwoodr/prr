#!/usr/bin/env bash
# prr-fanout-wezterm.sh — wezterm-native (NO tmux) variant of the multi-PR
# fan-out. Same contract as prr-fanout.sh: one visible window, one pane per PR
# each running `claude "/prr <ref>"` with the human approval gate intact, panes
# closing as each review finishes, then a consolidated rollup.
#
# Why a separate backend: tmux gives a free auto-tiling grid and cross-terminal
# portability, which is why it remains the default. This variant exists for the
# wezterm daily-driver: it drops the tmux layer and drives wezterm directly via
# `wezterm cli`. Selected only when PRR_FANOUT_NATIVE=true AND wezterm is present
# (see the dispatch shim at the top of prr-fanout.sh); otherwise nothing changes.
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
# Usage (run in the BACKGROUND from the skill; it blocks until every review ends):
#   PRR_FANOUT_NATIVE=true prr-fanout-wezterm.sh <PR-url-or-number> ...
#   prr-fanout-wezterm.sh test-mode <N> <N> ...   # no-Claude plumbing smoke test
#
# Config (env):
#   PRR_FANOUT_NATIVE        must be "true" to run (test-mode bypasses it)
#   PRR_FANOUT_TIMEOUT_MINS  global wall-clock cap; default 240 (4h); 0 = no cap
#   PRR_FANOUT_GEOMETRY      initial window size COLSxROWS; default 160x50
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

# --- test mode + guards ------------------------------------------------------
# `test-mode` mocks each review (no Claude) so spawn -> tile -> detect -> close
# -> rollup can be exercised quickly; it bypasses the opt-in flag and the claude
# check but still needs wezterm + a GUI.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

[[ "$TEST" -eq 1 || "${PRR_FANOUT_NATIVE:-}" == "true" ]] \
  || { echo "prr-fanout-wezterm: PRR_FANOUT_NATIVE is not 'true'; not fanning out." >&2; exit 3; }
[[ $# -ge 2 ]] \
  || { echo "prr-fanout-wezterm: need 2+ PRs to fan out (got $#)." >&2; exit 3; }
# wezterm-native is Linux-only (it relies on the XDG runtime gui sockets); the
# dispatch shim only routes here on Linux, but guard anyway.
[[ "$(uname)" != "Darwin" ]] \
  || { echo "prr-fanout-wezterm: native backend is Linux-only." >&2; exit 3; }
[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
  || { echo "prr-fanout-wezterm: no GUI session (DISPLAY/WAYLAND_DISPLAY unset); cannot open panes." >&2; exit 3; }
command -v wezterm >/dev/null 2>&1 || { echo "prr-fanout-wezterm: wezterm not on PATH." >&2; exit 3; }
[[ "$TEST" -eq 1 ]] || command -v claude >/dev/null 2>&1 \
  || { echo "prr-fanout-wezterm: claude not on PATH." >&2; exit 3; }

timeout_mins="${PRR_FANOUT_TIMEOUT_MINS:-240}"

# --- parse each ref to a PR number (same rule as setup/post-review.sh) --------
prnum() {
  if [[ "$1" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
  else
    echo "prr-fanout-wezterm: '$1' is neither a PR URL nor a number." >&2; return 2
  fi
}

refs=("$@")
numbers=()
for r in "${refs[@]}"; do numbers+=("$(prnum "$r")"); done
N=${#refs[@]}

# Clear any stale result files from a previous run so we do not read them as done.
for n in "${numbers[@]}"; do rm -f "/tmp/prr-fanout-${n}.result"; done

pane_cmd() {  # $1 = PR ref, $2 = index -> the shell command string a pane runs
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
  || { echo "prr-fanout-wezterm: wezterm window never came up (see $spawnlog)." >&2; cat "$spawnlog" >&2 || true; exit 3; }
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
# Cell (r,c) holds command index r*cols + c. Pane 0 is cell (0,0).
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
  left[$r]="$np"; cur="$np"
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

[[ "$TEST" -eq 1 ]] && echo "prr-fanout-wezterm: *** TEST MODE *** mocking reviews, no Claude invoked"
echo "prr-fanout-wezterm: launched $N reviews in an isolated wezterm window (${cols}x${rows} grid)"
echo "prr-fanout-wezterm: PRs: ${numbers[*]}"
echo "prr-fanout-wezterm: gui socket: $SOCK"
echo "prr-fanout-wezterm: terminal spawn log: $spawnlog (check it if no window appears)"
echo "prr-fanout-wezterm: timeout=${timeout_mins}m (0=none); waiting for reviews to finish..."

# --- poll loop (pure shell sleep; no tokens) ---------------------------------
declare -A done_map=()
deadline=$(( $(date +%s) + timeout_mins * 60 ))

remaining() {
  local out=()
  for n in "${numbers[@]}"; do [[ -n "${done_map[$n]:-}" ]] || out+=("$n"); done
  echo "${out[*]}"
}

# The instance is alive while it still has at least one pane; once the last pane
# closes the gui exits and the socket goes away, so a failed `list` means gone.
instance_alive() { wzcli list >/dev/null 2>&1; }

while :; do
  if [[ "$timeout_mins" -ne 0 && "$(date +%s)" -ge "$deadline" ]]; then
    echo "prr-fanout-wezterm: TIMEOUT after ${timeout_mins}m; still open: $(remaining)" >&2
    break
  fi
  instance_alive || { echo "prr-fanout-wezterm: wezterm window closed (all panes gone)."; break; }

  for n in "${numbers[@]}"; do
    [[ -n "${done_map[$n]:-}" ]] && continue
    rf="/tmp/prr-fanout-${n}.result"
    if [[ -f "$rf" ]]; then
      done_map[$n]="$(cat "$rf")"
      rm -f "$rf"
      [[ -n "${pane_of[$n]:-}" ]] && wzcli kill-pane --pane-id "${pane_of[$n]}" 2>/dev/null || true
      echo "prr-fanout-wezterm: done #$n -> ${done_map[$n]}"
    fi
  done

  [[ -z "$(remaining)" ]] && { echo "prr-fanout-wezterm: all reviews complete."; break; }
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

# All accounted for: close any panes still up (claude panes self-close on exit,
# but test/aborted ones may linger), which ends the instance. Otherwise leave the
# window in place so the open reviews can be finished by hand.
if [[ -z "$(remaining)" ]]; then
  if instance_alive; then
    wzcli list --format json | grep -o '"pane_id": *[0-9]*' | grep -o '[0-9]*' \
      | while read -r pid; do wzcli kill-pane --pane-id "$pid" 2>/dev/null || true; done
  fi
else
  echo "prr-fanout-wezterm: left the wezterm window open; finish the remaining reviews there."
fi
