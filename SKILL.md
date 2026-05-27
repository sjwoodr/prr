---
name: prr
description: >-
  Dual-source review of a GitHub PR in an isolated git worktree: a primary
  review pass plus a security-focused agent, synthesized into proposed inline
  GitHub review comments that are posted only after explicit user approval.
  Running it again on a PR you already reviewed does an incremental
  re-review — checking only whether your prior findings were addressed by the
  commits pushed since. Use when the user runs /prr, asks to review a pull
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

**Two modes.** Step 1 detects which one applies:

- **Full review** (steps 2-6) — the default: a fresh dual-source review.
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

## 1. Set up the review

Run the bundled setup script with the PR reference from the skill argument:

```
~/.claude/skills/prr/scripts/setup-review.sh <PR-url-or-number>
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
  the **Re-review** section. If `MODE: full-review`, continue below.
- Read the diff, the PR description (`body` in the view JSON), and the
  changed-file list.
- Read the prior review state (`reviews` and `comments` in the view JSON,
  and `pr-<N>-comments.json` for inline threads). Note what other
  reviewers (e.g. Copilot) already raised so step 3 does not duplicate it.
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
- Writing style: plain ASCII only. No em-dashes (`—`), no arrows
  (`→` `⇒` `←` `↔`), no special bullets (`•`), no ellipsis (`…`), no
  curly quotes (`"` `"` `'` `'`). Use ASCII equivalents: regular hyphen,
  comma, parens, colon, or split the sentence; `->` or words like
  "becomes" / "now fixed" instead of `→`; `-` instead of `•`; `...`
  instead of `…`; straight `"` / `'`. Never use the word "footgun".
  Inline comments only, never a single rollup comment.
- Self-check before posting: scan the drafted review body and every
  inline comment for the banned characters above. If any appear,
  rewrite. This is the only reliable enforcement, since the rule is
  easy to break when copying structure from prior context.
- Choose a verdict: `APPROVE` (no blockers), `REQUEST_CHANGES`, or
  `COMMENT`.

## 5. Approval gate — STOP HERE

Show the user:
- The ranked findings.
- Every drafted inline comment (file, line, body) verbatim.
- The proposed verdict.

Ask whether to post. Post nothing until the user explicitly approves.
If the user wants edits, revise and ask again.

## 6. Post and clean up (only after approval)

Build the review payload as a JSON file at `/tmp/pr-<N>-review.json`
containing:
- `commit_id` — the head sha from step 1
- `event` — `APPROVE` / `REQUEST_CHANGES` / `COMMENT`
- `body` — the review summary
- `comments` — array of `{path, line, side, body}`

Then run the post script, which submits the review in one call and
removes the worktree and temp artifacts:

```
~/.claude/skills/prr/scripts/post-review.sh <PR-url-or-number> /tmp/pr-<N>-review.json
```

If the user declined to post, run it with no payload argument to clean
up only:

```
~/.claude/skills/prr/scripts/post-review.sh <PR-url-or-number>
```

Confirm the worktree is removed and report the result.

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
