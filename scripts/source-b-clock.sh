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
#   source-b-clock.sh a-done <pr-number>   # your own pass (Source A) finished
#   source-b-clock.sh b-done <pr-number>   # Source B's report arrived
#   source-b-clock.sh c-start|c-check|c-done <pr-number>
#                                          # the same for the opt-in Source C,
#                                          # with its own stamp and budget
#
# a-done / b-done only record a time (first call wins) for the per-pass timings
# post-review.sh writes into the review's hidden prr-meta marker. They live here
# rather than in a script of their own so they need no extra allow-list entry.
#
# `check` prints one line of KEY=VALUE pairs on stdout, always exit 0 so a
# caller under `set -e` is never killed by a verdict:
#
#   VERDICT=wait     ELAPSED=123 BUDGET=900 REMAINING=777
#   VERDICT=timeout  ELAPSED=912 BUDGET=900 REMAINING=0
#   VERDICT=nocap    ELAPSED=123 BUDGET=0
#   VERDICT=nostamp  ELAPSED=0   BUDGET=900 REMAINING=900
#   VERDICT=done     ELAPSED=130 BUDGET=900
#
# done means the pass's b-done / c-done stamp exists, so its report is in.
# source-b.sh and source-c.sh stamp it only for a real report, which makes it
# the one signal a detached pi/opencode/codex run gives.
#
# nostamp means `start` was never run for this PR. It reports `nostamp` rather
# than `timeout` on purpose: a missing stamp is a skill bug, and resolving it
# toward "keep waiting" fails in the safe direction. A missing stamp that read
# as an expired budget would silently turn every review single-source, which is
# the exact outcome the gate rule exists to prevent.
#
# Config (env):
#   PRR_SOURCE_B_TIMEOUT  budget in seconds; default 900 (15 min); 0 = no cap.
#                         Anything non-numeric or negative falls back to the
#                         default with a notice on stderr -- a typo must not
#                         silently disable the wait.
#   PRR_SOURCE_C_TIMEOUT  the same for Source C (the c-* modes).
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail
TAG="source-b-clock"

DEFAULT_BUDGET=900

usage() {
  echo "$TAG: usage: $(basename "$0") start|check|a-done|b-done|c-start|c-check|c-done <pr-number>" >&2
  exit 2
}

mode="${1:-}"
number="${2:-}"

[[ -n "$mode" && -n "$number" ]] || usage
# Source C reuses every rule below with its own stamp, budget and wording;
# c-done is a done stamp like a-done and b-done.
source_name="source B"; stamp_name="sourceb-started"; budget_var="PRR_SOURCE_B_TIMEOUT"; done_name="b-done"
case "$mode" in
  start | check | a-done | b-done | c-done) ;;
  c-start | c-check)
    mode="${mode#c-}"
    source_name="source C"; stamp_name="sourcec-started"; budget_var="PRR_SOURCE_C_TIMEOUT"; done_name="c-done" ;;
  *) usage ;;
esac
# Digits only: the number lands in a /tmp path, so reject anything that could
# walk out of it or expand.
[[ "$number" =~ ^[0-9]+$ ]] || {
  echo "$TAG: pr-number must be digits, got '$number'" >&2
  exit 2
}

stamp="/tmp/pr-${number}-${stamp_name}"

# Budget resolution. Bash 3.2 (stock macOS) is the floor, so no fancy
# expansions (an eval stands in for ${!var}; budget_var is one of two fixed
# names above, never input). `0` is an explicit "no cap", matching
# PRR_FANOUT_TIMEOUT_MINS.
eval "budget=\"\${${budget_var}:-\$DEFAULT_BUDGET}\""
if ! [[ "$budget" =~ ^[0-9]+$ ]]; then
  echo "$TAG: ${budget_var}='$budget' is not a non-negative integer; using ${DEFAULT_BUDGET}s" >&2
  budget="$DEFAULT_BUDGET"
fi

now="$(date +%s)"

if [[ "$mode" == "a-done" || "$mode" == "b-done" || "$mode" == "c-done" ]]; then
  done_stamp="/tmp/pr-${number}-${mode}"
  [[ -s "$done_stamp" ]] || printf '%s\n' "$now" >"$done_stamp"
  echo "$TAG: ${mode} recorded for PR #${number}"
  exit 0
fi

if [[ "$mode" == "start" ]]; then
  # A done stamp left by an earlier, uncleaned run of this PR would read as
  # this pass finished before it began, and block this pass's own stamp.
  rm -f "/tmp/pr-${number}-${done_name}"
  printf '%s\n' "$now" >"$stamp"
  if [[ "$budget" -eq 0 ]]; then
    echo "$TAG: ${source_name} clock started for PR #${number}; no cap (${budget_var}=0)"
  else
    echo "$TAG: ${source_name} clock started for PR #${number}; budget ${budget}s"
  fi
  exit 0
fi

# check: a finished pass is done whatever the clock says. A done stamp older
# than this pass's start belongs to an earlier run and is ignored: reporting
# done on it would have the report read while the new pass is still writing it.
done_at="$(cat "/tmp/pr-${number}-${done_name}" 2>/dev/null || true)"
started="$(cat "$stamp" 2>/dev/null || true)"
if [[ "$done_at" =~ ^[0-9]+$ ]]; then
  if [[ ! "$started" =~ ^[0-9]+$ ]]; then
    echo "VERDICT=done ELAPSED=0 BUDGET=${budget}"
    exit 0
  elif (( done_at >= started )); then
    echo "VERDICT=done ELAPSED=$((done_at - started)) BUDGET=${budget}"
    exit 0
  fi
  echo "$TAG: ignoring /tmp/pr-${number}-${done_name}: older than this pass's start" >&2
fi

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
