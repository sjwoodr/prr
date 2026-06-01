# prr — automated PR reviews (Claude Code & Cursor skill)

`prr` is a [Claude Code](https://claude.com/claude-code) skill that runs a
structured, two-pass review of a GitHub pull request and posts inline review
comments — but only after you have seen and approved every one. It is a
personal tool: reviews post under your own GitHub account.

## What it is

A Claude Code *skill* is a packaged workflow you invoke with a slash command.
`prr` turns "review this PR" into a repeatable process:

- Checks the PR out under `/tmp`, isolated from your work — a detached
  **git worktree** when you run it inside the PR's repo, or a **standalone
  checkout** fetched straight from GitHub when you do not have that repo
  cloned locally. Your working tree and current branch are never touched.
- Runs **two independent review passes**: a primary correctness and
  conventions review, and a security-focused pass by a separate agent
  (cross-tenant isolation, auth, secrets, error handling, blast radius,
  test gaps).
- **Synthesizes** both passes, drops false positives and anything an
  existing reviewer (e.g. Copilot) already raised, and ranks each finding
  **blocker / notable / nit**.
- Drafts one **inline GitHub comment per finding**, anchored to a file and
  line.
- **Stops at an approval gate** — shows you every drafted comment and the
  proposed verdict, and posts nothing until you say yes.
- Submits the review through the GitHub CLI and removes the temporary checkout.

## Installing

Install into your Claude Code skills directory so the skill lives at
`~/.claude/skills/prr/`. Either method works.

**Option A — clone the repo:**

```bash
git clone https://github.com/sjwoodr/prr ~/.claude/skills/prr
```

**Option B — download and extract the zip:**

```bash
unzip prr.zip -d ~/.claude/skills/
```

That is all — `/prr` is now available in Claude Code.

### Cursor

`prr` uses the portable `SKILL.md` Agent Skills format, so it also works in
**Cursor** (2.4+). Cursor discovers skills in `~/.cursor/skills/`,
`~/.agents/skills/`, and a project `.cursor/skills/` — and, for compatibility,
in `~/.claude/skills/`, so an existing `~/.claude/skills/prr` install is picked
up as-is with no changes. To install it specifically for Cursor instead:

```bash
git clone https://github.com/sjwoodr/prr ~/.cursor/skills/prr
```

Invoke it the same way: type `/` in Cursor's Agent chat and pick `prr`, or let
it trigger automatically from the `description`. The bundled scripts are
resolved via `$SKILL_DIR` (the skill's own directory), so they run correctly
from whichever location Cursor loaded the skill.

**Caveat — the security pass.** `prr` was designed around Claude Code running
the security review as a **separate background agent** (the "dual-source" pass
in step 2). How Cursor handles that second agent is **not yet verified** — it
may run the security review inline within the single agent rather than as a
true parallel sub-agent. The review still covers both the primary and security
lenses; only the parallelism/isolation may differ. (The "this is not the
bundled `/review` skill" line in `SKILL.md` refers to a Claude Code built-in
and is harmless to ignore in Cursor.)

## Using it

With a full PR URL, from any directory:

```
/prr https://github.com/owner/repo/pull/583
```

Or, from inside the PR's own repository, just `/prr 583`.

## The workflow

| Step | What happens |
|------|--------------|
| 1. Setup | Resolves the PR, checks it out under `/tmp/pr-<N>-wt` (local worktree, or standalone checkout if the repo is not cloned), gathers the diff, description, and prior review threads. |
| 2. Dual-source review | Your primary review runs alongside a background security agent. |
| 3. Synthesize | Findings merged, de-duplicated, ranked blocker / notable / nit. |
| 4. Draft comments | One inline comment per finding; a verdict is chosen (APPROVE / REQUEST_CHANGES / COMMENT). |
| 5. Approval gate | You see every comment verbatim and the verdict. Nothing is posted yet. |
| 6. Post & clean up | On your approval, the review is submitted and the worktree removed. |

## Re-review mode

When a PR author pushes fixes, run `/prr` on the same PR again. It detects
your earlier prr review and switches to an **incremental re-review**:

- It does **not** repeat the full two-pass review.
- It looks only at the commits pushed since your review and marks each prior
  finding **Fixed / Partially fixed / Not addressed / Unclear**.
- It proposes an updated verdict (e.g. APPROVE once every blocker is
  resolved).

To force a full fresh review of an already-reviewed PR, say so when you
invoke it.

## Requirements

- **Claude Code**, or **Cursor** (2.4+) — `prr` uses the portable `SKILL.md`
  format both support (see [Cursor](#cursor) above for the sub-agent caveat)
- **GitHub CLI (`gh`)**, authenticated against an account with access to the
  repo
- **ripgrep (`rg`)** — recommended for code search; the skill falls back to
  `grep` if it is not installed
- A full PR URL works from **any directory** — the skill fetches the PR from
  GitHub when you do not have the repo cloned. A bare PR number must be run
  from inside the PR's own git repository.

## Bundle contents

```
prr/
├── SKILL.md              # the workflow definition Claude follows
├── README.md             # this file
├── LICENSE               # MIT license
└── scripts/
    ├── setup-review.sh   # worktree + artifacts + review/re-review detection
    └── post-review.sh    # submit the review and clean up
```

## Good to know

- **Nothing posts without your approval.** The gate is hard, and you can edit
  or drop any comment before posting.
- Reviews post under **your** GitHub identity; `prr` is a personal reviewer's
  aid, not a bot account.

## Author and license

Author: Steve Woodruff (@sjwoodr)

Licensed under the MIT License — see [`LICENSE`](./LICENSE).
