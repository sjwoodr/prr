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
# PRR_PASS_HARNESS: pi, opencode or codex; unset, the first one installed in
# that order (pass-common.sh has why each is safe to run read-only).
# PRR_PASS_THINKING sets the thinking level (default high; off for a local
# Ollama model, whose unbudgeted thinking can run away).
# PRR_PASS_MIN_SECONDS (default 30): a run faster than this is hollow.
#
# Run it right after setup-review.sh, do Source A, then read
# /tmp/pr-<N>-source-b.md: a prose report ending in the fenced json block the
# skill's step 2 describes. Needs one of the harnesses and a model it knows; there is deliberately no default model, because the diff
# goes wherever the model runs.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

PASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pass-common.sh
. "$PASS_DIR/pass-common.sh"

bg=0
[[ "${1:-}" == "--bg" ]] && { bg=1; shift; }
number="${1:?usage: source-b.sh [--bg] <pr-number> [model]}"
model="${2:-${PRR_SOURCE_B_MODEL:-}}"
pass_preflight source-b "$number" "$model" || exit 2

"$PASS_DIR/source-b-clock.sh" start "$number" >/dev/null
if (( bg )); then
  pass_detach "/tmp/pr-${number}-source-b.log" "$0" "$number" "$model"
  exit 0
fi

wt="/tmp/pr-${number}-wt"
diff="/tmp/pr-${number}-diff.txt"
view="/tmp/pr-${number}-view.json"

# The areas and finding rules follow source-c-brief.md's. Measured 2026-11-09
# with gpt-oss 120b on one PR: a shorter brief (topics and "verify before you
# report" only) gave three blockers, none real (a fail-closed path called a
# bypass, a cache that exists called missing, "tests pass" with no shell); this
# one gave none in three runs and covered every area.
brief="You are Source B in a pull request review: a security-focused deep
pass. Read only; do not modify files or run tests.

- Diff: $diff
- PR description: the body field of $view
- Full checkout of the PR head: $wt (read surrounding code there by absolute path)

Work through every area below. For each one, report findings or add a
cleared entry saying what you checked and why it holds; an area that does not
apply gets one cleared entry saying so. Skipping an area silently is the one
wrong answer.

1. Reach: who and what can call the changed code (HTTP, direct invoke, queue,
   schedule), and what they control in its input.
2. Authorisation on every path: each way through the changed code, including
   error and fallback paths. Does every path that should refuse actually
   refuse (fail closed)? Does any path skip a check?
3. Isolation: tenant, account or environment boundaries the change touches.
   Can one tenant's request reach another's data or secrets?
4. Secrets and configuration: what is read, from where, what gets logged, and
   what a missing or malformed value does.
5. Permissions and infrastructure: IAM, roles, policies, network or resource
   changes in the diff, and anything broader than the code needs.
6. Tests on security paths: for each test the change adds or edits, name the
   production line it pins and say whether reverting that line would make it
   fail. A test that would still pass, or that lost a case, role or assertion,
   is a finding.

Rules for a finding:

- It must be on a line the diff changes, or be something a changed line
  breaks. A problem in code the PR does not touch is out of scope.
- Give a concrete failure_scenario: the input or sequence of events, and the
  wrong outcome. If the scenario ends with the code refusing, returning false
  or throwing as intended, that is the code working, not a finding.
- Before calling something missing (a check, a cache, a permission, a test),
  search for it and say in evidence where you looked.
- A claim that the change made something worse must compare against the old
  code: the - lines of the diff.
- A claim about every/all/none/only must name the members you enumerated.
- You cannot run anything. Never say tests or builds pass or fail; say what
  you could not verify instead.
- Severity: blocker only when merging causes a concrete wrong outcome you
  described; notable for a real problem with a narrower or less likely impact;
  nit for the rest. 'May', 'could' and 'if a future change' are nits at most.
- Open the code that proves it and quote the lines in evidence. No evidence,
  no finding; an empty list is a fine answer.

End your reply with a fenced json block, exactly this shape. Prefix each
title with its area number, e.g. \"[2] ...\".
{\"findings\":[{\"severity\":\"blocker | notable | nit\",\"title\":\"\",\"file\":\"path under $wt\",\"line\":0,\"failure_scenario\":\"\",\"fix\":\"\",\"verified\":\"read-the-code | inferred-from-diff | assumption\",\"evidence\":\"\"}],\"cleared\":[{\"claim\":\"\",\"evidence\":\"\"}]}"

pass_run source-b "$number" "$model" "$brief" "/tmp/pr-${number}-source-b.md" b-done || exit 1
