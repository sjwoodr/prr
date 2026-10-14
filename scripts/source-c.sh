#!/usr/bin/env bash
# source-c.sh — prr's opt-in Source C through pi: an independent general review
# from a model outside Claude (glm, kimi, gpt-oss, a local model), run as a
# read-only agent. A Claude model is not run here: the skill launches it as a
# subagent with the same brief (scripts/source-c-brief.md), which costs nothing
# extra and runs in parallel.
#
# Usage:
#   source-c.sh [--bg] <pr-number> [model]   model defaults to $PRR_SOURCE_C_MODEL
#
# Writes /tmp/pr-<N>-source-c.md (prose ending in the fenced json block) and
# stamps c-done on the shared clock only for a real report. --bg, the thinking
# level and the hollow-report rule are as in source-b.sh. The diff goes to
# wherever the model runs, so there is no default model.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

PI_PASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pi-pass-common.sh
. "$PI_PASS_DIR/pi-pass-common.sh"

bg=0
[[ "${1:-}" == "--bg" ]] && { bg=1; shift; }
number="${1:?usage: source-c.sh [--bg] <pr-number> [model]}"
model="${2:-${PRR_SOURCE_C_MODEL:-}}"

# Bare Claude names (and claude-* ids) are the skill's subagent path; through
# pi they would bill an API key instead of the subscription.
case "${model##*/}" in
  opus|sonnet|haiku|fable|claude-*)
    echo "source-c: '$model' is a Claude model: launch it as a subagent with scripts/source-c-brief.md, not through pi" >&2
    exit 2 ;;
esac
pi_pass_preflight source-c "$number" "$model" || exit 2

"$PI_PASS_DIR/source-b-clock.sh" c-start "$number" >/dev/null
if (( bg )); then
  pi_pass_detach "/tmp/pr-${number}-source-c.log" "$0" "$number" "$model"
  exit 0
fi

brief="$(sed "s/{{N}}/${number}/g" "$PI_PASS_DIR/source-c-brief.md")"
pi_pass_run source-c "$number" "$model" "$brief" "/tmp/pr-${number}-source-c.md" c-done || exit 1
