#!/usr/bin/env python3
"""slack-react-test.py -- checks slack_react.py on a post that lists several
PRs: the count that turns reactions off, and the label that prefixes the
reply. Uses the text shape conversations.history returns (links as <url>).
No network. Run: tests/slack-react-test.py

Author: Steve Woodruff (@sjwoodr)
SPDX-License-Identifier: MIT
"""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "slack_react", os.path.join(here, "..", "scripts", "slack_react.py"))
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)

REPO = "acme/widgets"
U = "https://github.com/acme/widgets/pull/"
BATCH = "\n".join([
    "Ready for review:",
    f"WID-10 Card reminder claims - <{U}1915>",
    f"WID-11 Receipt archiver - <{U}1916>",
    f"<https://acme.atlassian.net/browse/WID-12|WID-12> Company writes - <{U}1919|{U}1919>",
    f"<{U}1934>",
    "",
    "Details in each PR.",
])
SINGLE = f"WID-9 Dead-letter the streams <{U}1922>"

fails = 0


def expect(name, want, got):
    global fails
    if want == got:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name}: want {want!r}, got {got!r}")
        fails += 1


expect("batch counts every PR", 4, sr._pr_count(BATCH))
expect("single post counts one", 1, sr._pr_count(SINGLE))
expect("same PR twice counts once", 1, sr._pr_count(f"<{U}1922> and <{U}1922|#1922>"))
expect("label from a bare link line", "WID-10 Card reminder claims (#1915)",
       sr._label(BATCH, REPO, 1915))
expect("label unwraps a ticket link", "WID-12 Company writes (#1919)",
       sr._label(BATCH, REPO, 1919))
expect("link-only line falls back to the number", "#1934", sr._label(BATCH, REPO, 1934))
expect("1915 does not match 19150", "#19150", sr._label(BATCH, REPO, 19150))


# main() end to end, with the Slack calls stubbed: record what would be sent.
def run(text, number):
    calls = []
    sr._find_post = lambda *a: ("111.222", text, None)
    sr._do_unreact = lambda t, c, ts, e: calls.append(("unreact", e))
    sr._do_react = lambda t, c, ts, e: calls.append(("react", e))
    sr._do_reply = lambda t, c, ts, txt: calls.append(("reply", txt)) or True
    os.environ.update(SLACK_BOT_TOKEN="x", PRR_CODE_REVIEWS_CHANNEL="C1")
    sys.argv = ["slack_react.py", "--repo", REPO, "--number", str(number),
                "--unreact", "eyes", "--react", "white_check_mark",
                "--reply", "Reviewed it, looks good, approved."]
    with open(os.devnull, "w") as null:
        out, sys.stdout = sys.stdout, null
        try:
            rc = sr.main()
        finally:
            sys.stdout = out
    return rc, calls


expect("batch: unreact, no react, labelled reply", (0, [
    ("unreact", "eyes"),
    ("reply", "WID-11 Receipt archiver (#1916): Reviewed it, looks good, approved."),
]), run(BATCH, 1916))
expect("single: unchanged", (0, [
    ("unreact", "eyes"), ("react", "white_check_mark"),
    ("reply", "Reviewed it, looks good, approved."),
]), run(SINGLE, 1922))

sys.exit(1 if fails else 0)
