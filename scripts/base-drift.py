#!/usr/bin/env python3
"""base-drift.py -- what a re-review's file-scoped since-diff cannot show.

  base-drift.py <pr-number> <worktree> <prior-sha> [<base-oid>]
  base-drift.py --selftest

setup-review.sh runs it in a re-review. The since-diff is scoped to the PR's
own files, so a merge of the base branch adds no noise to it. That scoping
also hides the one way such a merge hurts a PR without touching it: changing
or deleting something the PR's files depend on (a script that reads a path
the merge deleted, a test that imports a module the merge rewrote).

It does two things:

  - splits the commits since the prior review into the author's own work,
    merge commits, and commits that came in from the base branch (needs
    <base-oid> and full history; a shallow checkout reports "unknown");
  - lists every path that changed since the prior review outside the PR's
    files, and flags the ones the PR's files mention: by full path, by file
    name, or by a stem of 6+ characters. Names every package has
    (package.json, index.ts, ...) count only by full path.

A mention is a lead, not proof: a text match can be a false alarm, and a path
built at runtime can slip past it. Writes /tmp/pr-<N>-drift.txt and prints
short summary lines for setup-review.sh. Always exits 0.

Author: Steve Woodruff (@sjwoodr)
SPDX-License-Identifier: MIT
"""
import json
import os
import subprocess
import sys
import tempfile

GENERIC_NAMES = {"package", "index", "README", "CHANGELOG", "tsconfig", "__init__"}


def git(wt, *args):
    return subprocess.run(["git", "-C", wt, *args], check=True, capture_output=True,
                          text=True).stdout


def split_commits(wt, prior, base):
    """(author, merges, via_base) since `prior`, or None when it cannot tell."""
    if not base or os.path.exists(os.path.join(wt, ".git", "shallow")):
        return None
    try:
        total = int(git(wt, "rev-list", "--count", f"{prior}..HEAD"))
        own = ["rev-list", "--count", f"{prior}..HEAD", "--not", base]
        author = int(git(wt, *own, "--no-merges"))
        merges = int(git(wt, *own, "--merges"))
    except (subprocess.CalledProcessError, ValueError):
        return None
    return author, merges, total - author - merges


def drift(wt, prior, pr_files):
    """[(status, path, mention-or-None)] for changes outside the PR's files."""
    rows = []
    for line in git(wt, "diff", "--name-status", "--no-renames", prior, "HEAD").splitlines():
        status, path = line.split("\t", 1)
        if path not in pr_files:
            rows.append([status, path, None])
    texts = {}
    for f in sorted(pr_files):
        try:
            with open(os.path.join(wt, f), encoding="utf-8", errors="replace") as fh:
                texts[f] = fh.read().splitlines()
        except OSError:  # removed by the PR, or not a regular file
            pass
    for row in rows:
        path = row[1]
        name = path.rsplit("/", 1)[-1]
        stem = name.rsplit(".", 1)[0]
        tokens = [path]
        if stem not in GENERIC_NAMES:
            tokens += [name] + ([stem] if len(stem) >= 6 else [])
        row[2] = next((f"{f}:{i} ({t})" for t in tokens for f, lines in texts.items()
                       for i, text in enumerate(lines, 1) if t in text), None)
    return rows


def report(number, wt, prior, base, pr_files, out):
    split = split_commits(wt, prior, base)
    rows = drift(wt, prior, pr_files)
    hits = [r for r in rows if r[2]]
    with open(out, "w") as fh:
        fh.write(f"# Paths changed since {prior[:9]} outside the PR's files"
                 f" ({len(rows)}), mentioned ones first.\n")
        for status, path, where in sorted(rows, key=lambda r: (r[2] is None, r[1])):
            fh.write(f"{status}\t{path}" + (f"\t<- mentioned at {where}" if where else "") + "\n")
    if split:
        a, m, b = split
        print(f"  commits split:   {a} by the author, {m} merge(s), {b} from the base branch")
    else:
        print("  commits split:   unknown (shallow checkout or no base commit)")
    deleted = [r[1] for r in hits if r[0] == "D"]
    print(f"  base drift:      {len(rows)} path(s) changed outside the PR, {len(hits)} of them"
          f" mentioned by its files{f', {len(deleted)} DELETED' if deleted else ''} -> {out}")
    for status, path, where in hits[:8]:
        print(f"    {status} {path}  <- {where}")
    if len(hits) > 8:
        print(f"    ... {len(hits) - 8} more in {out}")


def selftest():
    with tempfile.TemporaryDirectory() as wt:
        def run(*a):
            return git(wt, "-c", "user.name=t", "-c", "user.email=t@t", *a)
        def write(path, text):
            with open(os.path.join(wt, path), "w") as fh:
                fh.write(text)
        run("init", "-q", "-b", "main")
        os.mkdir(os.path.join(wt, "app"))
        write("data.receipt.json", "{}\n"); write("other.txt", "x\n"); write("app/package.json", "{}\n")
        run("add", "."); run("commit", "-qm", "base")
        run("checkout", "-qb", "pr")
        write("tool.py", 'RECEIPT = "data.receipt.json"\n# reads package.json\n')
        run("add", "."); run("commit", "-qm", "pr")
        prior = run("rev-parse", "HEAD").strip()
        run("checkout", "-q", "main")
        run("rm", "-q", "data.receipt.json"); write("other.txt", "y\n"); write("app/package.json", "{1}\n")
        run("add", "."); run("commit", "-qm", "base moves")
        base = run("rev-parse", "HEAD").strip()
        run("checkout", "-q", "pr"); run("merge", "-q", "--no-edit", "main")
        assert split_commits(wt, prior, base) == (0, 1, 1), split_commits(wt, prior, base)
        rows = {p: (s, w) for s, p, w in drift(wt, prior, {"tool.py"})}
        assert rows["data.receipt.json"][0] == "D" and rows["data.receipt.json"][1], rows
        assert rows["other.txt"][1] is None, rows  # never mentioned
        assert rows["app/package.json"][1] is None, rows  # generic name, no full-path match
    print("base-drift selftest: ok")


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__.split("\n\n")[1])
    number, wt, prior = sys.argv[1:4]
    base = sys.argv[4] if len(sys.argv) == 5 else ""
    try:
        with open(f"/tmp/pr-{number}-view.json") as fh:
            pr_files = {f["path"] for f in json.load(fh)["files"]}
        report(number, wt, prior, base, pr_files, f"/tmp/pr-{number}-drift.txt")
    except Exception as e:  # noqa: BLE001 - evidence only; never fail setup
        print(f"  base drift:      not checked ({e})")


if __name__ == "__main__":
    main()
