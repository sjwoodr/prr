#!/usr/bin/env bash
# source-b.sh — prr's Source B for a harness with no subagent tool (pi, a bare
# CLI): runs the security pass as a separate read-only agent and stamps its
# clock itself, so `source_b: returned` can only be recorded when it ran.
#
# Usage:
#   source-b.sh [--bg] <pr-number> [model]   model defaults to $PRR_SOURCE_B_MODEL
#
# --bg detaches and returns at once (log in /tmp/pr-<N>-source-b.log); use it
# whenever the harness's shell tool has no background option of its own.
# PRR_PASS_THINKING sets pi's thinking level (default high).
# PRR_PASS_MIN_SECONDS (default 30): a run faster than this is hollow.
#
# Run it right after setup-review.sh, do Source A, then read
# /tmp/pr-<N>-source-b.md: a prose report ending in the fenced json block the
# skill's step 2 describes. Needs pi (https://github.com/badlogic/pi-mono) and
# a model it knows; there is deliberately no default model, because the diff
# goes wherever the model runs.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

PI_PASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pi-pass-common.sh
. "$PI_PASS_DIR/pi-pass-common.sh"

bg=0
[[ "${1:-}" == "--bg" ]] && { bg=1; shift; }
number="${1:?usage: source-b.sh [--bg] <pr-number> [model]}"
model="${2:-${PRR_SOURCE_B_MODEL:-}}"
pi_pass_preflight source-b "$number" "$model" || exit 2

"$PI_PASS_DIR/source-b-clock.sh" start "$number" >/dev/null
if (( bg )); then
  pi_pass_detach "/tmp/pr-${number}-source-b.log" "$0" "$number" "$model"
  exit 0
fi

wt="/tmp/pr-${number}-wt"
diff="/tmp/pr-${number}-diff.txt"
view="/tmp/pr-${number}-view.json"

brief="You are Source B in a pull request review: a security-focused deep
pass. Read only; do not modify files or run tests.

- Diff: $diff
- PR description: the body field of $view
- Full checkout of the PR head: $wt (read surrounding code there by absolute path)

Look for: cross-tenant and isolation gaps, auth and role mistakes, secrets,
blast radius, error handling, IAM or infrastructure permission changes, and
tests on security-relevant paths that became vacuous (would still pass with the
production behaviour broken) or lost a case, role or assertion.

Verify before you report: for every finding, open the code that proves it and
quote the lines in evidence. A claim about every/all/none/only must name the
members you enumerated. No evidence, no finding; an empty list is a fine answer.

End your reply with a fenced json block, exactly this shape:
{\"findings\":[{\"severity\":\"blocker | notable | nit\",\"title\":\"\",\"file\":\"path under $wt\",\"line\":0,\"failure_scenario\":\"\",\"fix\":\"\",\"verified\":\"read-the-code | inferred-from-diff | assumption\",\"evidence\":\"\"}],\"cleared\":[{\"claim\":\"\",\"evidence\":\"\"}]}"

pi_pass_run source-b "$number" "$model" "$brief" "/tmp/pr-${number}-source-b.md" b-done || exit 1
