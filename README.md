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

## Claude Code: skip the permission prompts (optional)

During a review Claude Code asks you to approve two helper-script runs
(`setup-review.sh`, `post-review.sh`) and the one file write of the review
payload to `/tmp/pr-<N>-review.json`. To pre-approve just those (scoped to the
prr scripts and that one payload path, nothing else), add them to your
**user** settings allow-list. Requires `jq`; the command is idempotent, safe
to re-run, and leaves any existing settings untouched:

```bash
mkdir -p ~/.claude
F=~/.claude/settings.json
[ -f "$F" ] || echo '{}' > "$F"
TMP=$(mktemp)
jq --arg h "$HOME" '
  ([
    "Bash(\($h)/.claude/skills/prr/scripts/setup-review.sh:*)",
    "Bash(\($h)/.claude/skills/prr/scripts/post-review.sh:*)",
    "Bash(\"$SKILL_DIR\"/scripts/setup-review.sh:*)",
    "Bash(\"$SKILL_DIR\"/scripts/post-review.sh:*)",
    "Write(/tmp/pr-*-review.json)"
  ]) as $new
  | .permissions.allow = ((.permissions.allow // []) + ($new - (.permissions.allow // [])))
' "$F" > "$TMP" && mv "$TMP" "$F"
jq '.permissions.allow' "$F"
```

Restart Claude Code if it does not pick the change up live. The scope is
limited to the prr scripts and the `pr-<N>-review.json` payload file under
`/tmp` (throwaway space). The `$SKILL_DIR` rules are path-independent, so they
work regardless of username; the absolute-path rules are belt-and-suspenders
for the default `~/.claude/skills/prr` install location.

Two notes:

- Invoke the helper scripts **bare** - do not pipe them through `tee` or
  redirect their output. A pipeline makes Claude Code match each segment of
  the command separately, so the un-allow-listed `tee` (or redirect) segment
  re-triggers a prompt even though the script itself is allowed. Both scripts
  already write their re-readable artifacts to `/tmp`, so there is nothing to
  capture. A path matcher with a leading double slash (e.g. `Write(//tmp/**)`)
  silently fails to match `/tmp/...` - use single-slash absolute paths.
- These rules only silence the **permission** prompts. The "post this review?"
  question at the end of every review is a deliberate safety gate, not a
  permission prompt - it cannot (and should not) be allow-listed away. prr
  never writes to GitHub until you say so.

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
| 4. Draft comments | One inline comment per finding; when a fix is obvious and small, the comment carries a `suggestion` block so you can accept it with GitHub's "Commit suggestion" button. A verdict is chosen (APPROVE / REQUEST_CHANGES / COMMENT). |
| 5. Approval gate | You see every comment verbatim and the verdict. Nothing is posted yet. |
| 6. Post & clean up | On your approval, the review is submitted and the worktree removed. Optionally reacts on the PR's chat-channel post (see [Optional: chat reaction](#optional-chat-reaction-on-the-pr-post)). |

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

## Self-review mode

When the PR author is you, `prr` auto-detects a **self-review**. It runs the
same full two-pass review as a normal run, but it is **report-only**: you get
the ranked findings and a proposed verdict in the chat and nothing is posted
back to the PR. (GitHub does not let you approve your own PR anyway, and the
point is a fresh zero-knowledge read of your own work.) Self-review takes
precedence over re-review.

## Optional: chat reaction on the PR post

If your team announces each PR in a chat channel (with the GitHub pull URL),
`prr` can react on that post to mirror the review outcome:

- APPROVE -> `:white_check_mark:`
- COMMENT or REQUEST_CHANGES -> `:speech_balloon:`
- nothing posted (gate declined, self-review, re-review report-only) -> no reaction

It is fully opt-in and a no-op unless both of these are set in the environment:

- `SLACK_BOT_TOKEN` — a Slack bot token with `reactions:write` and history
  access for the channel (`groups:history` for a private channel,
  `channels:history` for a public one); the bot must be a member of the channel
- `PRR_CODE_REVIEWS_CHANNEL` — the channel ID to search (e.g. `C0XXXXXXX`)

With neither set, behavior is unchanged. The step is best-effort: if the post is
not found or the chat API errors, it logs a note and never fails the review that
was already posted.

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
    ├── setup-review.sh   # worktree + artifacts + full/self/re-review detection
    ├── post-review.sh    # submit the review and clean up
    └── slack_react.py    # optional: react on the PR's chat post (opt-in via env)
```

## Good to know

- **Nothing posts without your approval.** The gate is hard, and you can edit
  or drop any comment before posting.
- Reviews post under **your** GitHub identity; `prr` is a personal reviewer's
  aid, not a bot account.

## Author and license

Author: Steve Woodruff (@sjwoodr)

Licensed under the MIT License — see [`LICENSE`](./LICENSE).
