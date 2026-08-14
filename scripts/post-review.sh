#!/usr/bin/env bash
# post-review.sh — prr skill final step: submit the review, then clean up.
# Works for a first review and for a re-review follow-up.
#
# Usage:
#   post-review.sh [--silent] <PR-url-or-number> <payload.json> [owner/repo]
#   post-review.sh [--silent] <PR-url-or-number>                  clean only
#
# --silent is stealth mode: post the review to GitHub as normal, but send no
# Slack signal at all. Normally inherited from setup-review.sh via the
# /tmp/pr-<n>-silent marker, so it does not have to be re-passed here.
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

# Stealth flag, accepted anywhere in the arg list and stripped before the
# positional parsing below. Usually redundant: setup-review.sh records the
# choice in a marker file that this script picks up on its own (see below).
silent=0
_args=()
for _a in "$@"; do
  case "$_a" in
    --silent|silent) silent=1 ;;
    *) _args+=("$_a") ;;
  esac
done
# Guarded expansion: bash 3.2 errors on an empty array under `set -u`.
if ((${#_args[@]})); then set -- "${_args[@]}"; else set --; fi

arg="${1:?usage: post-review.sh [--silent] <PR-url-or-number> [payload.json] [owner/repo]}"
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
silent_marker="/tmp/pr-${number}-silent"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# setup-review.sh records "send this review no outbound Slack signal" here, for
# --silent and for self-review alike. Inheriting it means stealth survives the
# gap between the two invocations without the skill having to remember a flag.
[[ -f "$silent_marker" ]] && silent=1

# Resolve the repo now so both the cleanup-only path and the post path can
# address the team's PR chat post (to clear the :eyes: marker, etc.).
[[ -z "$repo" ]] && repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# Best-effort: drop the :eyes: "review in progress" marker setup-review.sh
# added. No-op unless the Slack env vars are set or the post is found.
#
# Deliberately NOT skipped under stealth, even though a silent setup never added
# one. Removing a reaction only ever takes a signal away, so it cannot blow the
# cover this is protecting, and skipping it would strand a real :eyes: in the
# one case that matters: an ordinary review of this PR that added the marker,
# followed by a stealth re-review. Leaving "steve is reviewing this" pinned to
# the post forever is louder than the API call it costs to clear it.
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
  # Guarded on $wt existing, and `|| true` on the pipeline. Without both, an
  # already-gone worktree makes `git -C "$wt"` fail to chdir, and `set -e` plus
  # `pipefail` abort cleanup right here — exit 128, before a single artifact is
  # removed and before the confirmation line the skill relies on. That turned a
  # missing directory into every /tmp/pr-<n>-* file being left behind, which is
  # the opposite of what this function is for. Reachable whenever cleanup runs
  # twice, or the worktree was removed by hand between the two script calls.
  local main_wt=""
  if [[ -d "$wt" ]]; then
    main_wt="$(git -C "$wt" worktree list --porcelain 2>/dev/null \
               | awk '/^worktree /{print $2; exit}' || true)"
  fi
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
  # Removal is a GLOB, deliberately the SAME pattern the verification loop below
  # walks. It used to be a hand-maintained list of the filenames these scripts
  # create, which meant removal covered strictly less than verification checked,
  # and every new artifact had to be remembered or the review self-reported as
  # littered. Two features already walked into that: the stealth marker and the
  # source-b spawn stamp each shipped a fix adding themselves to the list.
  #
  # The case an enumeration can NEVER cover is the one that made this worth
  # changing: files a review SESSION writes at runtime rather than a script.
  # Drafting inline comment bodies or a review body to their own files (to dodge
  # shell quoting when assembling the payload) is a reasonable thing for an
  # assistant to do, and those names are invented on the spot, so no commit
  # exists in which anyone could have listed them. They orphaned permanently and
  # every later review of the same PR reported INCOMPLETE for them.
  #
  # $number is matched as [0-9]+ at parse time, so the prefix is always bounded
  # and can never widen to something unrelated.
  #
  # rm -rf, not rm -f: a session can leave a DIRECTORY under the prefix, and
  # rm -f would skip it, leaving verification to report it forever. $wt is
  # skipped because it is handled above; without that, a failed worktree removal
  # would come back here as an rm on a live git worktree.
  local artifact
  for artifact in "/tmp/pr-${number}-"*; do
    if [[ -e "$artifact" && "$artifact" != "$wt" ]]; then
      rm -rf "$artifact"
    fi
  done
  # Clear the "reviewing PR #N" status-line marker for this session (opt-in
  # statusLine, see setup-review.sh / README). Harmless if it was never written.
  rm -f "/tmp/prr-status-${CLAUDE_CODE_SESSION_ID:-nosession}"

  # Verify rather than assume, and print one line the caller can trust as THE
  # cleanup confirmation. The skill reads this and runs no follow-up check of
  # its own: an ad hoc `ls /tmp/pr-N-*` + `git worktree list | grep N` pipeline
  # embeds the PR number, so it can never match the permission allow-list and
  # prompts for approval on every single review.
  #
  # Plain string rather than an array: bash 3.2 (stock macOS) errors on an
  # empty array expansion under `set -u`. /tmp/prr-fanout-<n>.result is
  # deliberately not checked -- it outlives cleanup for the fan-out rollup, and
  # does not match this glob anyway.
  local leftovers=""
  if [[ -e "$wt" ]]; then
    leftovers="$wt"
  fi
  # `artifact` is already declared local by the removal loop above.
  for artifact in "/tmp/pr-${number}-"*; do
    # $wt is itself /tmp/pr-<n>-wt, so the glob re-matches it; skip to avoid
    # naming the worktree twice in the INCOMPLETE line.
    if [[ -e "$artifact" && "$artifact" != "$wt" ]]; then
      leftovers="${leftovers:+$leftovers }$artifact"
    fi
  done
  if [[ -n "$leftovers" ]]; then
    echo "cleanup INCOMPLETE, still present: $leftovers"
  else
    echo "cleanup verified: worktree gone, no /tmp/pr-${number}-* artifacts left"
  fi
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

# Refuse to post a review pinned to a head that is no longer current. A moved
# head means commits landed after the findings were formed, so the review was
# not written against the code it would be approving. Retargeting it to the new
# head (which this script used to do on GitHub's 422) turns that into an
# approval of code nobody read.
#
# No override flag, on purpose: the way through is to review the commits that
# landed and rebuild the payload with the new commit_id, and then this check
# passes by itself. An escape hatch here would be an escape hatch around the
# only thing enforcing that.
#
# Fail-open if the head cannot be resolved (network blip): GitHub's own 422
# below is the backstop, and it no longer retries.
payload_sha="$(jq -r '.commit_id // empty' "$marked")"
live_sha="$(gh pr view "$number" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null || true)"
if [[ -n "$live_sha" && -n "$payload_sha" && "$live_sha" != "$payload_sha" ]]; then
  echo "error: the PR head moved after this review was prepared; refusing to post." >&2
  echo "         reviewed: $payload_sha" >&2
  echo "         current:  $live_sha" >&2
  echo "       Re-run '$script_dir/setup-review.sh $number' to fetch and move the worktree" >&2
  echo "       to the new head, review what landed in between:" >&2
  echo "         git -C /tmp/pr-${number}-wt log --oneline ${payload_sha}..${live_sha}" >&2
  echo "         git -C /tmp/pr-${number}-wt diff ${payload_sha}..${live_sha}" >&2
  echo "       then rebuild the payload with commit_id set to the new head." >&2
  echo "       Worktree and payload left in place; nothing was posted." >&2
  exit 1
fi

echo "posting review to $repo #$number — event=$event, inline comments=$ncomments"

# Post the review. GitHub rejects a stale commit_id with 422 "pull request has
# been updated since you started reviewing" — the same moved-head condition the
# pre-flight check above catches, reached here when the head moved in the gap
# between that check and this call, or when the check could not resolve the head.
#
# This used to re-resolve the head, rewrite commit_id and retry. That silently
# posted the review against commits the reviewer never saw, which is the whole
# problem: an APPROVE is a statement about specific code. Now it refuses and
# says what to re-read. Never restore the retry.
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
  echo "$out" >&2
  echo "error: the PR head moved while this review was being posted; nothing was posted." >&2
  echo "         reviewed: ${stale_sha:-unknown}" >&2
  echo "         current:  ${fresh_sha:-unresolved}" >&2
  echo "       Re-run '$script_dir/setup-review.sh $number', review the commits that landed," >&2
  echo "       and rebuild the payload with commit_id set to the new head." >&2
  echo "       Worktree and payload left in place." >&2
  exit 1
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
# Under stealth the review still lands on GitHub in full; only the outcome
# reaction and the thread reply are withheld. The :eyes: unreact still runs:
# this path never calls clear_eyes (it folds the unreact into the same call
# below), so skipping outright would strand a marker left by an earlier
# ordinary review of this PR.
if ((silent)); then
  clear_eyes
  echo "slack: silent mode — no outcome reaction and no thread reply"
else
  case "$event" in
    APPROVE) react_emoji="white_check_mark" ;;
    *)       react_emoji="speech_balloon" ;;
  esac
  python3 "$script_dir/slack_react.py" \
    --repo "$repo" --number "$number" \
    --unreact eyes --react "$react_emoji" \
    ${slack_summary:+--reply "$slack_summary"} || true
fi

write_fanout_result posted "$event" "$ncomments"

cleanup
