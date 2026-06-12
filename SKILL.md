---
name: prr
description: >-
  Dual-source review of a GitHub PR in an isolated git worktree: a primary
  review pass plus a security-focused agent, synthesized into proposed inline
  GitHub review comments that are posted only after explicit user approval.
  Running it again on a PR you already reviewed does an incremental
  re-review — checking only whether your prior findings were addressed by the
  commits pushed since. Reviewing your own PR is auto-detected as a
  self-review: the same full fresh pass, but report-only with nothing posted
  back to the PR. Use when the user runs /prr, asks to review a pull
  request, or provides a PR URL or number to review.
---

<!--
  prr — Author: Steve Woodruff (@sjwoodr)
  Licensed under the MIT License. See the LICENSE file in this skill directory.
-->

# prr — PR review workflow

Personal dual-source PR review. The PR to review is provided as the skill
argument (a full GitHub URL or a bare number). Follow every step in order.
The approval gate in step 5 is hard: post nothing to GitHub until the user
explicitly says yes. This is not the bundled `/review` skill.

Two bundled scripts handle the deterministic mechanics (setup, posting,
cleanup); the steps between them need judgment and stay manual. A full PR
URL works from any directory — the setup script fetches the PR straight
from GitHub when you do not have the repo cloned locally. A bare PR number
must be run from inside the PR's own git repository.

**Script paths.** The two scripts live in this skill's own `scripts/`
directory. Before running them, set `SKILL_DIR` to the absolute path of the
directory that contains this `SKILL.md` (i.e. wherever this skill is
installed — e.g. `~/.claude/skills/prr`, `~/.cursor/skills/prr`, or a
project `.cursor/skills/prr`). Every command below invokes the scripts via
`"$SKILL_DIR"/scripts/...`, so the skill runs the same regardless of where
it was installed:

```
SKILL_DIR=<absolute path to the directory containing this SKILL.md>
```

**Three modes.** Step 1 detects which one applies:

- **Full review** (steps 2-6) — the default: a fresh dual-source review.
- **Self-review** — runs when the PR author is you (your own PR). It does the
  same full dual-source pass as a full review, but it is report-only: you
  deliver the findings and verdict to the user and post nothing back to the
  PR. Treat it as a zero-knowledge fresh look. See the report-only handling
  in steps 5 and 6. Self-review takes precedence over re-review.
- **Re-review** — runs instead when you have already posted a prr review on
  this PR. It skips the dual-source pass and only checks whether your prior
  findings were addressed by the commits pushed since the review. See the
  **Re-review** section at the end.

Honour the mode the setup script reports. The only exception: if the user
explicitly asks for a full review of an already-reviewed PR, run the full
flow regardless.

## Tooling

Throughout this workflow:

- **GitHub access goes through `gh`.** Always. The bundled scripts already
  do; any ad hoc GitHub call in the manual steps (PR data, review state,
  comment threads) must use `gh` too — never raw `curl` against the API.
- **Search the worktree with `rg` (ripgrep).** Use `rg` for every code
  search in steps 2-4. If `rg` is not installed, fall back to `grep -rn` —
  scope it to the relevant files or directories and exclude `.git`
  (e.g. `--exclude-dir=.git`) so the search stays clean.
- **Inspect files by absolute path — never `cd` into the worktree.** Prefer
  the Read / Glob / Grep tools (or `rg`) pointed at the full
  `/tmp/pr-<N>-wt/...` path. Do NOT use `cd /tmp/pr-<N>-wt/... && ls && cat`
  style compound commands: Claude Code applies a built-in "compound command
  contains `cd`" guard that forces a manual approval prompt on every such
  call and is NOT silenceable via the permissions allow-list. Reading by
  absolute path avoids the prompt entirely and Read gives line numbers for
  the `file:line` citations step 3 needs.
- **Run the bundled scripts bare — never pipe them through `tee`.** Invoke
  `setup-review.sh` and `post-review.sh` exactly as documented, with no
  `2>&1 | tee /tmp/...` wrapper. Piping turns the call into a pipeline, and
  Claude Code matches each pipeline segment against the allow-list
  separately: the `tee` segment is not allow-listed, so the whole call
  prompts even though the script itself is allowed. There is also nothing to
  capture — both scripts already write their re-readable artifacts to `/tmp`
  (`pr-<N>-view.json`, `pr-<N>-diff.txt`, `pr-<N>-comments.json`, and the
  re-review extras), which is what the review consumes. The general "tee
  output to /tmp" habit does not apply to these two scripts.

## 1. Set up the review

Run the bundled setup script with the PR reference from the skill argument:

```
"$SKILL_DIR"/scripts/setup-review.sh <PR-url-or-number>
```

It resolves owner/repo/number and checks out the PR head at
`/tmp/pr-<N>-wt` — a detached `git worktree` when you are inside the PR's
repo, otherwise a standalone checkout fetched directly from GitHub (no
local clone needed). It writes the review artifacts to `/tmp/`
(`pr-<N>-view.json`, `pr-<N>-diff.txt`, `pr-<N>-comments.json`), and prints
a `MODE:` line plus a `pr source:` line naming which path it used. In
re-review mode it additionally writes `pr-<N>-prior-review.json` and
`pr-<N>-since-diff.txt`.

Then:
- Read the `MODE:` line. If `MODE: re-review`, skip steps 2-6 and jump to
  the **Re-review** section. If `MODE: full-review`, continue below. If
  `MODE: self-review`, also continue below (it runs as a full review), but
  honour the report-only handling in steps 5 and 6 — you post nothing back
  to the PR.
- Read the diff, the PR description (`body` in the view JSON), and the
  changed-file list.
- Read the prior review state (`reviews` and `comments` in the view JSON,
  and `pr-<N>-comments.json` for inline threads). Note what other
  reviewers (e.g. Copilot) already raised so step 3 does not duplicate it.
- **Linked ticket / issue context.** Scan the PR title and description
  for a linked Jira ticket (e.g. `https://<site>.atlassian.net/browse/KEY-NNNN`
  or a bare `KEY-NNNN` reference) or GitHub issue (`#NNNN`,
  `owner/repo#NNNN`, full `https://github.com/owner/repo/issues/NNNN`).
  If found, fetch its details and acceptance criteria so they frame what
  "correct" looks like for this PR. Source A (your own pass) uses the
  AC to check whether the PR actually does what it claims. Source B
  (the security agent in step 2) is **not** given the ticket — a pure
  security review should hunt for real issues regardless of stated
  scope, and ticket framing could bias it toward "in scope, skip".
  - **GitHub issue:** `gh issue view <num> --repo <owner/repo>` (read
    the body + comments for AC).
  - **Jira ticket:** use the Atlassian MCP `getJiraIssue` tool if
    available. If no Atlassian MCP is configured, the tool is missing,
    or the call fails for auth reasons, silently skip the fetch and
    proceed without ticket context. Note the skip once in your console
    output so the user knows the ticket was not read. Do **not** mention
    the skip in any drafted review body or inline comment — that detail
    belongs to the local workflow, not to the PR.
  - If no ticket/issue is linked, skip this bullet without comment.
- Keep the **head sha** the script prints — step 6 needs it for `commit_id`.
- All file inspection happens inside `/tmp/pr-<N>-wt`. Never check the PR
  out in the main working tree.

## 2. Dual-source review

Two independent passes. **Spawn Source B first — in the background, as the
very first action of this step, before you begin Source A.** Source B
depends only on the diff and worktree from step 1, so it has no reason to
wait on Source A. Running it serially after your own review wastes wall
time; the two passes must overlap.

- **Source B** — one `codebase-analyst` agent doing a security-focused
  deep pass: cross-tenant / isolation, auth, secrets, blast radius,
  error handling, IAM and infrastructure permission changes, and test
  gaps on security-relevant paths. Spawn it once, with
  `run_in_background: true`, immediately after step 1. Give it the diff
  path, the PR description, and the worktree path `/tmp/pr-<N>-wt` so it
  can read surrounding code. A bare diff plus worktree is enough — do not
  delay the spawn to hand-feed it findings or `file:line` pointers; the
  agent explores on its own, and precise briefing is not worth
  serializing the work behind your own review.
- **Source A** — your own primary review of the diff: correctness,
  project conventions, test coverage, and the obvious security surface.
  Do this while Source B runs in the background.

Collect Source B's result once it completes. Verify any high-risk claim
it makes yourself before trusting it.

## 3. Synthesize

- Merge both passes. Dedupe overlapping findings.
- Drop false positives and anything an existing review thread already
  covers (step 1).
- Keep only legitimate, evidence-backed findings. For each, cite
  `file:line` from the worktree.
- Rank: blocker / notable / nit.

## 4. Draft inline comments

- One inline comment per finding: file path, line, and body.
- Inline review comments can only anchor on lines inside the PR diff.
  For a finding on a file not in the diff, anchor on the closest related
  line that is in the diff and name the real location in the body, or
  fall back to the review summary body.
- **Suggested fix blocks.** When the fix is obvious and small, end the
  comment body with a GitHub ` ```suggestion ` block so the author can
  accept it with the "Commit suggestion" button. Only do this when all of
  these hold; otherwise describe the fix in prose and skip the block:
  - The fix is unambiguous - there is one clearly-correct replacement, not
    a choice among options or something that needs the author's judgment.
  - It is small: a single line or a short contiguous hunk, roughly 10 lines
    or fewer. Above that, or if it spans non-adjacent regions, describe it
    instead.
  - It is self-contained: no new imports, helpers, or symbols defined
    elsewhere, and no follow-on edits in other files needed to make it
    compile or behave.
  Mechanics that must be exact, since the block is a literal replacement:
  - The suggestion replaces the comment's anchored line range verbatim.
    For a single-line fix, anchor on that one line. For a multi-line fix,
    make it a multi-line comment whose range (`start_line`..`line`, see
    step 6) covers exactly the lines being replaced - no more, no less.
    The replacement may contain a different number of lines than the range.
  - Reproduce the original indentation exactly inside the block; GitHub
    pastes it as-is.
  - The anchored line(s) must be inside the PR diff, same as any inline
    comment. A fix outside the diff cannot be a suggestion - describe it.
  - The suggestion block holds real code and is exempt from the ASCII
    prose rules below: write the code exactly as it must appear. The ASCII
    rules still apply to the prose part of the comment.
- Writing style: plain ASCII only. No em-dashes (`—`), no arrows
  (`→` `⇒` `←` `↔`), no special bullets (`•`), no ellipsis (`…`), no
  curly quotes (`"` `"` `'` `'`). Use ASCII equivalents: regular hyphen,
  comma, parens, colon, or split the sentence; `->` or words like
  "becomes" / "now fixed" instead of `→`; `-` instead of `•`; `...`
  instead of `…`; straight `"` / `'`. Never use the word "footgun".
  Go out of your way to make your comments sound human, not AI responses. 
  Inline comments only, never a single rollup comment.
- Self-check before posting: scan the drafted review body and every
  inline comment for the banned characters above. If any appear,
  rewrite. This is the only reliable enforcement, since the rule is
  easy to break when copying structure from prior context. Exclude the
  contents of any ` ```suggestion ` block from this check - that is
  verbatim code, not prose.
- Choose a verdict: `APPROVE` (no blockers), `REQUEST_CHANGES`, or
  `COMMENT`.

## 5. Approval gate — STOP HERE

Show the user:
- The ranked findings.
- Every drafted inline comment (file, line, body) verbatim.
- The proposed verdict.

Ask whether to post. Post nothing until the user explicitly approves.
If the user wants edits, revise and ask again.

**Self-review (`MODE: self-review`):** there is nothing to post, so this is a
report, not a gate. Deliver the same ranked findings, the drafted comments
(as your own notes), and the verdict directly to the user. Do not ask whether
to post, and do not post — go straight to step 6 to clean up.

## 6. Post and clean up (only after approval)

Build the review payload as a JSON file at `/tmp/pr-<N>-review.json`
containing:
- `commit_id` — the head sha from step 1
- `event` — `APPROVE` / `REQUEST_CHANGES` / `COMMENT`
- `body` — the review summary
- `comments` — array of `{path, line, side, body}`. For a multi-line
  comment (needed when a `suggestion` block replaces more than one line,
  see step 4), also set `start_line` and `start_side` so the range is
  `start_line`..`line`; the suggestion replaces exactly that range.

Then run the post script, which submits the review in one call and
removes the worktree and temp artifacts:

```
"$SKILL_DIR"/scripts/post-review.sh <PR-url-or-number> /tmp/pr-<N>-review.json
```

If the user declined to post, run it with no payload argument to clean
up only:

```
"$SKILL_DIR"/scripts/post-review.sh <PR-url-or-number>
```

**Self-review (`MODE: self-review`):** never build or post a payload. Always
run the cleanup-only invocation (no payload argument) so nothing can reach
the PR:

```
"$SKILL_DIR"/scripts/post-review.sh <PR-url-or-number>
```

Confirm the worktree is removed and report the result.

### Optional: approval reaction on a chat post

If your team announces each PR as a one-liner (with the GitHub pull URL) in a
chat channel, `post-review.sh` drops a reaction on that post to signal the review
outcome:

- **APPROVE** -> `:white_check_mark:`
- **COMMENT** or **REQUEST_CHANGES** -> `:speech_balloon:` (has feedback to read)
- **Nothing posted** (gate declined, self-review, re-review report-only) -> no
  reaction at all. The reaction only happens on the same path that posts a
  review, so declining to post never touches the chat channel.

Both are standard Slack emoji (no custom upload needed). This is fully opt-in and
a no-op unless both environment variables are set:

- `SLACK_BOT_TOKEN` — a Slack bot token with `reactions:write` plus history
  access for the channel (`groups:history` for a private channel,
  `channels:history` for a public one). The bot must be a member of the channel.
- `PRR_CODE_REVIEWS_CHANNEL` — the channel ID to search (e.g. `C0XXXXXXX`).

With neither set, prr behaves exactly as before. The reaction is added by the
bot; multiple reactions are fine (one per reviewer), and the bot re-reacting to
the same post with the same emoji is a harmless no-op. The step is best-effort: if
the post is not found or Slack errors, it logs a note and does not fail the run
(the review is already posted).

---

# Re-review (incremental)

Reached only when `setup-review.sh` prints `MODE: re-review` — the PR
already carries a prr review from you. Do **not** repeat the dual-source
review and do **not** spawn Source B. Check only whether the findings from
your prior review were addressed by the commits pushed since it.

Extra artifacts from step 1, alongside the usual ones:
- `pr-<N>-prior-review.json` — your prior review (`review`: id, state,
  `submitted_at`, `commit_id`, body) and its inline findings
  (`findings[]`: `path`, `line`, `body`).
- `pr-<N>-since-diff.txt` — the diff from the prior review's commit to the
  current head, scoped to the files this PR touches (so a `main` merge into
  the branch between reviews does not add unrelated noise).

## R1. Gather

- Read `pr-<N>-prior-review.json`: the prior verdict and each finding.
- Read `pr-<N>-since-diff.txt` and the commit count the setup script
  printed. If that file says the prior commit was not fetchable (rebase or
  force-push), fall back to the full PR diff (`pr-<N>-diff.txt`) and say so
  in the report.

## R2. Check each prior finding

For every finding in the prior review, decide its status from the
since-diff and the current file in the worktree (`/tmp/pr-<N>-wt`). Use
`rg` for any code search.

- **Fixed** — the change resolves the finding.
- **Partially fixed** — addressed but incomplete; say what still remains.
- **Not addressed** — no relevant change since the review.
- **Unclear** — cannot tell from the diff; say why.

Cite the commit or `file:line` that resolves (or fails to resolve) each
one. Then skim the since-diff once for any obvious regression the fixes
introduced. This is a light pass, not a new dual-source review.

## R3. Re-review gate — STOP HERE

Show the user:
- A per-finding status list — Fixed / Partially fixed / Not addressed /
  Unclear — each with its evidence.
- Any regression noticed in R2.
- A proposed updated verdict: `APPROVE` if every blocker is fixed,
  otherwise `REQUEST_CHANGES` or `COMMENT`.

Ask what to do. Post nothing until the user explicitly says so.

## R4. Post and clean up (only after approval)

The user chooses one of:

- **Report only** — post nothing. Run the post script with no payload
  argument to clean up.
- **Post a follow-up review** — build `/tmp/pr-<N>-review.json` as in
  step 6, with `commit_id` set to the **current** head sha. The `body`
  summarizes the per-finding status; include inline `comments` only on
  findings that are still open or newly regressed (anchored on lines in
  the current diff, per step 4's anchoring rule) — not on fixed ones.
  Then run the post script with the payload.

Either way, finish with `post-review.sh` so the worktree and artifacts are
removed. Confirm removal and report the result.
