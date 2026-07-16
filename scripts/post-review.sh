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
# A full PR URL works from any directory; a bare PR number must be run from
# inside the PR's git repo.
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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the repo now so both the cleanup-only path and the post path can
# address the team's PR chat post (to clear the :eyes: marker, etc.).
[[ -z "$repo" ]] && repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# Best-effort: drop the :eyes: "review in progress" marker setup-review.sh
# added. No-op unless the Slack env vars are set or the post is found.
clear_eyes() {
  python3 "$script_dir/slack_react.py" \
    --repo "$repo" --number "$number" --unreact eyes || true
}

# Fan-out mode: when this review runs inside a prr-fanout.sh tmux pane
# (PRR_FANOUT_PANE set), drop a one-line result file that the launcher polls to
# learn this PR is done and close its pane. Keyed on the PR number so the
# launcher finds it. No-op outside fan-out.
write_fanout_result() {
  [[ -n "${PRR_FANOUT_PANE:-}" ]] || return 0
  printf 'pr=%s status=%s event=%s comments=%s\n' \
    "$number" "$1" "${2:-none}" "${3:-0}" > "/tmp/prr-fanout-${number}.result"
}

cleanup() {
  # Local-worktree mode registers $wt as a git worktree; standalone mode leaves
  # a throwaway repo directory. Handle both, and tolerate being run from outside
  # any git repo.
  #
  # Resolve the main worktree from $wt itself BEFORE moving, then hop out of $wt
  # and drive git with `git -C`. This makes removal work even when the caller's
  # shell is parked inside $wt (a reviewer cd'd in, despite the skill saying not
  # to) — otherwise `git worktree remove` and `rm -rf` both fail on the cwd with
  # "Unable to read current working directory".
  local main_wt
  main_wt="$(git -C "$wt" worktree list --porcelain 2>/dev/null \
             | awk '/^worktree /{print $2; exit}')"
  cd /tmp 2>/dev/null || cd / || true
  if [[ -n "$main_wt" && "$main_wt" != "$wt" ]] \
     && git -C "$main_wt" worktree list --porcelain 2>/dev/null | grep -qF "$wt"; then
    git -C "$main_wt" worktree remove "$wt" --force
    git -C "$main_wt" worktree prune
    echo "worktree removed: $wt"
  elif [[ -e "$wt" ]]; then
    rm -rf "$wt"
    echo "pr checkout removed: $wt"
  else
    echo "pr checkout already gone: $wt"
  fi
  rm -f "/tmp/pr-${number}-view.json" "/tmp/pr-${number}-diff.txt" \
        "/tmp/pr-${number}-comments.json" "/tmp/pr-${number}-review.json" \
        "/tmp/pr-${number}-reviews.json" "/tmp/pr-${number}-prior-review.json" \
        "/tmp/pr-${number}-since-diff.txt" "$marked"
  # Clear the "reviewing PR #N" status-line marker for this session (opt-in
  # statusLine, see setup-review.sh / README). Harmless if it was never written.
  rm -f "/tmp/prr-status-${CLAUDE_CODE_SESSION_ID:-nosession}"
}

# No payload: cleanup-only mode (declined gate, self-review, re-review report).
# Nothing gets posted, so clear the in-progress :eyes: and tear down.
if [[ -z "$payload" ]]; then
  echo "cleanup-only: no payload given, not posting a review"
  clear_eyes
  write_fanout_result not-posted
  cleanup
  exit 0
fi

[[ -f "$payload" ]] || { echo "error: payload not found: $payload" >&2; exit 2; }
jq empty "$payload" 2>/dev/null \
  || { echo "error: payload is not valid JSON: $payload" >&2; exit 2; }

# Pull out the optional plain-language thread summary, then strip it from the
# body posted to GitHub (the reviews endpoint should only see real review
# fields). Append the prr marker (idempotent) so future runs detect this.
slack_summary="$(jq -r '.slack_summary // empty' "$payload")"
jq 'del(.slack_summary)
    | if ((.body // "") | contains("<!-- prr -->")) then .
      else .body = ((.body // "") + "\n\n<!-- prr -->") end' \
  "$payload" > "$marked"

event="$(jq -r '.event // "COMMENT"' "$marked")"
ncomments="$(jq '.comments | length' "$marked")"
echo "posting review to $repo #$number — event=$event, inline comments=$ncomments"

# Post the review. The one common transient failure is a stale commit_id: the
# PR head moved (rebase/force-push) after setup-review.sh pinned it, which
# GitHub rejects with 422 "pull request has been updated since you started
# reviewing". Re-resolve the head and retry once — that recovers the usual case
# where the inline anchor lines still land. If the retry also fails (anchors now
# stale), or it is any other error, leave the worktree and payload in place and
# tell the reviewer how to recover, rather than silently dropping the review.
post_review() {
  gh api "repos/${repo}/pulls/${number}/reviews" \
    --method POST --input "$marked" \
    --jq '"posted review id=\(.id) state=\(.state) url=\(.html_url)"'
}

if out="$(post_review 2>&1)"; then
  echo "$out"
elif grep -qiE 'updated since you started reviewing' <<<"$out"; then
  fresh_sha="$(gh pr view "$number" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  stale_sha="$(jq -r '.commit_id // empty' "$marked")"
  if [[ -n "$fresh_sha" && "$fresh_sha" != "$stale_sha" ]]; then
    echo "note: PR head moved since setup ($stale_sha -> $fresh_sha); retrying against the new head" >&2
    tmp="$(mktemp)" && jq --arg s "$fresh_sha" '.commit_id = $s' "$marked" > "$tmp" && mv "$tmp" "$marked"
    if out="$(post_review 2>&1)"; then
      echo "$out"
    else
      echo "$out" >&2
      echo "error: re-post against the new head failed too — the inline comment anchors are probably stale now." >&2
      echo "       Re-run '$script_dir/setup-review.sh $number' (it picks up the new head) and rebuild the payload against the current diff. Worktree and payload left in place." >&2
      exit 1
    fi
  else
    echo "$out" >&2
    echo "error: GitHub says the PR was updated but its head sha is unchanged ($stale_sha); not retrying blindly." >&2
    echo "       Re-run '$script_dir/setup-review.sh $number' to refresh. Worktree and payload left in place." >&2
    exit 1
  fi
else
  echo "$out" >&2
  exit 1
fi

# Optional: signal the review outcome on the team's PR chat post. No-op unless
# both SLACK_BOT_TOKEN and PRR_CODE_REVIEWS_CHANNEL are set. We clear the
# in-progress :eyes:, add an outcome reaction (check mark for an approval,
# speech balloon for a COMMENT or REQUEST_CHANGES, "has feedback to read"), and
# drop a short plain-language reply in the post's thread if the skill provided
# one. Best-effort: the review is already posted, so never let this abort.
case "$event" in
  APPROVE) react_emoji="white_check_mark" ;;
  *)       react_emoji="speech_balloon" ;;
esac
python3 "$script_dir/slack_react.py" \
  --repo "$repo" --number "$number" \
  --unreact eyes --react "$react_emoji" \
  ${slack_summary:+--reply "$slack_summary"} || true

write_fanout_result posted "$event" "$ncomments"

cleanup
