#!/usr/bin/env bash
# setup-review.sh — prr skill step 1: resolve a PR, create an isolated
# detached worktree, gather the review artifacts, and detect the mode:
# a first review (full) or a re-review of a PR you already reviewed.
#
# Usage:  setup-review.sh <PR-url-or-number> [owner/repo]
# Run from inside the target git repo (git worktree needs it).
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

# No owner/repo given: fall back to the current directory's repo.
[[ -z "$repo" ]] && repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

wt="/tmp/pr-${number}-wt"
view="/tmp/pr-${number}-view.json"
diff="/tmp/pr-${number}-diff.txt"
comments="/tmp/pr-${number}-comments.json"
reviews="/tmp/pr-${number}-reviews.json"
prior_json="/tmp/pr-${number}-prior-review.json"
since_diff="/tmp/pr-${number}-since-diff.txt"

# Stale re-review artifacts from an earlier run would mislead the skill.
rm -f "$prior_json" "$since_diff"

# Idempotent: a re-run on the same PR replaces the old worktree.
if git worktree list --porcelain | grep -qF "$wt"; then
  git worktree remove "$wt" --force
fi
git worktree prune

# Detached worktree at the PR head. pull/N/head works for fork PRs too,
# and detached means no local branch to clean up later.
git worktree add --detach "$wt" >/dev/null
git -C "$wt" fetch -q origin "pull/${number}/head"
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
# Re-review mode triggers when the current gh user already reviewed this PR.
# Pick the latest of their reviews, preferring one tagged with the prr
# marker; fall back to their latest review overall (prr reviews posted
# before the marker existed have no tag).
me="$(gh api user --jq .login)"
prior="$(jq -c --arg me "$me" '
  [ .[] | select(.user.login == $me) ] as $mine
  | ( ( [ $mine[] | select((.body // "") | contains("<!-- prr -->")) ] | last )
      // ( $mine | last ) )
  // empty
' "$reviews")"

mode="full-review"
commits_since="0"
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
    git -C "$wt" fetch -q origin "$prior_sha" 2>/dev/null || true
    if git -C "$wt" cat-file -e "${prior_sha}^{commit}" 2>/dev/null; then
      mapfile -t pr_files < <(jq -r '.files[].path' "$view")
      if [[ ${#pr_files[@]} -gt 0 ]]; then
        git -C "$wt" diff "${prior_sha}..HEAD" -- "${pr_files[@]}" > "$since_diff"
      else
        git -C "$wt" diff "${prior_sha}..HEAD" > "$since_diff"
      fi
      commits_since="$(git -C "$wt" rev-list --count "${prior_sha}..HEAD")"
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
