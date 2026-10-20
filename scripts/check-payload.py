#!/usr/bin/env python3
"""check-payload.py -- prr's rules that a model can't talk its way past.

  check-payload.py <pr-number> <payload.json>     exit 0 ok, 2 with reasons
  check-payload.py --selftest

post-review.sh runs this before anything reaches GitHub. Each check is a rule
the skill states in prose and a model once broke anyway (gpt-oss in pi,
2026-10-13: added three comments after the gate, wrote non-ASCII, recorded a
Source B skip that the rules did not allow and "no ticket" for a linked one):

- ASCII: the body, every comment, reply and slack_summary are plain ASCII,
  except the code inside a ```suggestion block.
- The gate: every inline comment in the payload is one of the drafts shown at
  the gate, saved to /tmp/pr-<N>-draft.json before asking. A subset is fine
  (approve with no nits); a new or reworded comment is not.
- source_b: "returned" needs Source B's b-done stamp, "timeout" its start
  stamp, and "skipped-prose" a change where every file is plain prose. A full
  review has to say what happened to Source B at all.
- source_c (opt-in): optional, but once Source C was started a payload must
  say what happened to it; "returned" needs its c-done stamp and consistent
  source_c_counts (what it contributed), and every other outcome but
  "no-model" and "skipped-prose" needs its start stamp.
- ac: "no-ticket" is refused when the PR's title or body links a ticket.
- reapproved: "conflict-fix" (a re-approval posted without the gate) needs
  conflict-fix.py's evidence to have found the PR eligible, for this same
  head, and the review to be a bare APPROVE: no inline comments, no replies.
"""
import json
import os
import re
import sys
import tempfile

SUGGESTION = re.compile(r"```suggestion\b.*?```", re.S)
# The skill's plain-prose rule, as far as file names can show it. Runbooks and
# claims about the live system can't be told from a name; those stay a call
# for the reviewer, so this only refuses what is certainly not prose.
PROSE_EXT = re.compile(r"\.(md|rst|adoc|txt)$", re.I)
PROSE_NAMES = re.compile(r"(^|/)(LICENSE|CHANGELOG|AUTHORS|NOTICE|CONTRIBUTORS)$")
AGENT_FILES = re.compile(
    r"(^|/)(CLAUDE\.md|AGENTS\.md|SKILL\.md|copilot-instructions\.md)$"
    r"|(^|/)\.(claude|cursor|github)/"
)
TICKET = re.compile(
    r"atlassian\.net/browse/[A-Z][A-Z0-9]+-\d+"
    r"|github\.com/[^/\s]+/[^/\s]+/issues/\d+"
    r"|^\s*\[[A-Z][A-Z0-9]+-\d+\]"
)


def non_ascii(text, where):
    text = SUGGESTION.sub("", text or "")
    bad = sorted({c for c in text if ord(c) > 127})
    if not bad:
        return []
    shown = ", ".join(f"{c!r} U+{ord(c):04X}" for c in bad[:6])
    return [f"{where}: non-ASCII outside a suggestion block ({shown})"]


def check_ascii(payload):
    problems = non_ascii(payload.get("body"), "body")
    problems += non_ascii(payload.get("slack_summary"), "slack_summary")
    for i, c in enumerate(payload.get("comments") or []):
        problems += non_ascii(c.get("body"), f"comment {i + 1} ({c.get('path')}:{c.get('line')})")
    for i, r in enumerate(payload.get("replies") or []):
        problems += non_ascii(r.get("body"), f"reply {i + 1}")
    return problems


def comment_key(c):
    return (c.get("path"), c.get("line"), c.get("start_line"), (c.get("body") or "").strip())


def check_gate(payload, draft_path):
    comments = payload.get("comments") or []
    if not comments:
        return []
    try:
        draft = json.load(open(draft_path))
    except FileNotFoundError:
        return [f"inline comments but no {draft_path}: save the drafts shown at the gate "
                "there (a JSON array of {path, line, body}) before asking, then build the "
                "payload from that file"]
    except ValueError:
        return [f"{draft_path} is not valid JSON"]
    drafted = {comment_key(c) for c in (draft.get("comments", []) if isinstance(draft, dict) else draft)}
    return [f"comment {i + 1} ({c.get('path')}:{c.get('line')}) was not among the drafts "
            "shown at the gate; post only what the user approved"
            for i, c in enumerate(comments) if comment_key(c) not in drafted]


def all_prose(paths):
    return bool(paths) and all(
        (PROSE_EXT.search(p) or PROSE_NAMES.search(p)) and not AGENT_FILES.search(p)
        for p in paths
    )


def check_source_b(payload, tmp, number, mode, paths):
    source_b = payload.get("source_b")
    if source_b is None:
        return ["source_b missing: a full review records what happened to Source B"] \
            if mode == "full-review" else []
    stamp = lambda name: os.path.exists(os.path.join(tmp, f"pr-{number}-{name}"))
    if source_b == "returned" and not stamp("b-done"):
        return ['source_b is "returned" but Source B never stamped b-done']
    if source_b == "timeout" and not stamp("sourceb-started"):
        return ['source_b is "timeout" but Source B was never started']
    if source_b == "skipped-prose" and not all_prose(paths):
        code = [p for p in paths if not all_prose([p])][:3]
        return ['source_b is "skipped-prose" but the change is not all plain prose '
                f"({', '.join(code)}): run Source B"]
    return []


SOURCE_C = ("returned", "failed", "stubbed", "timeout", "skipped-prose", "no-model")


def check_source_c(payload, tmp, number, paths):
    source_c = payload.get("source_c")
    stamp = lambda name: os.path.exists(os.path.join(tmp, f"pr-{number}-{name}"))
    if source_c is None:
        return ["source_c missing: Source C was started, so record what happened to it"] \
            if stamp("sourcec-started") else []
    if source_c not in SOURCE_C:
        return [f'source_c "{source_c}" is not one of {", ".join(SOURCE_C)}']
    if source_c == "returned" and not stamp("c-done"):
        return ['source_c is "returned" but Source C never stamped c-done']
    if source_c == "returned":
        counts = payload.get("source_c_counts")
        keys = ("found", "only", "kept", "only_kept")
        if not isinstance(counts, dict) or not all(isinstance(counts.get(k), int) for k in keys):
            return ['source_c is "returned" but source_c_counts is missing or incomplete: '
                    'record found, only, kept and only_kept from the gate\'s Sources block']
        if not (counts["only_kept"] <= counts["only"] <= counts["found"]
                and counts["only_kept"] <= counts["kept"] <= counts["found"]):
            return [f"source_c_counts do not add up: {counts}"]
    if source_c in ("failed", "stubbed", "timeout") and not stamp("sourcec-started"):
        return [f'source_c is "{source_c}" but Source C was never started']
    if source_c == "skipped-prose" and not all_prose(paths):
        return ['source_c is "skipped-prose" but the change is not all plain prose']
    return []


def check_ac(payload, view):
    if payload.get("ac") != "no-ticket":
        return []
    text = (view.get("title") or "") + "\n" + (view.get("body") or "")
    hit = TICKET.search(text) or TICKET.search(view.get("title") or "")
    return [f'ac is "no-ticket" but the PR links one ({hit.group(0).strip()}): '
            'read it, or record "unread" if it could not be fetched'] if hit else []


def check_reapproval(payload, tmp, number, mode):
    why = payload.get("reapproved")
    if why is None:
        return []
    if why != "conflict-fix":
        return [f'reapproved is "{why}"; the only kind is "conflict-fix"']
    try:
        ev = json.load(open(os.path.join(tmp, f"pr-{number}-conflict-fix.json")))
    except (FileNotFoundError, ValueError):
        return ["reapproved without conflict-fix evidence: setup runs conflict-fix.py "
                "only with PRR_REAPPROVE_CONFLICT_FIX=1"]
    out = []
    if mode != "re-review":
        out.append("reapproved outside a re-review")
    if not ev.get("eligible"):
        out.append(f"reapproved, but the evidence says no: {ev.get('reason')}")
    if payload.get("event") != "APPROVE":
        out.append("a conflict-fix re-approval posts APPROVE")
    if payload.get("commit_id") != ev.get("head"):
        out.append("commit_id is not the head the conflict-fix evidence was taken at")
    if payload.get("comments") or payload.get("replies"):
        out.append("a conflict-fix re-approval carries no inline comments or replies: "
                   "anything worth saying goes through the gate")
    return out


def check(number, payload_path, tmp="/tmp"):
    payload = json.load(open(payload_path))
    try:
        view = json.load(open(os.path.join(tmp, f"pr-{number}-view.json")))
    except (FileNotFoundError, ValueError):
        view = {}
    try:
        mode = open(os.path.join(tmp, f"pr-{number}-mode")).read().strip()
    except FileNotFoundError:
        mode = ""
    paths = [f.get("path", "") for f in view.get("files") or []]
    return (check_ascii(payload)
            + check_gate(payload, os.path.join(tmp, f"pr-{number}-draft.json"))
            + check_source_b(payload, tmp, number, mode, paths)
            + check_source_c(payload, tmp, number, paths)
            + check_ac(payload, view)
            + check_reapproval(payload, tmp, number, mode))


def selftest():
    with tempfile.TemporaryDirectory() as tmp:
        def put(name, data):
            with open(os.path.join(tmp, name), "w") as f:
                f.write(data if isinstance(data, str) else json.dumps(data))
        c1 = {"path": "a.ts", "line": 3, "side": "RIGHT", "body": "Fine nit."}
        c2 = {"path": "b.ts", "line": 9, "side": "RIGHT", "body": "Another."}
        put("pr-7-view.json", {"title": "[ABC-1] Port tests", "body": "x",
                               "files": [{"path": "src/a.ts"}]})
        put("pr-7-mode", "full-review\n")
        put("pr-7-draft.json", [c1, c2])
        put("pr-7-b-done", "1\n")
        good = {"body": "Looks right.", "comments": [c1], "source_b": "returned",
                "ac": "unread", "slack_summary": "Approved."}
        put("p.json", good)
        assert check("7", os.path.join(tmp, "p.json"), tmp) == [], "a clean payload passes"

        def fails(change, needle):
            put("p.json", {**good, **change})
            out = check("7", os.path.join(tmp, "p.json"), tmp)
            assert any(needle in p for p in out), (change, out)

        fails({"body": "style‑related"}, "U+2011")
        fails({"comments": [{**c1, "body": "Fine nit — really"}]}, "comment 1")
        fails({"comments": [c1, {**c2, "body": "Reworded."}]}, "not among the drafts")
        fails({"comments": [{"path": "z.ts", "line": 1, "body": "New."}]}, "not among the drafts")
        fails({"source_b": "skipped-prose"}, "not all plain prose")
        fails({"source_b": "timeout"}, "never started")
        fails({"ac": "no-ticket"}, "ABC-1")
        put("p.json", {k: v for k, v in good.items() if k != "source_b"})
        assert any("source_b missing" in p for p in check("7", os.path.join(tmp, "p.json"), tmp))
        # Source C is opt-in: absent is fine until it was started.
        fails({"source_c": "returned"}, "never stamped c-done")
        fails({"source_c": "timeout"}, "never started")
        fails({"source_c": "maybe"}, "not one of")
        put("p.json", {**good, "source_c": "no-model"})
        assert check("7", os.path.join(tmp, "p.json"), tmp) == []
        put("pr-7-sourcec-started", "1\n")
        fails({}, "source_c missing")
        put("p.json", {**good, "source_c": "timeout"})
        assert check("7", os.path.join(tmp, "p.json"), tmp) == []
        put("pr-7-c-done", "1\n")
        counts = {"found": 1, "only": 1, "kept": 0, "only_kept": 0}
        put("p.json", {**good, "source_c": "returned", "source_c_counts": counts})
        assert check("7", os.path.join(tmp, "p.json"), tmp) == []
        fails({"source_c": "returned"}, "source_c_counts is missing")
        fails({"source_c": "returned", "source_c_counts": {**counts, "only_kept": None}}, "missing or incomplete")
        fails({"source_c": "returned", "source_c_counts": {**counts, "only": 2}}, "do not add up")
        os.remove(os.path.join(tmp, "pr-7-sourcec-started"))
        os.remove(os.path.join(tmp, "pr-7-c-done"))
        # A suggestion block is verbatim code: its non-ASCII is allowed.
        sugg = {**c1, "body": "Use this:\n```suggestion\nconst s = 'é'\n```"}
        put("pr-7-draft.json", [c1, c2, sugg])
        put("p.json", {**good, "comments": [sugg]})
        assert check("7", os.path.join(tmp, "p.json"), tmp) == []
        # No comments needs no draft; a subset of the drafts is fine.
        os.remove(os.path.join(tmp, "pr-7-draft.json"))
        put("p.json", {**good, "comments": []})
        assert check("7", os.path.join(tmp, "p.json"), tmp) == []
        put("p.json", good)
        assert any("no " in p and "draft" in p for p in check("7", os.path.join(tmp, "p.json"), tmp))
        # A conflict-fix re-approval needs eligible evidence for this head.
        put("pr-7-mode", "re-review\n")
        re_ok = {"body": "Re-approving.", "event": "APPROVE", "commit_id": "abc", "comments": [],
                 "reapproved": "conflict-fix", "slack_summary": "Re-approved."}
        put("p.json", re_ok)
        assert any("without conflict-fix evidence" in p for p in check("7", os.path.join(tmp, "p.json"), tmp))
        put("pr-7-conflict-fix.json", {"eligible": True, "head": "abc", "reason": "2 clean"})
        assert check("7", os.path.join(tmp, "p.json"), tmp) == []
        for change, needle in (({"event": "COMMENT"}, "posts APPROVE"), ({"commit_id": "def"}, "not the head"),
                               ({"comments": [c1]}, "no inline comments"), ({"reapproved": "x"}, "only kind")):
            put("p.json", {**re_ok, **change})
            assert any(needle in p for p in check("7", os.path.join(tmp, "p.json"), tmp)), change
        put("pr-7-conflict-fix.json", {"eligible": False, "head": "abc", "reason": "new files"})
        put("p.json", re_ok)
        assert any("evidence says no" in p for p in check("7", os.path.join(tmp, "p.json"), tmp))
    assert all_prose(["README.md", "docs/x.rst", "LICENSE"])
    assert not all_prose(["README.md", "CLAUDE.md"])
    assert not all_prose([".github/workflows/ci.md"])
    print("selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        sys.exit(0)
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    problems = check(sys.argv[1], sys.argv[2])
    for p in problems:
        print(f"refused: {p}", file=sys.stderr)
    sys.exit(2 if problems else 0)
