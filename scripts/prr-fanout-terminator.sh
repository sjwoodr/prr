#!/usr/bin/env bash
# prr-fanout-terminator.sh — Terminator-native (NO tmux) variant of the multi-PR
# fan-out. Same contract as the tmux/wezterm backends: one visible window, one
# pane per PR each running `claude "/prr <ref>"` with the human approval gate
# intact, then a consolidated rollup. Selected by prr-fanout.sh when
# PRR_FANOUT=terminator.
#
# Why a separate backend: Terminator is native GTK/VTE, so it avoids wezterm's
# TUI CPU storm and kitty's no-mouse-resize, while giving focus-follows-mouse
# (hover focus) and mouse-drag pane resize. The catch is its remote control
# (`remotinator` over DBus) has NO "close a pane" verb and no per-instance
# isolation handle, so it cannot drive the lifecycle the way tmux send/kill or
# `wezterm cli` do. We sidestep remotinator entirely:
#
#   * Layout, not splits. We generate a throwaway Terminator config (`-g`) whose
#     [layouts] section fully specifies the grid — one Terminal node per PR with
#     its own `command` — and open it with `-l`. Terminator builds the whole
#     tiled window in one shot; we never issue a follow-up terminal command.
#   * Isolation via `-u` (--no-dbus). That forces our OWN GUI process instead of
#     forwarding a new window into the user's running Terminator, so (a) it can
#     never touch their daily-driver windows and (b) we get a real PID to track
#     for liveness. `-u` also means remotinator can't reach us — which is fine,
#     because the layout already did all the setup.
#
# PANE CLOSE — opt-in, and only from inside the pane. Terminator exposes NO
# "close pane" verb over DBus (remotinator has none), and `-u` removes DBus
# entirely, so unlike the tmux (kill-pane) and wezterm (cli kill-pane) backends
# NOTHING can close a pane from the OUTSIDE. The only lever is from INSIDE: a VTE
# pane closes when its child process exits (exit_action), so a pane can end its
# own process group to make Terminator close it. Hence:
#   * Default (PRR_FANOUT_TERM_AUTOCLOSE=10): each pane self-closes 10 seconds
#     after ITS result file lands — enough to glance at the outcome, then gone.
#     The cost: it terminates that pane's idle `claude` session (you lose its
#     scroll-back) — a VTE pane can only close by its child exiting, so keeping
#     the session AND closing the pane is not possible. Use 0 to close the instant
#     the result lands, or a larger number to linger longer.
#   * PRR_FANOUT_TERM_AUTOCLOSE=off (or `never`/empty): finished panes stay open,
#     holding their completed review for re-reading, until you close the window.
# Either way completion is detected via the /tmp result files (not pane death),
# so the rollup is accurate regardless.
#
# CONFIG CEILING: the throwaway `-g` config is self-contained, so it does NOT
# inherit the user's font/colors/keybindings — only `focus = mouse` is carried
# over (the whole point of this backend). Upgrade path if it proves worth it:
# merge the layout into a copy of ~/.config/terminator/config instead of a
# minimal generated one.
#
# Shared helpers (prnum, init_refs, pane_cmd, remaining, print_rollup) live in
# prr-fanout-common.sh, sourced below.
#
# Usage (normally via the prr-fanout.sh router; blocks until every review ends):
#   PRR_FANOUT=terminator prr-fanout-terminator.sh <PR-url-or-number> ...
#   prr-fanout-terminator.sh test-mode <N> <N> ...  # no-Claude plumbing smoke test
#
# Config (env):
#   PRR_FANOUT               must be "terminator" (the router sets this); test-mode bypasses it
#   PRR_FANOUT_TIMEOUT_MINS  global wall-clock cap; default 240 (4h); 0 = no cap
#   PRR_FANOUT_GEOMETRY      window size COLSxROWS in chars; default 160x50
#                            (converted to pixels at ~9x19 per cell for the layout)
#   PRR_FANOUT_TERM_AUTOCLOSE  integer seconds a pane stays up after its review
#                              finishes before self-closing (ends that pane's
#                              claude session); default 10. `off`/`never`/empty
#                              keeps panes open. See "PANE CLOSE" above.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail
TAG="prr-fanout-terminator"
# shellcheck source-path=SCRIPTDIR source=prr-fanout-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prr-fanout-common.sh"

# --- test mode + guards ------------------------------------------------------
# `test-mode` mocks each review (no Claude) so spawn -> tile -> detect -> rollup
# can be exercised quickly; it bypasses the selection gate and the claude check
# but still needs terminator + a GUI.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

# Run only as the terminator backend. The router normalizes PRR_FANOUT and execs
# us with PRR_FANOUT=terminator; a direct caller must set it themselves.
[[ "$TEST" -eq 1 || "${PRR_FANOUT:-}" == "terminator" ]] \
  || { echo "$TAG: not selected (PRR_FANOUT != terminator); refusing." >&2; exit 3; }
[[ $# -ge 2 ]] \
  || { echo "$TAG: need 2+ PRs to fan out (got $#)." >&2; exit 3; }
# Linux/X11 only: Terminator is a GTK app that needs a display, and this backend
# tracks the GUI process by PID (no setsid/daemonization).
[[ "$(uname)" != "Darwin" ]] \
  || { echo "$TAG: Terminator backend is Linux-only (use PRR_FANOUT=tmux on macOS)." >&2; exit 3; }
[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
  || { echo "$TAG: no GUI session (DISPLAY/WAYLAND_DISPLAY unset); cannot open a window." >&2; exit 3; }
command -v terminator >/dev/null 2>&1 || { echo "$TAG: terminator not on PATH." >&2; exit 3; }
[[ "$TEST" -eq 1 ]] || command -v claude >/dev/null 2>&1 \
  || { echo "$TAG: claude not on PATH." >&2; exit 3; }

timeout_mins="${PRR_FANOUT_TIMEOUT_MINS:-240}"
REPO="$PWD"   # panes cd here so bare-number PRs resolve against the repo

# Self-close grace (seconds): a pane closes itself this long after its review
# finishes. Default 10s — we do not want these windows hanging around. Set
# `off`/`never` (or empty) to keep panes open instead. Baked into each pane script
# at generation so behavior does not depend on env reaching the pane through
# Terminator. See the "PANE CLOSE" note in the header.
autoclose="${PRR_FANOUT_TERM_AUTOCLOSE-10}"   # no ':' => an explicit empty value lingers
[[ "$autoclose" == "off" || "$autoclose" == "never" ]] && autoclose=""
[[ -z "$autoclose" || "$autoclose" =~ ^[0-9]+$ ]] \
  || { echo "$TAG: PRR_FANOUT_TERM_AUTOCLOSE must be an integer (seconds), 'off'/'never', or empty (got '$autoclose')." >&2; exit 3; }

# Parse refs -> numbers (shared prnum), then clear stale result files from a
# previous run so we do not read them as done.
refs=("$@")
numbers=()
for r in "${refs[@]}"; do numbers+=("$(prnum "$r")"); done
for n in "${numbers[@]}"; do rm -f "/tmp/prr-fanout-${n}.result"; done
N=${#refs[@]}

# --- geometry: chars -> pixels for the layout --------------------------------
# Other backends size in char cells; Terminator layout nodes size in pixels, so
# convert with a nominal cell (~9w x 19h). Exact size does not matter: the panes
# are mouse-resizable and the ratios keep them even on window resize.
geo="${PRR_FANOUT_GEOMETRY:-160x50}"
gchars_c="${geo%%x*}"; gchars_r="${geo##*x}"
Wpx=$(( gchars_c * 9 )); Hpx=$(( gchars_r * 19 ))

# --- grid: near-square, columns of (near) equal height -----------------------
# gridcols = ceil(sqrt(N)); distribute N over the columns so each holds floor or
# ceil of N/gridcols panes (no empty cells). PR i fills column-major.
gridcols=1; while (( gridcols * gridcols < N )); do (( gridcols++ )); done
base=$(( N / gridcols )); extra=$(( N % gridcols ))
declare -a colcount=()
for (( c=0; c<gridcols; c++ )); do
  if (( c < extra )); then colcount[c]=$(( base + 1 )); else colcount[c]=$base; fi
done

# --- generate the throwaway config + per-pane launcher scripts ---------------
LAYOUT="prrfanout"
cfg="/tmp/prr-fanout-terminator-$$.config"
scriptdir="/tmp/prr-fanout-panes-$$"
spawnlog="/tmp/prr-fanout-spawn.log"   # overwritten each run; check if no window
mkdir -p "$scriptdir"

# Self-contained config. focus = mouse preserves the hover-focus this backend
# exists for; exit_action = close lets a pane close once its command exits (the
# claude REPL keeps it open until you quit claude); suppress_multiple_term_dialog
# skips the "close N terminals?" prompt when you close the window.
{
  echo "[global_config]"
  echo "  focus = mouse"
  echo "  suppress_multiple_term_dialog = True"
  echo "[profiles]"
  echo "  [[default]]"
  echo "    scrollback_lines = 5000"
  echo "    exit_action = close"
  echo "[layouts]"
  echo "  [[$LAYOUT]]"
} > "$cfg"

# Unique node names. NOTE: this must NOT be a `$(...)` command substitution —
# that runs in a subshell, so the `nid++` would be lost and every node would
# collide on the same name. Assign into $NAME in the current shell instead.
nid=0
newname() { NAME="n$(( nid++ ))"; }

emit_node() {  # name type parent order [position] [ratio] [command]
  local name="$1" typ="$2" parent="$3" order="$4" pos="${5:-}" ratio="${6:-}" cmd="${7:-}"
  {
    echo "    [[[$name]]]"
    echo "      type = $typ"
    echo "      parent = $parent"
    echo "      order = $order"
    [[ -n "$pos" ]]   && echo "      position = $pos"
    [[ -n "$ratio" ]] && echo "      ratio = $ratio"
    if [[ "$typ" == "Terminal" ]]; then
      echo "      profile = default"
      [[ -n "$cmd" ]] && echo "      command = $cmd"
    fi
  } >> "$cfg"
}

# Window root.
newname; win="$NAME"
{
  echo "    [[[$win]]]"
  echo "      type = Window"
  echo "      parent = \"\""
  echo "      order = 0"
  echo "      size = $Wpx, $Hpx"
} >> "$cfg"

# Build the grid as a left-deep HPaned chain of columns; each column is a
# top-deep VPaned chain of its panes. Each Paned in an equal split has the same
# pixel position (a nested Paned's allocation shrinks proportionally), with ratio
# 1/(remaining) so resizes stay even. Terminals run `bash <per-pane-script>` to
# avoid any INI quoting of the pane command.
hparent="$win"; horder=0
idx=0
for (( c=0; c<gridcols; c++ )); do
  m=${colcount[c]}
  if (( c < gridcols - 1 )); then
    newname; hp="$NAME"
    hpos=$(( (Wpx + gridcols / 2) / gridcols ))
    hratio="$(awk "BEGIN{printf \"%.6f\", 1/($gridcols-$c)}")"
    emit_node "$hp" HPaned "$hparent" "$horder" "$hpos" "$hratio"
    cparent="$hp"; corder=0      # this column's content hangs off child 0
    hparent="$hp"; horder=1      # the next column chains off child 1
  else
    cparent="$hparent"; corder="$horder"   # last column takes the tail slot
  fi

  vparent="$cparent"; vorder="$corder"
  for (( j=0; j<m; j++ )); do
    if (( j < m - 1 )); then
      newname; vp="$NAME"
      vpos=$(( (Hpx + m / 2) / m ))
      vratio="$(awk "BEGIN{printf \"%.6f\", 1/($m-$j)}")"
      emit_node "$vp" VPaned "$vparent" "$vorder" "$vpos" "$vratio"
      tparent="$vp"; torder=0
      vparent="$vp"; vorder=1
    else
      tparent="$vparent"; torder="$vorder"
    fi
    scr="$scriptdir/pane-$idx.sh"
    rfpane="/tmp/prr-fanout-${numbers[$idx]}.result"
    {
      echo "#!/usr/bin/env bash"
      echo "cd $(printf '%q' "$REPO") || exit 1"
      # Self-close watcher (only when autoclose is enabled). It waits for THIS
      # pane's result file, then after the grace period terminates the pane's
      # process group, which makes Terminator close the pane (its child exits).
      # The watcher ignores TERM so it survives to escalate to KILL. $$ here is
      # the pane script's pid, which Terminator/VTE makes the process-group
      # leader, so `-$$` targets claude + the script + the watcher together.
      if [[ -n "$autoclose" ]]; then
        cat <<WATCH
__grp=\$\$
( trap '' TERM
  while [ ! -f $(printf '%q' "$rfpane") ]; do sleep 2; done
  sleep $autoclose
  kill -TERM -- "-\$__grp" 2>/dev/null
  sleep 3
  kill -KILL -- "-\$__grp" 2>/dev/null ) &
__watcher=\$!
WATCH
      fi
      # pane_cmd emits a single line with no trailing newline; add one so the
      # watcher-stop line below cannot fuse onto the review command.
      printf '%s\n' "$(pane_cmd "${refs[$idx]}" "$idx")"
      # If the review's command exits on its own first (e.g. you quit claude
      # before it finished), stop the watcher so it cannot loop forever or fire
      # against a recycled process group. Must be SIGKILL: the watcher ignores
      # TERM (so it survives its own group-TERM to escalate), so TERM would not
      # stop it here.
      [[ -n "$autoclose" ]] && echo '[[ -n "${__watcher:-}" ]] && kill -KILL "$__watcher" 2>/dev/null || true'
    } > "$scr"
    chmod +x "$scr"
    newname
    emit_node "$NAME" Terminal "$tparent" "$torder" "" "" "bash $scr"
    idx=$(( idx + 1 ))
  done
done

# --- launch the isolated Terminator window -----------------------------------
# -u (--no-dbus) gives us our own process (real PID, never touches the user's
# running Terminator). Direct child + $! so the PID is the GUI itself (terminator
# -u does not daemonize), which we use for liveness below.
terminator -u -g "$cfg" -l "$LAYOUT" >"$spawnlog" 2>&1 &
term_pid=$!

# Confirm it actually came up (a bad config / missing display exits fast).
alive=0
for _ in $(seq 1 25); do
  if kill -0 "$term_pid" 2>/dev/null; then alive=1; break; fi
  sleep 0.2
done
if [[ "$alive" -ne 1 ]]; then
  echo "$TAG: Terminator window never came up (see $spawnlog)." >&2
  cat "$spawnlog" >&2 || true
  exit 3
fi

[[ "$TEST" -eq 1 ]] && echo "$TAG: *** TEST MODE *** mocking reviews, no Claude invoked"
echo "$TAG: launched $N reviews in an isolated Terminator window (${gridcols} cols, $(printf '%s ' "${colcount[@]}")per col)"
echo "$TAG: PRs: ${numbers[*]}"
echo "$TAG: layout config: $cfg  (pane scripts: $scriptdir)"
echo "$TAG: terminal spawn log: $spawnlog (check it if no window appears)"
if [[ -n "$autoclose" ]]; then
  echo "$TAG: NOTE: each pane self-closes ${autoclose}s after its review finishes (PRR_FANOUT_TERM_AUTOCLOSE=off to keep them open)."
else
  echo "$TAG: NOTE: finished review panes stay open; close the window when done."
fi
echo "$TAG: timeout=${timeout_mins}m (0=none); waiting for reviews to finish..."

# --- poll loop (pure shell sleep; no tokens) ---------------------------------
declare -A done_map=()
deadline=$(( $(date +%s) + timeout_mins * 60 ))

while :; do
  if [[ "$timeout_mins" -ne 0 && "$(date +%s)" -ge "$deadline" ]]; then
    echo "$TAG: TIMEOUT after ${timeout_mins}m; still open: $(remaining)" >&2
    break
  fi
  # The window is gone (user closed it) -> stop. We cannot close panes ourselves,
  # so this is the only window-side end condition besides all-results-in.
  kill -0 "$term_pid" 2>/dev/null \
    || { echo "$TAG: Terminator window closed."; break; }

  for n in "${numbers[@]}"; do
    [[ -n "${done_map[$n]:-}" ]] && continue
    rf="/tmp/prr-fanout-${n}.result"
    if [[ -f "$rf" ]]; then
      # Do NOT delete it here: the pane's own self-close watcher also waits on
      # this file, and the next run clears stale files at startup anyway.
      done_map[$n]="$(cat "$rf")"
      echo "$TAG: done #$n -> ${done_map[$n]}"
    fi
  done

  [[ -z "$(remaining)" ]] && { echo "$TAG: all reviews complete."; break; }
  sleep 5
done

# --- rollup ------------------------------------------------------------------
print_rollup

# With autoclose on, finished panes self-close and the window goes away once the
# last one does; with it off, panes (and the window) stay until you close them.
# Either way we never force the window shut from here, so any still-open review
# can be finished by hand.
if [[ -z "$(remaining)" ]]; then
  if [[ -n "$autoclose" ]]; then
    echo "$TAG: all reviews accounted for; panes self-close (${autoclose}s grace)."
  else
    echo "$TAG: all reviews accounted for; close the Terminator window when done reading."
  fi
else
  echo "$TAG: left the Terminator window open; finish the remaining reviews there."
fi
