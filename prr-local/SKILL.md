---
name: prr-local
description: Review a GitHub pull request with the local Ollama model, as a single-source pass. Use this, never the full prr skill, whenever you are running on a local model and asked to review a PR.
---

# prr-local

**When invoked, run the review command below on the given PR right away; ask for the PR only if none was given.**

A single-source review of a pull request by a local model, sharing prr's setup
and posting scripts.

The review is a script, not a procedure you follow. **Do not review the diff
yourself.** Run the script below.

## Review

```
python3 ~/.claude/skills/prr/scripts/prr-local.py <PR-url-or-number> --save-only --think-budget 400
```

- Keep `--think-budget 400` unless the user names another budget; drop it only
  if they ask for no thinking. Never use plain `--think` (uncapped).
- Add `--silent` if the user asks for no chat signals.
- Use an Ollama cloud model (`--model gpt-oss:120b-cloud`) only when the user
  names one: it sends the diff off the machine.
- It makes one call per changed file, so it can take minutes. Stream the
  output, and start no other heavy request alongside it. Progress is in
  `/tmp/prr-local-<N>.log`.

Read the `reviewing N file(s)` line first. A PR you already reviewed with no
commits since runs in re-review mode against an empty diff, reviews zero files,
and still proposes APPROVE. That result means nothing.

The script prints the findings, the summary body, and a proposed verdict, then
saves `/tmp/pr-<N>-review.json` and stops. It posts nothing.

Relay its report to the user close to verbatim. It is one pass by a quantized
local model, so flag it as lower confidence than a normal prr review and do not
add findings of your own on top.

## Posting

Nothing reaches GitHub until a human reads the report and says yes **in this
conversation**. Their approval is the only thing that authorizes the next
command, so never run it pre-emptively, and never infer consent from an earlier
message about a different PR.

```
python3 ~/.claude/skills/prr/scripts/prr-local.py <PR> --post-saved APPROVE
```

Valid choices: `APPROVE`, `APPROVE_BARE` (approve with no inline comments),
`REQUEST_CHANGES`, `COMMENT`, and `DISCARD` (post nothing). This runs no
inference; it posts the saved review and cleans up. If commits landed since the
review, it refuses rather than posting a stale review, which is correct: re-run
the review.

When you ask the user to choose, list all five, and tell them they can add a
note of their own to any choice except `DISCARD`. If they give one, pass it
through a quoted heredoc, so backticks and `$` in it reach GitHub unchanged:

```
python3 ~/.claude/skills/prr/scripts/prr-local.py <PR> --post-saved APPROVE --note - <<'NOTE'
<their text, exactly as they wrote it>
NOTE
```

Never write or reword a note yourself. It goes at the end of the review body.

If the user declines, discard: `--post-saved DISCARD` posts nothing, clears the
chat :eyes: marker, and removes the worktree and the saved review.

Do not hand-edit the saved file, and do not post with `gh` directly. The script
builds the payload from it, and post-review.sh validates the head sha.
