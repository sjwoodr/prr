#!/usr/bin/env bash
# prr-fanout.sh — prr skill: review several PRs in parallel, each in its own
# interactive Claude session in a visible pane, with the human approval gate
# fully intact.
#
# Opt-in via PRR_FANOUT=true (PRR_TMUX_FANOUT=true is honored as a back-compat
# alias). Assumes a GUI session (X11/Xwayland or Wayland, or macOS) because the
# panes must be VISIBLE for you to approve each post; over SSH/headless this
# refuses and the skill falls back to sequential review.
#
# Backend (chosen automatically):
#   - kitty installed (any OS) -> kitty's native grid layout: a true auto-grid
#     that rebalances as panes close, focus-follows-mouse, and self-closing
#     panes. No tmux required.
#   - otherwise -> one terminal (tilix/gnome-terminal/x-terminal-emulator/xterm,
#     or Terminal.app on macOS) hosting tmux, tiled one pane per PR.
#
# Usage (run in the BACKGROUND from the skill — it blocks until every review
# finishes, which is a human-paced wait):
#   PRR_FANOUT=true prr-fanout.sh <PR-url-or-number> <PR-url-or-number> ...
#
# Lifecycle:
#   1. Open ONE window with one pane per PR, each running `claude "/prr <ref>"`.
#   2. Each PR's review writes /tmp/prr-fanout-<number>.result when it finishes
#      (post-review.sh, keyed on PRR_FANOUT_PANE). The pane then closes: under
#      kitty a per-pane watcher terminates its process so kitty closes the pane;
#      under tmux the launcher kills the pane. The poll is a pure shell sleep
#      loop: it costs CPU only, never tokens, so an idle wait is free.
#   3. When all PRs are accounted for, print a consolidated rollup and exit.
#
# Config (env):
#   PRR_FANOUT / PRR_TMUX_FANOUT  must be "true" to run (else refuse with exit 3)
#   PRR_FANOUT_TIMEOUT_MINS       global wall-clock cap; default 240 (4h); 0 = no cap
#   PRR_FANOUT_TERMINAL           force a terminal binary (tmux backend only)
#   PRR_FANOUT_GEOMETRY           spawned-window size COLSxROWS (kitty default 200x60, tmux 160x50)
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

# --- test mode + guards ------------------------------------------------------
# `test-mode` as the first arg runs a no-Claude smoke test of the plumbing: each
# pane mocks a review by writing its own result file (no claude invoked), so you
# can exercise spawn -> tile -> detect -> close -> rollup quickly. It bypasses the
# opt-in flag and the claude check, but still needs a backend (kitty or tmux) + GUI.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

# Opt-in flag: PRR_FANOUT is the documented name; PRR_TMUX_FANOUT is honored as a
# back-compat alias. Either being "true" enables the fan-out.
fanout_enabled=0
[[ "${PRR_FANOUT:-}" == "true" || "${PRR_TMUX_FANOUT:-}" == "true" ]] && fanout_enabled=1
[[ "$TEST" -eq 1 || "$fanout_enabled" -eq 1 ]] \
  || { echo "prr-fanout: PRR_FANOUT is not 'true'; not fanning out." >&2; exit 3; }
[[ $# -ge 2 ]] \
  || { echo "prr-fanout: need 2+ PRs to fan out (got $#)." >&2; exit 3; }
os="$(uname)"
# macOS (Aqua) has no DISPLAY; a desktop GUI is assumed present. On Linux require
# an X11/Wayland session, since the panes must be visible to approve them.
if [[ "$os" != "Darwin" ]]; then
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
    || { echo "prr-fanout: no GUI session (DISPLAY/WAYLAND_DISPLAY unset); cannot open panes." >&2; exit 3; }
fi

# --- backend selection -------------------------------------------------------
# kitty is preferred whenever installed (any OS): its grid layout is a true
# auto-grid that rebalances as panes close, it has focus-follows-mouse, and its
# panes self-close, so it needs no tmux. Without kitty, fall back to tmux hosted
# in a found terminal.
if command -v kitty >/dev/null 2>&1; then
  backend="kitty"
else
  backend="tmux"
  command -v tmux >/dev/null 2>&1 \
    || { echo "prr-fanout: neither kitty nor tmux on PATH; cannot fan out." >&2; exit 3; }
fi

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

# Globals referenced after the backend branch (kept set for `set -u` safety).
session=""; KITTY_PID=""; wrapper=""; sessfile=""; backend_desc=""
declare -A pane_of=()

# ============================================================================
# kitty backend
# ============================================================================
spawn_kitty() {
  # Per-pane wrapper: runs the review (or mock) in the FOREGROUND so you can
  # interact with it, plus a background watcher that, once this PR's result file
  # lands, terminates the foreground process. kitty closes a window when its
  # child exits, so the pane self-closes — the launcher never has to address or
  # kill an individual pane (kitty has no stable per-pane CLI handle anyway).
  wrapper="/tmp/prr-fanout-$$-pane.sh"
  cat > "$wrapper" <<'WRAP'
#!/bin/sh
# args: <num> <payload> <mode>   payload = PR ref (real) | mock delay (test)
num="$1"; payload="$2"; mode="$3"
rf="/tmp/prr-fanout-${num}.result"
( until [ -f "$rf" ]; do sleep 2; done; sleep 1; kill -TERM "$$" 2>/dev/null ) &
if [ "$mode" = "test" ]; then
  echo "[TEST MODE] mock review of PR ${num}; finishing in ${payload}s"
  sleep "$payload"
  printf 'pr=%s status=test comments=0\n' "$num" > "$rf"
  echo "[TEST MODE] PR ${num} result written; pane will self-close"
  exec sleep 600
else
  # PRR_FANOUT_PANE makes post-review.sh drop the result file this pane waits on.
  export PRR_FANOUT_PANE=1
  exec claude "/prr ${payload}"
fi
WRAP

  # Session file: a grid layout with one launched pane per PR. Session restore
  # has no per-pane command field, so each pane runs the wrapper with its args.
  sessfile="/tmp/prr-fanout-$$-kitty.session"
  {
    echo "layout grid"
    local i n
    for i in "${!refs[@]}"; do
      n="${numbers[$i]}"
      if [[ "$TEST" -eq 1 ]]; then
        printf 'launch --title prr-%s sh %s %s %s test\n' "$n" "$wrapper" "$n" "$(( 3 + i * 2 ))"
      else
        printf 'launch --title prr-%s sh %s %s %s real\n' "$n" "$wrapper" "$n" "${refs[$i]}"
      fi
    done
  } > "$sessfile"

  # Open at a fixed cell size (PRR_FANOUT_GEOMETRY as COLSxROWS, default 200x60),
  # not maximized. remember_window_size=no makes kitty honor that initial size
  # instead of reusing a remembered one; enabled_layouts/focus_follows_mouse force
  # the grid + hover regardless of the user's kitty.conf (which otherwise still
  # applies: colors, opacity, etc.).
  local geo cols rows
  geo="${PRR_FANOUT_GEOMETRY:-200x60}"
  cols="${geo%%x*}"; rows="${geo##*x}"
  kitty -o remember_window_size=no \
        -o initial_window_width="${cols}c" \
        -o initial_window_height="${rows}c" \
        -o enabled_layouts=grid \
        -o focus_follows_mouse=yes \
        --session "$sessfile" >/dev/null 2>&1 &
  KITTY_PID=$!
  backend_desc="kitty (native grid)"
}

# ============================================================================
# tmux backend (one terminal hosting a tiled tmux session)
# ============================================================================
spawn_tmux() {
  # pick a terminal
  local term="" t
  if [[ "$os" == "Darwin" ]]; then
    term="${PRR_FANOUT_TERMINAL:-Terminal}"
  else
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
  local first_pane p i
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
  # Re-tile evenly whenever the window attaches or is resized.
  tmux set-hook -t "$session" client-resized  'select-layout tiled' >/dev/null 2>&1 || true
  tmux set-hook -t "$session" client-attached 'select-layout tiled' >/dev/null 2>&1 || true

  # Open ONE visible terminal attached to the session, sized to PRR_FANOUT_GEOMETRY.
  local geo cols rows attach cmdfile
  geo="${PRR_FANOUT_GEOMETRY:-160x50}"
  cols="${geo%%x*}"; rows="${geo##*x}"
  attach="tmux attach -t $session"
  if [[ "$os" == "Darwin" ]]; then
    cmdfile="${TMPDIR:-/tmp}/prr-fanout-$$.command"
    printf '#!/bin/sh\nprintf "\\033[8;%s;%st"\nexec %s\n' "$rows" "$cols" "$attach" > "$cmdfile"
    chmod +x "$cmdfile"
    open -a "$term" "$cmdfile" \
      || echo "prr-fanout: could not open terminal '$term' (is it installed?)." >&2
  else
    local SP; if command -v setsid >/dev/null 2>&1; then SP=(setsid); else SP=(); fi
    case "$term" in
      tilix)          "${SP[@]}" "$term" --geometry="$geo" -e "$attach"                >/dev/null 2>&1 & ;;
      gnome-terminal) "${SP[@]}" "$term" --geometry="$geo" -- tmux attach -t "$session" >/dev/null 2>&1 & ;;
      xterm)          "${SP[@]}" "$term" -geometry "$geo"  -e "$attach"                >/dev/null 2>&1 & ;;
      *)              "${SP[@]}" "$term" -e "$attach"                                   >/dev/null 2>&1 & ;;
    esac
  fi
  backend_desc="tmux via $term"
}

if [[ "$backend" == "kitty" ]]; then
  spawn_kitty
else
  spawn_tmux
fi

[[ "$TEST" -eq 1 ]] && echo "prr-fanout: *** TEST MODE *** mocking reviews, no Claude invoked"
echo "prr-fanout: launched ${#refs[@]} reviews via ${backend_desc}"
echo "prr-fanout: PRs: ${numbers[*]}"
[[ "$backend" == "tmux" ]] && echo "prr-fanout: attach manually any time with: tmux attach -t $session"
echo "prr-fanout: timeout=${timeout_mins}m (0=none); waiting for reviews to finish..."

# --- poll loop (pure shell sleep; no tokens) ---------------------------------
declare -A done_map=()
deadline=$(( $(date +%s) + timeout_mins * 60 ))

remaining() {
  local out=()
  for n in "${numbers[@]}"; do [[ -n "${done_map[$n]:-}" ]] || out+=("$n"); done
  echo "${out[*]}"
}

# Liveness of the spawned window, per backend: kitty exits when all panes close;
# the tmux session ends when its last pane closes.
session_alive() {
  if [[ "$backend" == "tmux" ]]; then
    tmux has-session -t "$session" 2>/dev/null
  else
    kill -0 "$KITTY_PID" 2>/dev/null
  fi
}

# Record any result files that have appeared since the last sweep. For tmux we
# also close the finished pane here; kitty panes self-close, and their result
# files persist on disk so a late sweep (even after the window is gone) still
# sees them.
harvest() {
  local n rf
  for n in "${numbers[@]}"; do
    [[ -n "${done_map[$n]:-}" ]] && continue
    rf="/tmp/prr-fanout-${n}.result"
    if [[ -f "$rf" ]]; then
      done_map[$n]="$(cat "$rf")"
      if [[ "$backend" == "tmux" ]]; then
        rm -f "$rf"
        [[ -n "${pane_of[$n]:-}" ]] && tmux kill-pane -t "${pane_of[$n]}" 2>/dev/null || true
        tmux select-layout -t "$session":reviews tiled >/dev/null 2>&1 || true
      fi
      echo "prr-fanout: done #$n -> ${done_map[$n]}"
    fi
  done
}

while :; do
  if [[ "$timeout_mins" -ne 0 && "$(date +%s)" -ge "$deadline" ]]; then
    echo "prr-fanout: TIMEOUT after ${timeout_mins}m; still open: $(remaining)" >&2
    break
  fi
  # Harvest BEFORE the liveness check: when the window closes (all panes
  # self-closed), the result files still exist, so the final sweep must run
  # before we break on a closed window — otherwise late finishers are missed.
  harvest
  [[ -z "$(remaining)" ]] && { echo "prr-fanout: all reviews complete."; break; }
  session_alive || { harvest; echo "prr-fanout: spawned window closed."; break; }
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

if [[ "$backend" == "tmux" ]]; then
  if [[ -z "$(remaining)" ]]; then
    tmux kill-session -t "$session" 2>/dev/null || true
  else
    echo "prr-fanout: left open panes in place; reattach to finish: tmux attach -t $session"
  fi
else
  # kitty: panes self-close. Remove only the generated launch files. Do NOT
  # delete the result files here: each pane's own watcher is still polling its
  # result file to know when to self-close, and deleting it out from under a slow
  # watcher would strand that pane open forever. The result files are tiny and are
  # cleared at the start of the next run. Any still-open pane (timeout) keeps
  # running and self-closes when its review lands, after this launcher has exited.
  rm -f "$wrapper" "$sessfile"
  if [[ -n "$(remaining)" ]]; then
    echo "prr-fanout: left the kitty window open; finish the remaining reviews there."
  fi
fi
