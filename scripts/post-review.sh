#!/usr/bin/env bash
# post-review.sh — prr skill final step: submit the review, then clean up.
# Works for a first review and for a re-review follow-up.
#
# Usage:
#   post-review.sh <PR-url-or-number> <payload.json> [owner/repo]   post + clean
#   post-review.sh <PR-url-or-number>                               clean only
#
# The payload JSON is built by the skill after the approval gate and must
# contain: commit_id, event (APPROVE|REQUEST_CHANGES|COMMENT), body, comments[].
# A hidden `<!-- prr -->` marker is appended to the body before posting so a
# later prr run recognises this as a prr review and switches to re-review.
# Run from inside the target git repo (git worktree needs it).
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

arg="${1:?usage: post-review.sh <PR-url-or-number> [payload.json] [owner/repo]}"
payload="${2:-}"
repo="${3:-}"

if [[ "$arg" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  repo="${repo:-${BASH_REMATCH[1]}/${BASH_REMATCH[2]}}"
  number="${BASH_REMATCH[3]}"
elif [[ "$arg" =~ ^[0-9]+$ ]]; then
  number="$arg"
else
  echo "error: '$arg' is neither a PR URL nor a number" >&2
  exit 2
fi

wt="/tmp/pr-${number}-wt"
marked="/tmp/pr-${number}-review.posted.json"

cleanup() {
  if git worktree list --porcelain | grep -qF "$wt"; then
    git worktree remove "$wt" --force
    git worktree prune
    echo "worktree removed: $wt"
  else
    echo "worktree already gone: $wt"
  fi
  rm -f "/tmp/pr-${number}-view.json" "/tmp/pr-${number}-diff.txt" \
        "/tmp/pr-${number}-comments.json" "/tmp/pr-${number}-review.json" \
        "/tmp/pr-${number}-reviews.json" "/tmp/pr-${number}-prior-review.json" \
        "/tmp/pr-${number}-since-diff.txt" "$marked"
}

# No payload: cleanup-only mode (e.g. the review was declined at the gate).
if [[ -z "$payload" ]]; then
  echo "cleanup-only: no payload given, not posting a review"
  cleanup
  exit 0
fi

[[ -f "$payload" ]] || { echo "error: payload not found: $payload" >&2; exit 2; }
jq empty "$payload" 2>/dev/null \
  || { echo "error: payload is not valid JSON: $payload" >&2; exit 2; }
[[ -z "$repo" ]] && repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# Append the prr marker to the body (idempotent) so future runs detect it.
jq 'if ((.body // "") | contains("<!-- prr -->")) then .
     else .body = ((.body // "") + "\n\n<!-- prr -->") end' \
  "$payload" > "$marked"

event="$(jq -r '.event // "COMMENT"' "$marked")"
ncomments="$(jq '.comments | length' "$marked")"
echo "posting review to $repo #$number — event=$event, inline comments=$ncomments"

# Post the review. If this fails, `set -e` aborts here BEFORE cleanup, so
# the worktree and payload survive for a retry.
gh api "repos/${repo}/pulls/${number}/reviews" \
  --method POST --input "$marked" \
  --jq '"posted review id=\(.id) state=\(.state) url=\(.html_url)"'

cleanup
