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

During a review Claude Code asks you to approve the helper-script runs
(`setup-review.sh`, `post-review.sh`, and `prr-fanout.sh` for the multi-PR
fan-out) and the one file write of the review payload to
`/tmp/pr-<N>-review.json`. To pre-approve just those (scoped to the prr
scripts and that one payload path, nothing else), add them to your
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
    "Bash(\($h)/.claude/skills/prr/scripts/prr-fanout.sh:*)",
    "Bash(~/.claude/skills/prr/scripts/setup-review.sh:*)",
    "Bash(~/.claude/skills/prr/scripts/post-review.sh:*)",
    "Bash(~/.claude/skills/prr/scripts/prr-fanout.sh:*)",
    "Bash(\"$SKILL_DIR\"/scripts/setup-review.sh:*)",
    "Bash(\"$SKILL_DIR\"/scripts/post-review.sh:*)",
    "Bash(\"$SKILL_DIR\"/scripts/prr-fanout.sh:*)",
    "Write(/tmp/pr-*-review.json)"
  ]) as $new
  | .permissions.allow = ((.permissions.allow // []) + ($new - (.permissions.allow // [])))
' "$F" > "$TMP" && mv "$TMP" "$F"
jq '.permissions.allow' "$F"
```

Restart Claude Code if it does not pick the change up live. The scope is
limited to the prr scripts and the `pr-<N>-review.json` payload file under
`/tmp` (throwaway space). Three rule forms are installed because Claude Code's
permission matcher compares the command string literally — it does not expand
`~`, `$HOME`, or `$SKILL_DIR` before matching, so a rule only fires when its
form matches how the command is written. SKILL.md invokes the scripts via the
`~/.claude/skills/prr/...` form, so the tilde rules are the ones that normally
match; the fully-expanded absolute-path rules and the path-independent
`$SKILL_DIR` rules are belt-and-suspenders for the default install location and
for any custom invocation that uses those forms instead.

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

## Parallel multi-PR review (`PRR_FANOUT`)

Reviewing a batch (say a colleague's eight open PRs)? Pass several at once and
`prr` can fan them out into a grid of interactive sessions:

```
/prr 101 102 103 104
```

A multi-PR run opens **one window** with one pane per PR, each pane running
`/prr` on a single PR. You review and **approve each post in its own pane** — the
approval gate is never bypassed. As each review finishes, its pane closes; when
the last one closes you get a consolidated rollup back in the original session.

**tmux is the recommended backend, and the one `prr` uses by default.** It is the
most stable and proven path: portable across terminals, with a free auto-tiling
grid. You do **not** need to opt in — when `PRR_FANOUT` is unset, a multi-PR run
fans out with tmux automatically, as long as `tmux` is on your `PATH` and a
graphical session is available. Set `PRR_FANOUT=off` to force sequential review
instead.

- **`PRR_FANOUT=tmux`** (the default) — one terminal running **tmux** with a
  tiled pane per PR. `PRR_FANOUT=true` and the legacy `PRR_TMUX_FANOUT=true` are
  aliases for it.

The other backends are **reference implementations** — drop the tmux layer and
drive a terminal's own splitting directly. They are kept mainly as a worked
example for anyone who wants to extend the fan-out to a terminal that is not in
the tmux backend's detection list. They are **not** the recommended path; reach
for one only if tmux genuinely does not fit your setup:

- **`PRR_FANOUT=wezterm`** — **wezterm-native** panes, no tmux (Linux only). See
  [the wezterm-native backend](#wezterm-native-backend-prr_fanoutwezterm) below.
- **`PRR_FANOUT=terminator`** — **Terminator-native** panes via a generated
  layout, no tmux (Linux/X11). Native GTK with focus-follows-mouse and
  mouse-resizable panes; finished panes self-close after a short grace period.

The skill routes through `scripts/prr-fanout.sh`, which resolves `PRR_FANOUT` and
hands off to the matching `scripts/prr-fanout-<backend>.sh`.

The wait between approvals is a plain shell sleep loop, so an idle batch (you
walked away) costs **no tokens** — only the active reviews do.

**This assumes a graphical desktop session** (Linux X11/Xwayland or Wayland, or
macOS), because the panes have to be visible for you to approve them. Over SSH
or headless, or when the selected backend's tools are missing, the fan-out
refuses and the PRs are reviewed **one at a time** instead (the normal single-PR
flow per PR). A single-PR run ignores `PRR_FANOUT` entirely.

Tune (or opt out) via environment:

- `PRR_FANOUT` — controls fan-out for multi-PR runs:
  - **unset** (default) — auto: fan out with **tmux** when `tmux` is on `PATH`
    and a graphical session is present, otherwise review sequentially. No opt-in
    needed to get the tmux fan-out.
  - **`off`** (also `none` / `false` / `0`) — force **sequential** review; never
    fan out, even with tmux installed.
  - **`tmux`** — force the tmux backend (`true` and the legacy
    `PRR_TMUX_FANOUT=true` are aliases).
  - **`wezterm`** / **`terminator`** — use a reference backend instead (see the
    backend list above). Single-PR runs ignore `PRR_FANOUT` entirely.
- `PRR_FANOUT_TIMEOUT_MINS` — global wall-clock cap on the run; default `240`
  (4h). `0` disables the cap (safe, since waiting is token-free). On timeout the
  launcher stops, reports which PRs are still open, and **leaves your in-progress
  panes alone** (it prints the `tmux attach` command to finish them by hand).
- `PRR_FANOUT_TERMINAL` — force the terminal, skipping detection. On **Linux**
  the auto-detection order is `tilix`, `terminator`, `wezterm`,
  `gnome-terminal`, `x-terminal-emulator` (the desktop default via
  `update-alternatives`), then `xterm`. On **macOS** the
  default is the built-in **Terminal.app**; set this to another terminal app name
  (e.g. `iTerm`, `Alacritty`) to override. The macOS override is best-effort: the
  app is opened on the attach command and a Terminal-style resize is attempted,
  but if the app ignores it the window just opens at its default size.
- `PRR_FANOUT_GEOMETRY` — size of the spawned window as `COLSxROWS`; default
  `160x50`. On Linux it is applied via the terminal's geometry flag
  (`tilix`/`terminator`/`gnome-terminal` `--geometry=`, `xterm` `-geometry`); on macOS the
  spawned window self-resizes with a terminal escape that Terminal.app honors.
  Terminals that ignore the escape (or other Linux terminals) open at their
  default size — the panes still tile evenly and re-tile if you resize the
  window. `wezterm` has no geometry flag, so the size is applied through its
  `--config initial_cols`/`initial_rows` overrides instead. Bump it for big
  batches so the tiled panes stay readable (e.g. `220x60` for a 3x3 grid of
  eight).

Notes: `gnome-terminal` runs its command in a background server, so depending on
your profile's "When command exits" setting the window may linger after the
panes close; `wezterm`, `tilix`, and `xterm` close cleanly. On **macOS** Terminal.app leaves
the spawned window on "[Process completed]" when the panes finish (the panes
always close inside tmux regardless). To have it close automatically, set
Terminal's shell-exit action once, then relaunch Terminal:

```bash
defaults write com.apple.Terminal ShellExitAction -int 1   # 1 = close if clean; 2 = always close
```

If that key does not take on your macOS version, set it in the GUI instead:
Terminal → Settings → Profiles → Shell → "When the shell exits" → "Close the
window". Bare PR numbers must be run from inside the PR's repo (as usual); full
PR URLs work from anywhere.

### wezterm-native backend (`PRR_FANOUT=wezterm`)

On a **wezterm** daily driver you can drop the tmux layer entirely. Set
`PRR_FANOUT=wezterm` and a multi-PR run hands off to `prr-fanout-wezterm.sh`,
which drives wezterm directly via `wezterm cli` instead of running tmux inside a
window. Everything else is identical: one window, one pane per PR, the approval
gate intact, panes closing as each review finishes, then the same rollup.

It opens its **own** isolated gui instance (`wezterm start --class prr-fanout-<pid>
--always-new-process`) and addresses it only through that instance's private gui
socket, so your existing wezterm windows are never touched. Panes are tiled into a
near-square grid (`cols = ceil(sqrt(N))`); a finished pane's space is absorbed by
its sibling with **no rebalance-on-close** (these runs last minutes, so survivors
just getting bigger is fine, and not re-tiling avoids yanking panes around mid-read).

This backend is **Linux-only** — not because wezterm is (it runs fine on macOS),
but because the backend's launch + isolation mechanics are: it detaches the gui
with `setsid` (absent on macOS) and locates the new instance's socket under the
XDG runtime dir. On macOS, use `PRR_FANOUT=tmux`, which drives wezterm just fine.
`PRR_FANOUT_TIMEOUT_MINS` and `PRR_FANOUT_GEOMETRY` apply the same way; the
geometry sizes the window via wezterm's `initial_cols`/`initial_rows`. Smoke-test
it with `PRR_FANOUT=wezterm /prr test-mode 1 2 3 4 5`.

**Smoke-testing the fan-out.** `/prr test-mode <N> <N> ...` (e.g. `/prr test-mode
1 2 3 4 5 6`) runs the whole launcher **without invoking Claude**: it opens the
tiled window and each pane mocks a review by writing its result file (staggered,
so panes close one by one), letting you verify the spawn, layout, sizing,
pane-close, and rollup quickly. It bypasses the enable gate (no `PRR_FANOUT`
needed) and defaults to the `tmux` backend; prefix `PRR_FANOUT=wezterm` to
smoke-test the wezterm-native backend instead.

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

- `SLACK_BOT_TOKEN` — a Slack **user** OAuth token (`xoxp-...`). The env var
  keeps this name, but the token is a user token so the reaction and threaded
  reply appear as **you**, not a bot. It needs the user scopes `reactions:write`,
  `chat:write`, and history access for the channel (`channels:history` for a
  public channel, `groups:history` for a private one); the account that owns the
  token must be a member of the channel. See
  [Creating the Slack app](#creating-the-slack-app) below for the step-by-step.
- `PRR_CODE_REVIEWS_CHANNEL` — the channel ID to search (e.g. `C0XXXXXXX`)

With neither set, behavior is unchanged. The step is best-effort: if the post is
not found or the chat API errors, it logs a note and never fails the review that
was already posted.

### Creating the Slack app

The chat-reaction step talks to Slack with your own token, so the reaction and
the threaded reply show up as **you**. Create a personal Slack app once and
reuse its token:

1. Go to **https://api.slack.com/apps** and click **Create New App -> From
   scratch**. Give it a name (e.g. `prr`) and pick your workspace.
2. Open **OAuth & Permissions** in the left sidebar.
3. Under **User Token Scopes** (the *user* list, not *Bot* Token Scopes), add:
   - `reactions:write` — add and remove the `:eyes:` / `:white_check_mark:` /
     `:speech_balloon:` reactions
   - `chat:write` — post the threaded reply
   - `channels:history` — find the PR post in a public channel
   - `groups:history` — same, for a private channel (skip if your channel is
     public)
4. Scroll up and click **Install to Workspace**, then authorize.
   - **Workspace admin approval:** most workspaces restrict who can install
     apps, so this will likely create a *pending request* rather than install
     right away. Ask a Slack workspace admin/owner to approve it (they do this
     under Slack settings -> Manage apps, or via the approval link Slack emails
     them). The token is not issued until the app is approved and installed.
5. Back on **OAuth & Permissions**, copy the **User OAuth Token** (it starts with
   `xoxp-`).
6. Make sure you are a **member of the channel** you announce PRs in (the token
   can only read history and react where you are present). Copy its channel ID:
   open the channel, click its name, and the ID (`C0XXXXXXX`) is at the bottom of
   the details pane.
7. Export both variables (add them to your shell profile to persist):

   ```bash
   export SLACK_BOT_TOKEN=xoxp-your-user-token
   export PRR_CODE_REVIEWS_CHANNEL=C0XXXXXXX
   ```

That is it — the next `/prr` run signals progress on the matching PR post.

## Optional: PR status line (Claude Code)

Show the PR you are currently reviewing on the Claude Code status line, and fall
back to the working directory + git branch when no review is running. Like the
chat reaction, this is fully opt-in and off unless you add one line to your
`settings.json`.

`scripts/prr-statusline.sh` reads the session id Claude Code pipes to a
`statusLine` command and, while a review is in progress, prints the
`prr: reviewing #<PR>` line `setup-review.sh` leaves in `/tmp` (cleared by
`post-review.sh`, on both the posted and declined paths). It is keyed per
session, so parallel fan-out panes each show their own PR. When idle it prints
`~/path (branch) <ctx>` instead — the directory, git branch, and current context
size (e.g. `886k`), never the model. Both forms are capped at 70 characters by
default (override with the `PRR_STATUSLINE_WIDTH` env var, set the same way as
`PRR_FANOUT`), trimmed with a trailing `...`; the context count is kept out of
that trim so it stays visible.

Enable it by pointing a `statusLine` command at the bundled script in
`~/.claude/settings.json`:

```jsonc
{
  "statusLine": {
    "type": "command",
    "command": "<SKILL_DIR>/scripts/prr-statusline.sh"
  }
}
```

Or add it non-destructively with `jq` (merges into any existing settings, keeps
your other keys):

```bash
SKILL_DIR="$HOME/.claude/skills/prr"   # adjust for Cursor / project-local installs
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmp="$(mktemp)"
jq --arg cmd "$SKILL_DIR/scripts/prr-statusline.sh" \
   '.statusLine = {type: "command", command: $cmd}' \
   "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
```

If you already have a `statusLine`, that snippet replaces it — merge by hand to
keep custom rendering. Nothing else depends on the config: `setup-review.sh` and
`post-review.sh` always write and clear the tiny session-scoped state file, so if
you never add the `statusLine` block nothing reads it and there is no effect.

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
- A **graphical desktop session** (Linux X11/Xwayland or Wayland, or macOS) plus
  the selected backend's multiplexer — **tmux** for `PRR_FANOUT=tmux`, **wezterm**
  for `PRR_FANOUT=wezterm` — optional, only for the parallel multi-PR fan-out.
  Without them, multi-PR runs review sequentially instead.

### Installing a fan-out backend

Only needed if you want the parallel fan-out (`PRR_FANOUT`); single-PR review
needs neither.

**tmux** (default backend) is in the standard repos:

```bash
brew install tmux                  # macOS
sudo apt install tmux              # Ubuntu/Debian
```

**wezterm** is *not* in Ubuntu's default repos — on macOS it is a Homebrew cask,
on Ubuntu/Debian you add WezTerm's apt repository first:

```bash
# macOS
brew install --cask wezterm

# Ubuntu/Debian (official apt repo)
curl -fsSL https://apt.fury.io/wez/gpg.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | sudo tee /etc/apt/sources.list.d/wezterm.list
sudo chmod 644 /usr/share/keyrings/wezterm-fury.gpg
sudo apt update
sudo apt install wezterm
```

If you would rather not add the repo, WezTerm also ships as a Flatpak
(`flatpak install flathub org.wezfurlong.wezterm`) or an AppImage / `.deb` from
its [GitHub releases](https://github.com/wezterm/wezterm/releases). (The
wezterm backend is Linux-only; on macOS use `PRR_FANOUT=tmux`, which drives
wezterm too.)

## Bundle contents

```
prr/
├── SKILL.md              # the workflow definition Claude follows
├── README.md             # this file
├── LICENSE               # MIT license
└── scripts/
    ├── setup-review.sh   # worktree + artifacts + full/self/re-review detection
    ├── post-review.sh    # submit the review and clean up
    ├── prr-statusline.sh # optional: Claude Code status line (opt-in via settings.json)
    ├── prr-fanout.sh     # optional: multi-PR fan-out router (PRR_FANOUT=tmux|wezterm)
    ├── prr-fanout-tmux.sh    # backend: tiled tmux panes (portable; default)
    ├── prr-fanout-wezterm.sh # backend: wezterm-native panes, no tmux (Linux only)
    ├── prr-fanout-common.sh  # shared helpers sourced by both fan-out backends
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
