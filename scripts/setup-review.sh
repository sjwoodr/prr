#!/usr/bin/env bash
# setup-review.sh — prr skill step 1: resolve a PR, create an isolated
# detached worktree, gather the review artifacts, and detect the mode:
# a full review, a self-review of your own PR (full pass, report-only), or
# a re-review of a PR you already reviewed.
#
# Usage:  setup-review.sh [--silent] [--noeyes] [--full] [--allow-conflicts] <PR-url-or-number> [owner/repo]
#         setup-review.sh --threads <PR-url-or-number> [owner/repo]
# A full PR URL works from any directory; a bare PR number must be run from
# inside the PR's git repo.
#
# --silent is stealth mode: suppress every Slack signal for this review, so
# nothing on the team's chat post says it is happening or how it ended.
#
# --noeyes skips only the :eyes: at start. The outcome reaction and thread
# reply still post if the review does. For a review started unattended, which
# may sit at the approval gate for hours, so :eyes: would claim someone is on it.
#
# A PR with merge conflicts is refused (exit 4) before anything is created:
# resolving them changes the code, so a review now would be spent again on the
# re-review after the fix. --allow-conflicts (or `conflicts`) reviews it anyway.
#
# --threads touches nothing but the comment artifact: it re-reads the PR's
# inline comments and reviews, rewrites /tmp/pr-<N>-comments.json, and lists
# what other people posted since this review started, so a comment that lands
# mid-review (another reviewer, a bot, an author reply) is seen before the gate.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

# Pull the stealth flag out of the arg list wherever it appears, so the
# positional parsing below is unaffected by it. The bare `silent` spelling is
# accepted alongside `--silent` because the skill's own front-door form reads
# `/prr silent <PR>`, mirroring `/prr test-mode <PR>`.
silent=0
noeyes=0
threads=0
force_full=0
allow_conflicts=0
_args=()
for _a in "$@"; do
  case "$_a" in
    --silent|silent) silent=1 ;;
    --noeyes|noeyes) noeyes=1 ;;
    --threads) threads=1 ;;
    # A full review even when you already reviewed this PR (a major rework).
    --full|full) force_full=1 ;;
    --allow-conflicts|conflicts) allow_conflicts=1 ;;
    *) _args+=("$_a") ;;
  esac
done
# Guarded rather than a bare "${_args[@]}": bash 3.2 (stock macOS) errors on an
# empty array expansion under `set -u`, and `setup-review.sh --silent` with no
# PR is exactly that. Falling through to the usage error below is the point.
if ((${#_args[@]})); then set -- "${_args[@]}"; else set --; fi

arg="${1:?usage: setup-review.sh [--silent] <PR-url-or-number> [owner/repo]}"
repo="${2:-}"

# Accept a full GitHub PR URL or a bare number.
if [[ "$arg" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  number="${BASH_REMATCH[3]}"
elif [[ "$arg" =~ ^[0-9]+$ ]]; then
  number="$arg"
else
  echo "error: '$arg' is neither a PR URL nor a number" >&2
  exit 2
fi

# Identify the current directory's repo, if we are inside one at all.
current_repo=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  current_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi

# A bare PR number carries no repo of its own, so it must be run from inside
# the PR's repo. A full PR URL carries owner/repo and works from anywhere.
if [[ -z "$repo" ]]; then
  if [[ -z "$current_repo" ]]; then
    echo "error: a bare PR number must be run from inside the PR's git repo;" \
         "pass a full PR URL to review a repo you do not have locally" >&2
    exit 2
  fi
  repo="$current_repo"
fi

if ((threads)); then
  comments="/tmp/pr-${number}-comments.json"
  started="$(cat "/tmp/pr-${number}-started" 2>/dev/null || echo 0)"
  [[ "$started" =~ ^[0-9]+$ ]] || started=0
  me="$(gh api user --jq .login)"
  gh api --paginate "repos/${repo}/pulls/${number}/comments" | jq -s 'add // []' > "$comments.tmp" \
    && mv "$comments.tmp" "$comments"
  reviews_now="$(gh api --paginate "repos/${repo}/pulls/${number}/reviews" | jq -s 'add // []')"
  # New since the stamp, and not yours. A review with an empty body is a
  # thread reply's wrapper; its comment is already in the inline list.
  new="$(jq -r --arg me "$me" --argjson t "$started" --argjson reviews "$reviews_now" '
    def recent(ts): (ts | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $t;
    ( [ .[] | select(.user.login != $me and recent(.created_at))
        | "inline  \(.user.login)  \(.path):\(.line // .original_line // "-")\(if .in_reply_to_id then "  (reply in thread \(.in_reply_to_id))" else "" end)\n        \(.body | gsub("\n"; " ") | .[0:300])" ]
    + [ $reviews[] | select(.user.login != $me and .submitted_at != null and recent(.submitted_at) and ((.body // "") != ""))
        | "review  \(.user.login)  \(.state)\n        \(.body | gsub("\n"; " ") | .[0:300])" ] )
    | .[]' "$comments")"
  # GNU date takes -d @epoch, BSD/macOS date takes -r epoch.
  since='the beginning'
  if ((started)); then
    since="$(date -d "@$started" '+%H:%M:%S' 2>/dev/null || date -r "$started" '+%H:%M:%S')"
  fi
  echo "prr threads: ${repo} #${number}, since ${since}"
  if [[ -n "$new" ]]; then
    printf '%s\n' "$new"
  else
    echo "  nothing new from anyone else"
  fi
  exit 0
fi

# Refuse a PR with merge conflicts before touching anything (no worktree, no
# :eyes:, nothing to clean up). GitHub computes mergeability lazily and says
# UNKNOWN until it has, so ask a few times; still UNKNOWN means review it.
if ((!allow_conflicts)); then
  mergeable=UNKNOWN
  for _ in 1 2 3 4 5; do
    mergeable="$(gh pr view "$number" --repo "$repo" --json mergeable --jq .mergeable 2>/dev/null || echo UNKNOWN)"
    [[ "$mergeable" == UNKNOWN ]] || break
    sleep 2
  done
  if [[ "$mergeable" == CONFLICTING ]]; then
    echo "prr: #${number} has merge conflicts with its base branch; not reviewing it until they are resolved."
    echo "     Resolving them changes the code, so this review would be redone. To review it anyway: conflicts"
    # In a review-watch pane, the result file is what closes the pane.
    if [[ -n "${PRR_FANOUT_PANE:-}" ]]; then
      printf 'pr=%s status=conflicts event=none comments=0\n' "$number" > "/tmp/prr-fanout-${number}.result"
    fi
    exit 4
  fi
fi

wt="/tmp/pr-${number}-wt"
view="/tmp/pr-${number}-view.json"
diff="/tmp/pr-${number}-diff.txt"
comments="/tmp/pr-${number}-comments.json"
reviews="/tmp/pr-${number}-reviews.json"
prior_json="/tmp/pr-${number}-prior-review.json"
since_diff="/tmp/pr-${number}-since-diff.txt"
silent_marker="/tmp/pr-${number}-silent"

# Stale artifacts from an earlier run would mislead the skill. The silent marker
# is cleared here rather than left to the write below, so a stealth review of a
# PR cannot make an ordinary review of that same PR quietly stealthy later.
rm -f "$prior_json" "$since_diff" "$silent_marker"

# Start of the review, for the timings post-review.sh writes into its hidden
# meta marker. Kept across a re-run on a moved head (same review), but a stamp
# over a day old is a crashed run's leftover, not this review.
started="/tmp/pr-${number}-started"
if [[ -z "$(find "$started" -mmin -1440 2>/dev/null)" ]]; then
  date +%s > "$started"
fi

# Idempotent: drop whatever a previous run left at $wt. If it was a worktree
# of the repo we are currently in, deregister it first; then clear the path.
# (A worktree registered in a different repo can only be pruned from inside
# that repo — the directory removal still applies, and that repo prunes its
# own stale entry on its next prr run.)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && git worktree list --porcelain | grep -qF "$wt"; then
  git worktree remove "$wt" --force
  git worktree prune
fi
rm -rf "$wt"

# Materialize the PR head at $wt as a detached checkout. Two paths:
#   local-worktree — the current directory IS the PR's repo: a detached
#     git worktree of it, no extra clone, no extra download.
#   standalone — the PR lives in a repo not checked out here (or we are not
#     in a git repo at all): a throwaway repo whose origin is the PR's
#     GitHub repo. The review reads the same files either way.
if [[ -n "$current_repo" && "$current_repo" == "$repo" ]]; then
  pr_source="local worktree"
  git worktree add --detach "$wt" >/dev/null
  fetch=(git -C "$wt" fetch -q origin)
  depth=()  # worktree of the full local clone — history is already here
else
  pr_source="standalone (no local clone of $repo)"
  git init -q "$wt"
  git -C "$wt" remote add origin "https://github.com/${repo}.git"
  # Authenticate HTTPS fetches via gh's token so private repos work even
  # without a prior `gh auth setup-git`.
  fetch=(git -C "$wt" -c "credential.helper=!gh auth git-credential" fetch -q origin)
  # Shallow: a review needs the PR's file tree, not the repo's whole
  # history. --depth 1 keeps even a large monorepo checkout small.
  depth=(--depth 1)
fi

# Detached PR head. pull/N/head works for fork PRs too; in standalone mode
# origin is the PR's GitHub repo, so the same fetch works without a clone.
"${fetch[@]}" ${depth[@]+"${depth[@]}"} "pull/${number}/head"
git -C "$wt" checkout -q FETCH_HEAD
head_sha="$(git -C "$wt" rev-parse HEAD)"

# Artifacts the review pass reads.
gh pr view "$number" --repo "$repo" \
  --json number,title,state,headRefName,author,files,reviews,comments,body \
  > "$view"
gh pr diff "$number" --repo "$repo" > "$diff"
gh api --paginate "repos/${repo}/pulls/${number}/comments" > "$comments"
gh api --paginate "repos/${repo}/pulls/${number}/reviews"  > "$reviews"

# --- Mode detection ------------------------------------------------------
# Three modes, in precedence order:
#   self-review — the PR author IS the current gh user (your own PR). Runs
#     the full dual-source pass but is report-only; GitHub does not allow
#     approving your own PR, and the intent is a fresh zero-knowledge look.
#   re-review   — you already reviewed this PR. Pick the latest of your
#     reviews, preferring one tagged with the prr marker; fall back to your
#     latest review overall (prr reviews predating the marker have no tag).
#   full-review — the default: a first, fresh review.
me="$(gh api user --jq .login)"
pr_author="$(jq -r '.author.login // ""' "$view")"

mode="full-review"
commits_since="0"
prior=""

# Self-review wins over re-review; only look for a prior review otherwise.
if [[ -n "$pr_author" && "$pr_author" == "$me" ]]; then
  mode="self-review"
else
  prior="$(jq -c --arg me "$me" '
    # A thread reply is a COMMENTED review with an empty body, not a review.
    [ .[] | select(.user.login == $me)
          | select(.state != "COMMENTED" or (.body // "") != "") ] as $mine
    | ( ( [ $mine[] | select((.body // "") | contains("<!-- prr -->")) ] | last )
        // ( $mine | last ) )
    // empty
  ' "$reviews")"
fi

forced_full=""
if [[ -n "$prior" ]] && ((force_full)); then
  forced_full="$(jq -r '"\(.state) at \(.commit_id // "?" | .[0:9])"' <<<"$prior")"
  prior=""
fi

if [[ -n "$prior" ]]; then
  mode="re-review"
  review_id="$(jq -r .id <<<"$prior")"
  prior_sha="$(jq -r '.commit_id // ""' <<<"$prior")"

  # The inline comments belonging to that review are the prior findings.
  findings="$(jq --argjson rid "$review_id" '
    [ .[] | select(.pull_request_review_id == $rid)
      | { path, line: (.line // .original_line), body } ]
  ' "$comments")"
  jq -n --argjson review "$prior" --argjson findings "$findings" '
    { review: { id: $review.id, state: $review.state,
                submitted_at: $review.submitted_at,
                commit_id: $review.commit_id, body: $review.body },
      findings: $findings }
  ' > "$prior_json"

  # Incremental diff: what changed since the prior review, scoped to the
  # files this PR touches — a `main` merge into the branch between reviews
  # would otherwise flood the diff with unrelated changes.
  if [[ -n "$prior_sha" ]]; then
    "${fetch[@]}" ${depth[@]+"${depth[@]}"} "$prior_sha" 2>/dev/null || true
    if git -C "$wt" cat-file -e "${prior_sha}^{commit}" 2>/dev/null; then
      IFS=$'\n' read -r -d '' -a pr_files < <(jq -r '.files[].path' "$view" && printf '\0')
      if [[ ${#pr_files[@]} -gt 0 ]]; then
        git -C "$wt" diff "${prior_sha}..HEAD" -- "${pr_files[@]}" > "$since_diff"
      else
        git -C "$wt" diff "${prior_sha}..HEAD" > "$since_diff"
      fi
      # Two-dot diff above compares the two commits' trees directly, so it
      # is exact even on a shallow checkout. The commit count needs the
      # ancestry between them, which a shallow checkout lacks — flag it.
      commits_since="$(git -C "$wt" rev-list --count "${prior_sha}..HEAD" 2>/dev/null || echo unknown)"
      [[ -f "$wt/.git/shallow" && "$commits_since" != "0" ]] \
        && commits_since="$commits_since (approx; shallow checkout)"
    else
      echo "prior review commit ${prior_sha} is not fetchable (likely a" \
           "rebase or force-push) — compare against the full PR diff instead" \
           > "$since_diff"
      commits_since="unknown (rebase/force-push)"
    fi
  fi
fi

printf '%s\n' "$mode" > "/tmp/pr-${number}-mode"

# --- Summary -------------------------------------------------------------
cat <<EOF
prr setup complete
  repo:            $repo
  pr:              #$number  $(jq -r .title "$view")
  head sha:        $head_sha
  worktree:        $wt
  pr source:       $pr_source
  files changed:   $(jq '.files | length' "$view")
  prior comments:  $(jq 'length' "$comments")
  MODE:            $mode
EOF
if [[ -n "$forced_full" ]]; then
  echo "  forced full:     yes, your earlier review ($forced_full) is ignored"
fi
cat <<EOF
artifacts:
  view json:       $view
  diff:            $diff
  prior comments:  $comments
EOF

# What the review has to account for, printed so no model has to dig it out of
# the JSON: the linked ticket (step 1 reads its acceptance criteria) and who
# already commented where (step 3 concurs instead of repeating them).
tickets="$(jq -r '(.title // "") + "\n" + (.body // "")' "$view" \
  | grep -oE 'atlassian\.net/browse/[A-Z][A-Z0-9]+-[0-9]+|github\.com/[^/ ]+/[^/ ]+/issues/[0-9]+|^\[[A-Z][A-Z0-9]+-[0-9]+\]' \
  | sed -E 's#.*/browse/##; s#^\[##; s#\]$##' | sort -u | paste -sd' ' - || true)"
echo "linked ticket:     ${tickets:-none in the title or body}"
jq -r --slurpfile view "$view" '
  ( [ .[] | "  inline  \(.user.login)  \(.path):\(.line // .original_line // "-")  \(.body | gsub("\n"; " ") | .[0:120])" ]
  + [ $view[0].reviews[]? | select((.body // "") != "")
      | "  review  \(.author.login)  \(.state)  \(.body | gsub("\n"; " ") | .[0:120])" ] )
  | if length == 0 then "prior comments:    none" else "prior comments (concur, do not repeat):", .[] end
' "$comments" 2>/dev/null || true

if ((silent)); then
  cat <<EOF
silent mode:
  slack:           OFF for this review — no :eyes:, no outcome reaction, no
                   thread reply. post-review.sh inherits this automatically.
EOF
fi

if [[ "$mode" == "re-review" ]]; then
  cat <<EOF
re-review context:
  prior review:    $me / $(jq -r .review.state "$prior_json") / $(jq -r '.review.submitted_at' "$prior_json")
  prior findings:  $(jq '.findings | length' "$prior_json")
  commits since:   $commits_since
  prior review:    $prior_json
  since-diff:      $since_diff
EOF
fi

if [[ "$mode" == "self-review" ]]; then
  cat <<EOF
self-review context:
  pr author:       $pr_author (you)
  posting:         disabled — report findings to the user only, post nothing
EOF
  # PRR_SELF_REVIEW_C=<model> runs Source C on every self-review, where the
  # author's own assumptions and PR description are what it attacks. Unset, it
  # stays opt-in: a third pass costs about as much as Source B.
  self_c="${PRR_SELF_REVIEW_C:-}"
  case "$self_c" in
    ""|off|none|false|0) echo "  source C:        opt-in (set PRR_SELF_REVIEW_C=<model> to run it on every self-review)" ;;
    *)                   echo "  source C:        on by default, model $self_c (noC to skip)" ;;
  esac
fi

# Two different reasons to send the team no Slack signal, and they turn out to
# be one rule. --silent is stealth: review the PR without the team seeing it
# happen. self-review posts nothing back to the PR at all, so there is no
# "someone is reviewing this" worth announcing either. They differ only in what
# reaches GITHUB (silent still posts the review; self-review never does), which
# is not this file's concern. So collapse them into one predicate rather than
# testing two conditions in two scripts and risking one drifting from the other.
#
# Recorded as a marker file because post-review.sh runs as a separate
# invocation, often a full review later. A flag it had to be re-passed would
# rest on the skill remembering it, and the failure modes are not symmetric:
# forgetting at setup leaves a stray :eyes:, while forgetting at post announces
# the verdict and a thread summary, which is the thing stealth exists to
# prevent. Marker means the property belongs to the review, not to one call.
slack_quiet=0
if ((silent)) || [[ "$mode" == "self-review" ]]; then
  slack_quiet=1
  : > "$silent_marker"
fi

# Optional: mark the team's PR chat post with :eyes: to show a review has
# started. No-op unless SLACK_BOT_TOKEN and PRR_CODE_REVIEWS_CHANNEL are set.
# Removed again by post-review.sh once the review is posted or cleaned up.
# Best-effort: never let it abort setup.
if ((noeyes && !slack_quiet)); then
  echo "slack: noeyes - no :eyes: on the chat post; the outcome reaction and reply still post"
elif ((!slack_quiet)); then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$script_dir/slack_react.py" \
    --repo "$repo" --number "$number" --react eyes || true
fi

# Optional: show "reviewing PR #N" on the Claude Code status line for this
# session. scripts/prr-statusline.sh renders this file if the user configured it
# as a `statusLine` command (see README). Session-scoped (keyed on the same
# session id the status line reads from stdin) so parallel fan-out panes each
# show their own PR. Cleared by post-review.sh. Best-effort and harmless when no
# statusLine is configured — nothing reads the file.
title="$(jq -r '.title // empty' "$view" 2>/dev/null || true)"
# Verb tracks the mode. These are three different amounts of work with three
# different endings - a re-review only checks prior findings, and a self-review
# posts nothing back to the PR at all - and once the setup output has scrolled
# away the bar is the only place that distinction is still visible.
case "$mode" in
  re-review)   verb="re-reviewing" ;;
  self-review) verb="self-reviewing" ;;
  *)           verb="reviewing" ;;
esac
printf 'prr: %s #%s%s\n' "$verb" "$number" "${title:+ - $title}" \
  > "/tmp/prr-status-${CLAUDE_CODE_SESSION_ID:-nosession}" 2>/dev/null || true
