#!/usr/bin/env python3
"""jira-ticket.py -- read a linked Jira ticket's criteria over REST, fast or not at all.

  jira-ticket.py <pr-number> <KEY-NNNN> [<KEY-NNNN> ...]
  jira-ticket.py --selftest

setup-review.sh runs it when JIRA_BASE_URL, JIRA_EMAIL and JIRA_API_TOKEN are
set. An Atlassian MCP call can hang for minutes and the model cannot put a
time limit on it; this has a hard 30 second limit per ticket, after which the
review goes on without the ticket.

For each key it writes the summary, status, description and every non-empty
field whose name mentions acceptance or criteria, as plain text, to
/tmp/pr-<N>-ticket.txt, and prints one line per key. Nothing else from the
ticket is kept: prr reads a ticket only to check acceptance criteria.
Always exits 0.

Author: Steve Woodruff (@sjwoodr)
SPDX-License-Identifier: MIT
"""
import base64
import json
import os
import signal
import sys
import urllib.parse
import urllib.request

LIMIT = 30  # seconds per ticket, connect to last byte


def adf_text(node, depth=0):
    """Atlassian Document Format to plain text; strings pass through."""
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "".join(adf_text(n, depth) for n in node)
    kind, kids = node.get("type"), node.get("content", [])
    if kind == "text":
        return node.get("text", "")
    if kind == "hardBreak":
        return "\n"
    if kind in ("mention", "emoji", "inlineCard"):
        attrs = node.get("attrs", {})
        return attrs.get("text") or attrs.get("shortName") or attrs.get("url") or ""
    if kind in ("bulletList", "orderedList"):
        return "".join(adf_text(k, depth + 1) for k in kids)
    if kind == "listItem":
        body = adf_text(kids, depth).strip().replace("\n", "\n" + "  " * depth)
        return "  " * (depth - 1) + "- " + body + "\n"
    if kind == "heading":
        return "#" * node.get("attrs", {}).get("level", 2) + " " + adf_text(kids, depth) + "\n\n"
    if kind in ("paragraph", "codeBlock", "blockquote", "panel"):
        return adf_text(kids, depth) + "\n\n"
    return adf_text(kids, depth)


def fetch(key):
    base = os.environ["JIRA_BASE_URL"].rstrip("/")
    auth = base64.b64encode(f"{os.environ['JIRA_EMAIL']}:{os.environ['JIRA_API_TOKEN']}".encode()).decode()
    req = urllib.request.Request(
        f"{base}/rest/api/3/issue/{urllib.parse.quote(key)}?fields=*all&expand=names",
        headers={"Authorization": f"Basic {auth}", "Accept": "application/json"})

    def expired(*_):
        raise TimeoutError(f"no answer in {LIMIT}s")

    signal.signal(signal.SIGALRM, expired)
    signal.alarm(LIMIT)  # urllib's timeout is per socket read, not the whole call
    try:
        with urllib.request.urlopen(req, timeout=LIMIT) as r:
            return json.load(r)
    finally:
        signal.alarm(0)


def render(key, issue):
    fields, names = issue.get("fields", {}), issue.get("names", {})
    out = [f"=== {key}: {fields.get('summary', '')}",
           f"status: {(fields.get('status') or {}).get('name', '?')}"]
    criteria = [fid for fid, name in names.items()
                if fields.get(fid) and any(w in name.lower() for w in ("acceptance", "criteria"))]
    for fid in criteria:
        out += [f"--- {names[fid]}", adf_text(fields[fid]).strip()]
    if not criteria:
        out.append("--- no acceptance-criteria field set; check the description")
    out += ["--- Description", adf_text(fields.get("description")).strip() or "(empty)"]
    return "\n".join(out) + "\n\n"


def selftest():
    doc = {"type": "doc", "content": [
        {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "AC"}]},
        {"type": "bulletList", "content": [
            {"type": "listItem", "content": [{"type": "paragraph", "content": [
                {"type": "text", "text": "one"}]}]},
            {"type": "listItem", "content": [{"type": "paragraph", "content": [
                {"type": "text", "text": "two"}]}]}]}]}
    assert adf_text(doc) == "## AC\n\n- one\n- two\n", repr(adf_text(doc))
    issue = {"names": {"summary": "Summary", "customfield_1": "Acceptance Criteria",
                       "customfield_2": "Internal notes"},
             "fields": {"summary": "S", "status": {"name": "In Progress"}, "customfield_1": doc,
                        "customfield_2": "secret", "description": None}}
    text = render("K-1", issue)
    assert "- two" in text and "secret" not in text and "(empty)" in text, text
    print("jira-ticket selftest: ok")


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    if len(sys.argv) < 3:
        sys.exit(__doc__.split("\n\n")[1])
    number, keys = sys.argv[1], sys.argv[2:]
    path = f"/tmp/pr-{number}-ticket.txt"
    text = ""
    for key in keys:
        try:
            text += render(key, fetch(key))
            print(f"ticket:            {key} read over REST -> {path}")
        except Exception as e:  # noqa: BLE001 - a ticket is context, never a blocker
            print(f"ticket:            {key} NOT read over REST ({type(e).__name__}: {e})")
    if text:
        with open(path, "w") as fh:
            fh.write(text)


if __name__ == "__main__":
    main()
