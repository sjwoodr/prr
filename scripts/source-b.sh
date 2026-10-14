#!/usr/bin/env bash
# source-b.sh — prr's Source B for a harness with no subagent tool (pi, a bare
# CLI): runs the security pass as a separate read-only agent and stamps its
# clock itself, so `source_b: returned` can only be recorded when it ran.
#
# Usage:
#   source-b.sh <pr-number> [model]       model defaults to $PRR_SOURCE_B_MODEL
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

if pi -p --no-session --no-extensions --no-skills --no-context-files \
     --tools read,grep,find,ls --model "$model" "$brief" >"$out" 2>&1; then
  "$script_dir/source-b-clock.sh" b-done "$number" >/dev/null
  echo "source-b: done, report in $out"
else
  echo "source-b: the agent failed (exit $?); see $out. Record source_b as failed." >&2
  exit 1
fi
