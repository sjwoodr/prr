#!/usr/bin/env python3
"""prr helper (optional): add an approval reaction to a PR's chat post.

Some teams post every PR as a one-liner to a chat channel (e.g. a Slack
"#code-reviews" channel) containing the GitHub pull URL. When a prr review is
APPROVED, this drops a reaction (default :white_check_mark:) on that post to
signal "reviewed/approved". Multiple reactions are fine (one per approver), so it
never skips just because the post already has one; the bot's own duplicate comes
back as `already_reacted` and is treated as a no-op.

This step is entirely OPT-IN via environment variables and is a no-op unless both
are set:
  SLACK_BOT_TOKEN          a Slack bot token with groups:history (or
                           channels:history for a public channel) + reactions:write
  PRR_CODE_REVIEWS_CHANNEL the channel ID to search (e.g. C0XXXXXXX)

Nothing is hard-coded; with neither var set the skill behaves exactly as before.
Best-effort by design: any failure (missing config, post not found, Slack error)
prints a note and exits 0 so it never aborts the review that was already posted.

Usage:
  slack_react.py --repo owner/name --number 754 [--channel C..] [--emoji ...]

Author: Steve Woodruff (@sjwoodr)
SPDX-License-Identifier: MIT
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

MAX_PAGES = 6  # ~1200 messages back, plenty for a PRs-only channel


def _api(method, token, params=None, post=False):
    url = f"https://slack.com/api/{method}"
    headers = {"Authorization": f"Bearer {token}"}
    if post:
        headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(url, data=json.dumps(params).encode(), headers=headers)
    else:
        url += "?" + urllib.parse.urlencode(params or {})
        req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def _find_post_ts(token, channel, repo, number):
    # Match the PR url path, repo-qualified, number not followed by another digit.
    pat = re.compile(rf"/{re.escape(repo)}/pull/{number}(?!\d)")
    cursor = None
    for _ in range(MAX_PAGES):
        params = {"channel": channel, "limit": 200}
        if cursor:
            params["cursor"] = cursor
        r = _api("conversations.history", token, params)
        if not r.get("ok"):
            return None, r.get("error", "unknown")
        for m in r.get("messages", []):
            if pat.search(m.get("text", "")):
                return m["ts"], None
        cursor = r.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            break
    return None, "post not found"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--number", required=True)
    ap.add_argument("--channel", default=os.environ.get("PRR_CODE_REVIEWS_CHANNEL"))
    ap.add_argument("--emoji", default="white_check_mark")
    args = ap.parse_args()

    token = os.environ.get("SLACK_BOT_TOKEN")
    if not token or not args.channel:
        # Opt-in feature: silently do nothing unless both token and channel are set.
        return 0

    ts, err = _find_post_ts(token, args.channel, args.repo, args.number)
    if not ts:
        print(f"slack: could not react ({err}); add the {args.emoji} manually if needed")
        return 0

    r = _api("reactions.add", token,
             {"channel": args.channel, "timestamp": ts, "name": args.emoji}, post=True)
    if r.get("ok"):
        print(f"slack: added :{args.emoji}: to the PR's chat post (ts {ts})")
    elif r.get("error") == "already_reacted":
        print(f"slack: :{args.emoji}: already added by the bot (ts {ts}), no-op")
    else:
        print(f"slack: reaction failed ({r.get('error')}); add it manually if needed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
