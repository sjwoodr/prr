#!/usr/bin/env bash
#
# source-b-clock.sh -- wall-clock budget for the Source B security agent.
#
# WHY THIS OWNS ONLY THE CLOCK, NOT THE DETECTION
#
# Source B runs as a background agent whose completion is delivered to the
# model as a task notification, not written to a file. No script can observe
# that it finished, so this cannot block until done the way prr-fanout.sh
# blocks on its result files. It stamps when the agent was spawned and reports
# how much budget is left; the skill decides whether to keep waiting.
#
# The budget exists because the step 5 approval gate now waits for Source B
# (see SKILL.md "The gate WAITS for Source B"). Waiting forever on an agent
# that will never answer is worse than proceeding single-source, so the wait
# needs an upper bound.
#
# Usage:
#   source-b-clock.sh start <pr-number>    # stamp the spawn time
#   source-b-clock.sh check <pr-number>    # report the verdict
#
# `check` prints one line of KEY=VALUE pairs on stdout, always exit 0 so a
# caller under `set -e` is never killed by a verdict:
#
#   VERDICT=wait     ELAPSED=123 BUDGET=600 REMAINING=477
#   VERDICT=timeout  ELAPSED=612 BUDGET=600 REMAINING=0
#   VERDICT=nocap    ELAPSED=123 BUDGET=0
#   VERDICT=nostamp  ELAPSED=0   BUDGET=600 REMAINING=600
#
# nostamp means `start` was never run for this PR. It reports `nostamp` rather
# than `timeout` on purpose: a missing stamp is a skill bug, and resolving it
# toward "keep waiting" fails in the safe direction. A missing stamp that read
# as an expired budget would silently turn every review single-source, which is
# the exact outcome the gate rule exists to prevent.
#
# Config (env):
#   PRR_SOURCE_B_TIMEOUT  budget in seconds; default 600 (10 min); 0 = no cap.
#                         Anything non-numeric or negative falls back to the
#                         default with a notice on stderr -- a typo must not
#                         silently disable the wait.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail
TAG="source-b-clock"

DEFAULT_BUDGET=600

usage() {
  echo "$TAG: usage: $(basename "$0") start|check <pr-number>" >&2
  exit 2
}

mode="${1:-}"
number="${2:-}"

[[ -n "$mode" && -n "$number" ]] || usage
case "$mode" in
  start | check) ;;
  *) usage ;;
esac
# Digits only: the number lands in a /tmp path, so reject anything that could
# walk out of it or expand.
[[ "$number" =~ ^[0-9]+$ ]] || {
  echo "$TAG: pr-number must be digits, got '$number'" >&2
  exit 2
}

stamp="/tmp/pr-${number}-sourceb-started"

# Budget resolution. Bash 3.2 (stock macOS) is the floor, so no fancy
# expansions. `0` is an explicit "no cap", matching PRR_FANOUT_TIMEOUT_MINS.
budget="${PRR_SOURCE_B_TIMEOUT:-$DEFAULT_BUDGET}"
if ! [[ "$budget" =~ ^[0-9]+$ ]]; then
  echo "$TAG: PRR_SOURCE_B_TIMEOUT='$budget' is not a non-negative integer; using ${DEFAULT_BUDGET}s" >&2
  budget="$DEFAULT_BUDGET"
fi

now="$(date +%s)"

if [[ "$mode" == "start" ]]; then
  printf '%s\n' "$now" >"$stamp"
  if [[ "$budget" -eq 0 ]]; then
    echo "$TAG: source B clock started for PR #${number}; no cap (PRR_SOURCE_B_TIMEOUT=0)"
  else
    echo "$TAG: source B clock started for PR #${number}; budget ${budget}s"
  fi
  exit 0
fi

# check
if [[ ! -r "$stamp" ]]; then
  echo "$TAG: no spawn stamp at $stamp -- was 'start' run? Resolving toward waiting." >&2
  echo "VERDICT=nostamp ELAPSED=0 BUDGET=${budget} REMAINING=${budget}"
  exit 0
fi

started="$(cat "$stamp" 2>/dev/null || true)"
if ! [[ "$started" =~ ^[0-9]+$ ]]; then
  echo "$TAG: spawn stamp at $stamp is not an epoch ('$started'). Resolving toward waiting." >&2
  echo "VERDICT=nostamp ELAPSED=0 BUDGET=${budget} REMAINING=${budget}"
  exit 0
fi

elapsed=$((now - started))
# A stamp in the future (clock step, file copied between machines) would give a
# negative elapsed and read as a fresh budget forever. Clamp instead.
[[ "$elapsed" -lt 0 ]] && elapsed=0

if [[ "$budget" -eq 0 ]]; then
  echo "VERDICT=nocap ELAPSED=${elapsed} BUDGET=0"
  exit 0
fi

remaining=$((budget - elapsed))
[[ "$remaining" -lt 0 ]] && remaining=0

if [[ "$elapsed" -ge "$budget" ]]; then
  echo "VERDICT=timeout ELAPSED=${elapsed} BUDGET=${budget} REMAINING=0"
else
  echo "VERDICT=wait ELAPSED=${elapsed} BUDGET=${budget} REMAINING=${remaining}"
fi
exit 0
