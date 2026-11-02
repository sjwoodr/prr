#!/usr/bin/env bash
# pane-cmd-test.sh -- checks the pane command the fan-out builds:
#
#   - pane_cmd() output shapes (prr-fanout-common.sh): the default must stay
#     byte-identical to a pre-PR_AGENT_CLI pane command, and the new variables
#     compose with silent / Source C.
#   - the PRR_AGENT_CLI / PRR_AGENT_ARGS validation in prr-fanout.sh: plain
#     tokens only, and no non-interactive or auto-approve flag gets through.
#
# Needs a bash >= 4 on this machine (pane_cmd uses associative arrays), which
# is already a fan-out requirement. Pops no panes: the launcher cases below
# point PRR_FANOUT at the tmux backend with a PATH that has no tmux in it, so
# a valid configuration fails later with "tmux not on PATH" (exit 3) — a
# distinguishable outcome from the validation refusing the value (exit 2).
# Run: bash tests/pane-cmd-test.sh
#
set -u

here="$(cd "$(dirname "$0")/.." && pwd)"

# Mirror the launcher's own interpreter hunt, so the test works on macOS 3.2.
bash4="$BASH"
[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]] || bash4=""
if [[ -z "$bash4" ]]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
    [[ -x "$b" && "$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)" -ge 4 ]] && { bash4="$b"; break; }
  done
fi
if [[ -z "$bash4" ]]; then
  echo "FAIL setup: no bash >= 4 found (associative arrays are needed)"; exit 1
fi

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

N=999991  # a PR number no real review has; pane_cmd only formats it

# run_pane_cmd <name> <expected> [env=value ...] -- source the common file the
# way every backend does (TEST=0, numbers set, run set) and capture pane_cmd.
run_pane_cmd() {
  local name="$1" want="$2"; shift 2
  local got
  got="$("$bash4" -c "
    TEST=0 numbers=($N) run=
    $(for kv in "$@"; do printf 'export %q; ' "$kv"; done)
    source '$here/scripts/prr-fanout-common.sh'
    pane_cmd $N 0" 2>&1)"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name" "want [$want], got [$got]"
  fi
}

run_pane_cmd "default (no CLI/ARGS) is unchanged" \
  'PRR_FANOUT_PANE=1 claude "/prr '$N'"'
run_pane_cmd "opencode interactive TUI" \
  'PRR_FANOUT_PANE=1 opencode --prompt "/prr '$N'"' \
  PRR_AGENT_CLI=opencode PRR_AGENT_ARGS=--prompt
run_pane_cmd "silent composes with a custom CLI" \
  'PRR_FANOUT_PANE=1 opencode --prompt "/prr silent '$N'"' \
  PRR_FANOUT_SILENT=1 PRR_AGENT_CLI=opencode PRR_AGENT_ARGS=--prompt
run_pane_cmd "Source C composes with a custom CLI" \
  'PRR_FANOUT_PANE=1 opencode --prompt "/prr C=opus '$N'"' \
  PRR_FANOUT_SOURCE_C="C=opus" PRR_AGENT_CLI=opencode PRR_AGENT_ARGS=--prompt
run_pane_cmd "silent + Source C, default CLI" \
  'PRR_FANOUT_PANE=1 claude "/prr silent C=opus '$N'"' \
  PRR_FANOUT_SILENT=1 PRR_FANOUT_SOURCE_C="C=opus"

# A recursive PATH holding everything BUT tmux/wezterm/terminator lets a valid
# config reach the backend and die as "not on PATH" (exit 3), while an invalid
# PRR_AGENT_* is refused by the launcher itself (exit 2, launcher message).
stub_path() {
  # Symlink everything on PATH except the backend terminals, so the launcher
  # reaches its own exec and the backend's missing-tool guard instead of
  # dying on a missing dirname for lack of coreutils.
  local p="${TMPDIR:-/tmp}/prr-panetest-bin"
  mkdir -p "$p" || return 1
  local oldIFS="$IFS" d f b
  IFS=:
  for d in $PATH; do
    IFS="$oldIFS"
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      [[ -e "$f" && -f "$f" && -x "$f" ]] || continue
      b="${f##*/}"
      case "$b" in tmux|tmux-server|wezterm|wezterm-gui|terminator) continue ;; esac
      [[ -e "$p/$b" ]] || ln -s "$f" "$p/$b" 2>/dev/null
    done
    IFS=:
  done
  IFS="$oldIFS"
  printf '%s' "$p"
}
VPATH="$(stub_path)" || { echo "FAIL setup: cannot create stub PATH"; exit 1; }

launcher() {  # launcher <env=value ...>
  env PATH="$VPATH" "$@" "$bash4" "$here/scripts/prr-fanout.sh" test-mode "$N" 2>&1
}

expect_reject() {  # expect_reject <name> <env=value ...>
  local name="$1"; shift
  local out rc
  out="$(launcher "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq 2 && "$out" == *"PRR_AGENT"* ]]; then
    pass "$name"
  else
    fail "$name" "exit $rc (want 2 with a PRR_AGENT message); output: $(head -1 <<<"$out")"
  fi
}
expect_accept() {  # expect_accept <name> <env=value ...> -- validation passes;
  # the run then stops at tmux missing (exit 3), never opening a pane.
  local name="$1"; shift
  local out rc
  out="$(launcher "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq 3 && "$out" == *"tmux not on PATH"* ]]; then
    pass "$name"
  else
    fail "$name" "exit $rc (want 3 ['tmux not on PATH']); output: $(head -1 <<<"$out")"
  fi
}

expect_reject "CLI with a space is refused" PRR_AGENT_CLI="npx opencode" PRR_FANOUT=tmux
expect_reject "ARGS metacharacter is refused" PRR_AGENT_ARGS="run;Evil" PRR_FANOUT=tmux
expect_reject "opencode run is refused (non-interactive)" PRR_AGENT_CLI=opencode PRR_AGENT_ARGS="run --agent build" PRR_FANOUT=tmux
expect_reject "--auto is refused (auto-approves the gate)" PRR_AGENT_CLI=opencode PRR_AGENT_ARGS="--prompt --auto" PRR_FANOUT=tmux
expect_reject "claude -p is refused (non-interactive)" PRR_AGENT_ARGS="-p" PRR_FANOUT=tmux
expect_accept "opencode --prompt is accepted" PRR_AGENT_CLI=opencode PRR_AGENT_ARGS="--prompt" PRR_FANOUT=tmux
expect_accept "no CLI/ARGS configured is accepted" PRR_FANOUT=tmux

echo
if [[ "$fails" -eq 0 ]]; then
  echo "all pane-cmd checks pass"
else
  echo "$fails pane-cmd check(s) FAILED"
  exit 1
fi
