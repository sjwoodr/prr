#!/usr/bin/env python3
"""prr helper (optional): signal review progress on a PR's chat post.

Some teams post every PR as a one-liner to a chat channel (e.g. a Slack
"#code-reviews" channel) containing the GitHub pull URL. This helper finds that
post and signals review progress on it:

  - when a review STARTS, an :eyes: reaction is added ("someone is reviewing");
  - when the review is POSTED, the :eyes: is removed, an outcome reaction is
    added (:white_check_mark: for an approval, :speech_balloon: for feedback),
    and a short plain-language reply is dropped in the post's thread.

All three are independent operations on the same found post, selected by flag:
  --react EMOJI    add a reaction (e.g. eyes, white_check_mark, speech_balloon)
  --unreact EMOJI  remove a reaction (no-op if it was not there)
  --reply TEXT     post TEXT as a threaded reply under the post

Multiple flags may be combined in one call; they run in order unreact -> react
-> reply against the single post the helper locates.

This step is entirely OPT-IN via environment variables and is a no-op unless both
are set:
  SLACK_BOT_TOKEN          a Slack bot token with groups:history (or
                           channels:history for a public channel),
                           reactions:write, and chat:write (for --reply)
  PRR_CODE_REVIEWS_CHANNEL the channel ID to search (e.g. C0XXXXXXX)

Nothing is hard-coded; with neither var set the skill behaves exactly as before.
Best-effort by design: any failure (missing config, post not found, Slack error)
prints a note and exits 0 so it never aborts the review that was already posted.

Usage:
  slack_react.py --repo owner/name --number 754 --react eyes
  slack_react.py --repo owner/name --number 754 \
                 --unreact eyes --react white_check_mark --reply "looks good"

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


def _do_unreact(token, channel, ts, emoji):
    r = _api("reactions.remove", token,
             {"channel": channel, "timestamp": ts, "name": emoji}, post=True)
    if r.get("ok"):
        print(f"slack: removed :{emoji}: from the PR's chat post (ts {ts})")
    elif r.get("error") == "no_reaction":
        print(f"slack: :{emoji}: was not present (ts {ts}), no-op")
    else:
        print(f"slack: removing :{emoji}: failed ({r.get('error')}); remove it manually if needed")


def _do_react(token, channel, ts, emoji):
    r = _api("reactions.add", token,
             {"channel": channel, "timestamp": ts, "name": emoji}, post=True)
    if r.get("ok"):
        print(f"slack: added :{emoji}: to the PR's chat post (ts {ts})")
    elif r.get("error") == "already_reacted":
        print(f"slack: :{emoji}: already added by the bot (ts {ts}), no-op")
    else:
        print(f"slack: reaction :{emoji}: failed ({r.get('error')}); add it manually if needed")


def _do_reply(token, channel, ts, text):
    r = _api("chat.postMessage", token,
             {"channel": channel, "thread_ts": ts, "text": text}, post=True)
    if r.get("ok"):
        print(f"slack: posted a thread reply to the PR's chat post (ts {ts})")
    else:
        print(f"slack: thread reply failed ({r.get('error')}); reply manually if needed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--number", required=True)
    ap.add_argument("--channel", default=os.environ.get("PRR_CODE_REVIEWS_CHANNEL"))
    ap.add_argument("--react", help="emoji to add (e.g. eyes, white_check_mark)")
    ap.add_argument("--unreact", help="emoji to remove (no-op if absent)")
    ap.add_argument("--reply", help="text to post as a threaded reply")
    # Backward-compat alias: older callers pass --emoji to add a reaction.
    ap.add_argument("--emoji", help=argparse.SUPPRESS)
    args = ap.parse_args()

    react = args.react or args.emoji  # --emoji is the legacy spelling of --react

    token = os.environ.get("SLACK_BOT_TOKEN")
    if not token or not args.channel:
        # Opt-in feature: silently do nothing unless both token and channel are set.
        return 0
    if not (react or args.unreact or args.reply):
        return 0  # nothing asked of us

    ts, err = _find_post_ts(token, args.channel, args.repo, args.number)
    if not ts:
        print(f"slack: PR chat post not found ({err}); skipping reactions/reply")
        return 0

    # Order matters: clear the in-progress marker, set the outcome, then reply.
    if args.unreact:
        _do_unreact(token, args.channel, ts, args.unreact)
    if react:
        _do_react(token, args.channel, ts, react)
    if args.reply:
        _do_reply(token, args.channel, ts, args.reply)
    return 0


if __name__ == "__main__":
    sys.exit(main())
