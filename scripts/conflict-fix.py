#!/usr/bin/env python3
"""conflict-fix.py -- evidence for re-approving a merge-conflict fix.

  conflict-fix.py <pr-number> <owner/repo> <worktree>
  conflict-fix.py --selftest

Opt-in (PRR_REAPPROVE_CONFLICT_FIX=1); setup-review.sh runs it in a re-review.
The case: you approved a PR, it later conflicted with its base branch, the
author resolved the conflicts (a merge of the base or a rebase onto it), and
the push dismissed your approval. Nothing you approved changed, so the
re-review can re-approve without the gate. Whether the push really was only a
conflict fix is the model's call (prr SKILL.md, "Re-approving a conflict
fix"); this script gathers the facts it decides on, and the hard limits
around that call, which no classification can override:

  - your latest review was an APPROVE that GitHub then dismissed;
  - no check that passed on the approved commit fails on the new head
    (running ones are ignored, and so is one that was already failing);
  - the PR touches the same files as at the approval, all of them text.

Then it replays the approved version onto the new base with a 3-way merge
(base side: where the approved commit forked from the base branch; theirs:
where the new head forks from it now) and compares each PR file with the
new head. Each file gets one tag:

  clean      the new head is exactly the merge result
  resolved   it is the merge result except in its conflict regions, which
             hold only lines taken from one side or the other
  new-lines  conflict regions hold lines from neither side
  differs    it changed outside any conflict region (new work, or a change
             forced by the base, e.g. a rename landing in main)

Writes /tmp/pr-<N>-conflict-fix.json (the verdict post-review.sh checks) and
/tmp/pr-<N>-conflict-fix.txt (each file's evidence, for the model to read),
and prints a short summary. Always exits 0; anything it cannot establish
makes the PR "not eligible", which leaves the ordinary gated re-review.

Author: Steve Woodruff (@sjwoodr)
SPDX-License-Identifier: MIT
"""
import difflib
import json
import os
import subprocess
import sys
import tempfile

FAILED = {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}
MARK = 7  # git merge-file's default conflict marker size
CAP = 300  # diff lines of evidence per file; a regenerated file can run to thousands


def git(wt, *args, check=True):
    r = subprocess.run(["git", "-C", wt, *args], capture_output=True)
    if check and r.returncode:
        raise RuntimeError(f"git {' '.join(args[:2])}: {r.stderr.decode(errors='replace').strip()[:200]}")
    return r


def gh_json(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"gh {' '.join(args[:2])}: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout)


def blob(wt, rev, path):
    """File content at rev as bytes, or None when the file is absent there."""
    r = git(wt, "show", f"{rev}:{path}", check=False)
    return r.stdout if r.returncode == 0 else None


def is_text(data):
    if data is None:
        return True
    if b"\0" in data:
        return False
    try:
        data.decode()
        return True
    except UnicodeDecodeError:
        return False


def lines(data):
    return [] if data is None else data.decode().splitlines(keepends=True)


def merge3(ours, base, theirs):
    """git merge-file of three versions: (merged lines with markers, conflicts)."""
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for name, data in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = os.path.join(d, name)
            with open(p, "wb") as f:
                f.write(data or b"")
            paths.append(p)
        r = subprocess.run(["git", "merge-file", "-p", "-L", "approved", "-L", "fork", "-L", "base",
                            *paths], capture_output=True)
        if r.returncode < 0 or r.returncode > 127:
            raise RuntimeError("git merge-file failed")
        return r.stdout.decode().splitlines(keepends=True), r.returncode


def segments(merged):
    """Split merge-file output into ("clean", lines) and ("conflict", ours, theirs)."""
    out, clean, i = [], [], 0
    while i < len(merged):
        if merged[i].startswith("<" * MARK + " "):
            out.append(("clean", clean))
            clean, ours, theirs, side = [], [], [], "ours"
            i += 1
            while i < len(merged) and not merged[i].startswith(">" * MARK + " "):
                if merged[i].startswith("=" * MARK) and merged[i].strip() == "=" * MARK:
                    side = "theirs"
                elif side == "ours":
                    ours.append(merged[i])
                else:
                    theirs.append(merged[i])
                i += 1
            out.append(("conflict", ours, theirs))
        else:
            clean.append(merged[i])
        i += 1
    out.append(("clean", clean))
    return out


def find(hay, needle, start):
    if not needle:
        return len(hay)
    for k in range(start, len(hay) - len(needle) + 1):
        if hay[k:k + len(needle)] == needle:
            return k
    return -1


def classify(merged, conflicts, head):
    """Tag one file against its 3-way merge. Returns (tag, new lines)."""
    if not conflicts:
        return ("clean" if merged == head else "differs"), []
    segs = segments(merged)
    pos, new = 0, []
    for k, seg in enumerate(segs):
        if seg[0] == "clean":
            if head[pos:pos + len(seg[1])] != seg[1]:
                return "differs", []
            pos += len(seg[1])
            continue
        # A conflict region: the head's lines up to the next clean segment.
        nxt = segs[k + 1][1] if k + 1 < len(segs) else []
        end = find(head, nxt, pos) if nxt else len(head)
        if end < 0:
            return "differs", []
        sides = set(seg[1]) | set(seg[2])
        new += [l for l in head[pos:end] if l not in sides and l.strip()]
        pos = end
    if pos != len(head):
        return "differs", []
    return ("new-lines", new) if new else ("resolved", [])


def evidence(path, tag, merged, head, new):
    text = [f"=== {path}: {tag}\n"]
    if tag in ("resolved", "new-lines", "differs"):
        # The merge result (conflict markers and all) against the new head:
        # what the author did with each conflict, and anything else changed.
        diff = list(difflib.unified_diff(merged, head, f"{path} (approved, replayed onto the base)",
                                         f"{path} (new head)", n=3))
        text += diff[:CAP]
        if len(diff) > CAP:
            text.append(f"... {len(diff) - CAP} more diff lines cut; compare {path} in the worktree\n")
    if new:
        text.append(f"--- lines in conflict regions from neither side ({len(new)}):\n")
        text += [f"    {l.rstrip()}\n" for l in new[:40]]
    return "".join(text) + ("\n" if text and not text[-1].endswith("\n") else "")


def run(number, repo, wt, tmp="/tmp"):
    prior = json.load(open(os.path.join(tmp, f"pr-{number}-prior-review.json")))["review"]
    head = git(wt, "rev-parse", "HEAD").stdout.decode().strip()
    v = {"pr": int(number), "head": head, "approved": prior.get("commit_id"), "eligible": False,
         "reason": "", "files": {}}

    # `code` is the short form prr-meta records (cf=ineligible-<code>).
    def stop(code, reason):
        v["code"], v["reason"] = code, reason
        return v

    if prior.get("state") != "DISMISSED":
        return stop("not-dismissed", f"your last review is {str(prior.get('state')).lower()}, not a dismissed approval")
    pages = gh_json("api", "--paginate", "--slurp", f"repos/{repo}/issues/{number}/timeline")
    events = [e for page in pages for e in page if e.get("event") == "review_dismissed"]
    hit = next((e for e in reversed(events)
                if (e.get("dismissed_review") or {}).get("review_id") == prior.get("id")), None)
    if not hit or (hit["dismissed_review"].get("state") or "").lower() != "approved":
        return stop("not-approval", "the dismissed review was not an approval")
    if not v["approved"]:
        return stop("no-commit", "the approved commit is unknown")

    def failed(sha):
        pages = gh_json("api", "--paginate", "--slurp", f"repos/{repo}/commits/{sha}/check-runs")
        return {c["name"] for page in pages for c in page.get("check_runs", [])
                if c.get("conclusion") in FAILED}
    # A check already failing on the approved commit was part of what you
    # approved; one that started failing since needs a look.
    broke = sorted(failed(head) - failed(v["approved"]))
    if broke:
        return stop("checks", f"checks failing since your approval: {', '.join(broke[:5])}")

    base = gh_json("pr", "view", str(number), "--repo", repo, "--json", "baseRefName")["baseRefName"]
    # Merge bases need history; a standalone checkout is shallow (no blobs needed).
    if os.path.exists(os.path.join(wt, ".git", "shallow")):
        git(wt, "fetch", "-q", "--unshallow", "--filter=blob:none", "origin", check=False)
    git(wt, "fetch", "-q", "origin", f"+refs/heads/{base}:refs/remotes/origin/{base}", v["approved"])
    old = git(wt, "merge-base", v["approved"], f"origin/{base}").stdout.decode().strip()
    new = git(wt, "merge-base", head, f"origin/{base}").stdout.decode().strip()
    v.update(base=base, fork_old=old, fork_new=new)

    names = lambda a, b: set(git(wt, "diff", "--name-only", "--no-renames", a, b).stdout.decode().split("\n")) - {""}
    before, after = names(old, v["approved"]), names(new, head)
    if before != after:
        added, dropped = sorted(after - before), sorted(before - after)
        return stop("files", "the PR's files changed:"
                    + (f" now also {', '.join(added[:5])}" if added else "")
                    + (f" no longer {', '.join(dropped[:5])}" if dropped else ""))

    report = []
    for path in sorted(after):
        ours, fork, theirs = (blob(wt, r, path) for r in (v["approved"], old, new))
        now = blob(wt, head, path)
        if not all(is_text(x) for x in (ours, fork, theirs, now)):
            return stop("binary", f"{path} is binary")
        # An absent file merges as an empty one, which covers a file the PR
        # adds or deletes and one the base adds or deletes alike.
        merged, conflicts = merge3(ours, fork, theirs)
        tag, new_lines = classify(merged, conflicts, lines(now))
        v["files"][path] = tag
        if tag != "clean":
            report.append(evidence(path, tag, merged, lines(now), new_lines))

    v["eligible"], v["code"] = True, "eligible"
    tags = list(v["files"].values())
    v["reason"] = ", ".join(f"{tags.count(t)} {t}" for t in ("clean", "resolved", "new-lines", "differs")
                            if t in tags) or "no files"
    with open(os.path.join(tmp, f"pr-{number}-conflict-fix.txt"), "w") as f:
        f.write("".join(report) or "every PR file is exactly the approved version replayed onto the base\n")
    return v


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    number, repo, wt = sys.argv[1:4]
    try:
        v = run(number, repo, wt)
    except Exception as e:  # noqa: BLE001 - unknown means a normal, gated re-review
        v = {"pr": int(number), "eligible": False, "code": "error", "reason": f"could not check: {e}"}
    with open(f"/tmp/pr-{number}-conflict-fix.json", "w") as f:
        json.dump(v, f, indent=1)
    print("conflict fix:")
    if v["eligible"]:
        print(f"  candidate:       yes ({v['reason']}), approved {v['approved'][:9]}, head {v['head'][:9]}")
        print(f"  evidence:        /tmp/pr-{number}-conflict-fix.txt")
        print("  next:            classify it (SKILL.md, Re-approving a conflict fix)")
    else:
        print(f"  candidate:       no, {v['reason']}; ordinary re-review")
    return 0


def selftest():
    L = lambda s: [x + "\n" for x in s.split()]
    ours, base, theirs = L("a b c d e"), L("a b c d e"), L("a b c d e")
    m, c = merge3(*("".join(x).encode() for x in (L("a B c d e"), base, L("a b c d E"))))
    assert c == 0 and classify(m, c, L("a B c d E")) == ("clean", [])
    assert classify(m, c, L("a B c X E"))[0] == "differs"
    m, c = merge3(*("".join(x).encode() for x in (L("a B c d e"), ours, L("a Z c d e"))))
    assert c == 1
    assert classify(m, c, L("a B c d e")) == ("resolved", [])
    assert classify(m, c, L("a B Z c d e")) == ("resolved", [])
    assert classify(m, c, L("a Q c d e")) == ("new-lines", ["Q\n"])
    assert classify(m, c, L("a B c d X"))[0] == "differs"
    assert classify(m, c, L("a B c d"))[0] == "differs"
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
