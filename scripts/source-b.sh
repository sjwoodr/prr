#!/usr/bin/env bash
# source-b.sh — prr's Source B for a harness with no subagent tool (pi, a bare
# CLI): runs the security pass as a separate read-only agent and stamps its
# clock itself, so `source_b: returned` can only be recorded when it ran.
#
# Usage:
#   source-b.sh <pr-number> [model]       model defaults to $PRR_SOURCE_B_MODEL
#
# PRR_SOURCE_B_THINKING sets pi's thinking level (default high).
# PRR_SOURCE_B_MIN_SECONDS (default 30): a run faster than this is hollow.
#
# Run it in the background right after setup-review.sh, do Source A, then read
# /tmp/pr-<N>-source-b.md: a prose report ending in the fenced json block the
# skill's step 2 describes. Needs pi (https://github.com/badlogic/pi-mono) and
# a model it knows; there is deliberately no default model, because the diff
# goes wherever the model runs.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

number="${1:?usage: source-b.sh <pr-number> [model]}"
model="${2:-${PRR_SOURCE_B_MODEL:-}}"
[[ -n "$model" ]] || { echo "source-b: no model: pass one or set PRR_SOURCE_B_MODEL" >&2; exit 2; }
command -v pi >/dev/null || { echo "source-b: pi is not installed" >&2; exit 2; }

wt="/tmp/pr-${number}-wt"
diff="/tmp/pr-${number}-diff.txt"
view="/tmp/pr-${number}-view.json"
out="/tmp/pr-${number}-source-b.md"
[[ -d "$wt" && -r "$diff" ]] || { echo "source-b: run setup-review.sh first" >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/source-b-clock.sh" start "$number" >/dev/null

brief="You are Source B in a two-source pull request review: a security-focused
deep pass. Read only; do not modify files or run tests.

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

thinking="${PRR_SOURCE_B_THINKING:-high}"
started=$(date +%s)
rc=0
pi -p --no-session --no-extensions --no-skills --no-context-files \
  --tools read,grep,find,ls --model "$model" --thinking "$thinking" \
  "$brief" </dev/null >"$out" 2>&1 || rc=$?
if (( rc != 0 )); then
  echo "source-b: the agent failed (exit $rc); see $out. Record source_b as failed." >&2
  exit 1
fi
elapsed=$(( $(date +%s) - started ))

# A clean exit is not a report. One trial returned an empty json block after
# 2 s and was recorded as `returned`. Too fast to have read the diff, or no
# finding, no cleared item and almost no prose, is a failure: no b-done stamp.
min_seconds="${PRR_SOURCE_B_MIN_SECONDS:-30}"
items=$(grep -cE '"(claim|title)"[[:space:]]*:[[:space:]]*"[^"]' "$out" || true)
prose=$(wc -c <"$out")
if (( elapsed < min_seconds )) || (( items == 0 && prose < 400 )); then
  echo "source-b: hollow report (${elapsed}s, ${items} findings/cleared, ${prose} bytes); see $out. Record source_b as failed." >&2
  exit 1
fi

"$script_dir/source-b-clock.sh" b-done "$number" >/dev/null
echo "source-b: done in ${elapsed}s, report in $out"
