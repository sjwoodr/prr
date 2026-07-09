#!/usr/bin/env bash
# setup-review.sh — prr skill step 1: resolve a PR, create an isolated
# detached worktree, gather the review artifacts, and detect the mode:
# a full review, a self-review of your own PR (full pass, report-only), or
# a re-review of a PR you already reviewed.
#
# Usage:  setup-review.sh <PR-url-or-number> [owner/repo]
# A full PR URL works from any directory; a bare PR number must be run from
# inside the PR's git repo.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

arg="${1:?usage: setup-review.sh <PR-url-or-number> [owner/repo]}"
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

wt="/tmp/pr-${number}-wt"
view="/tmp/pr-${number}-view.json"
diff="/tmp/pr-${number}-diff.txt"
comments="/tmp/pr-${number}-comments.json"
reviews="/tmp/pr-${number}-reviews.json"
prior_json="/tmp/pr-${number}-prior-review.json"
since_diff="/tmp/pr-${number}-since-diff.txt"

# Stale re-review artifacts from an earlier run would mislead the skill.
rm -f "$prior_json" "$since_diff"

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
    [ .[] | select(.user.login == $me) ] as $mine
    | ( ( [ $mine[] | select((.body // "") | contains("<!-- prr -->")) ] | last )
        // ( $mine | last ) )
    // empty
  ' "$reviews")"
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
artifacts:
  view json:       $view
  diff:            $diff
  prior comments:  $comments
EOF

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
fi

# Optional: mark the team's PR chat post with :eyes: to show a review has
# started. No-op unless SLACK_BOT_TOKEN and PRR_CODE_REVIEWS_CHANNEL are set.
# Removed again by post-review.sh once the review is posted or cleaned up.
# Skipped for self-review: reviewing your own PR posts nothing back, so there
# is no "someone is reviewing this" signal worth showing the team.
# Best-effort: never let it abort setup.
if [[ "$mode" != "self-review" ]]; then
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
printf 'prr: reviewing #%s%s\n' "$number" "${title:+ - $title}" \
  > "/tmp/prr-status-${CLAUDE_CODE_SESSION_ID:-nosession}" 2>/dev/null || true
