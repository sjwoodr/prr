#!/usr/bin/env python3
"""Single-source review with a local Ollama model.

prr's normal flow is dual-source: a model does its own pass while a subagent
does an independent security pass. This is deliberately NOT that. It runs one
pass (Source A only) against a local Ollama model, for an outage or for trying
a local model as a reviewer, and says so in its report.

Status (2026-09-30): no local model tested so far is accurate enough to trust
(qwen3:8b, qwen2.5-coder:7b, gemma4:26b-a4b-it-qat; no finding survived
checking, with or without capped thinking). The pipeline is kept so a new model
is one --model flag away.

The design point: a local quantized model is weakest at exactly the things a
review payload demands (strict schema, precise line numbers recalled from a
long diff, holding a procedure across many turns). So the model is given one
narrow job -- read one file's hunks, name what is wrong -- and deterministic
code owns everything else:

  - line numbers are pre-computed and handed TO the model, not asked of it
  - output is grammar-constrained by a JSON schema, so it cannot be malformed
  - every anchor is validated against the diff before it can reach GitHub
  - the verdict is derived from severities, not chosen by the model
  - the plain-ASCII prose rule is enforced by substitution, not self-check
  - the approval gate is control flow, so nothing posts without a keypress,
    or, under --save-only, without a separate --post-saved run

Mechanics are reused as-is: setup-review.sh prepares the worktree and
artifacts, post-review.sh validates the head sha, posts, signals chat, and
cleans up. Neither cares which model produced the findings.

Usage:
  prr-local.py <PR> [--model NAME] [--think | --think-budget N] [--silent] [--no-model] [--save-only]
  prr-local.py <PR> --post-saved APPROVE|APPROVE_BARE|REQUEST_CHANGES|COMMENT|DISCARD [--note TEXT]
  prr-local.py --selftest

  --model       Ollama model tag (default: $PRR_LOCAL_MODEL, else Gemma 4 26B)
  --think       Let the model reason before each file's findings. Slower,
                uncapped, and only the findings are kept, never the reasoning.
  --think-budget N  Cap the reasoning at N tokens per call (implies --think).
                At the cap the model is stopped and asked to answer from its
                notes so far, as hearth's Think setting does.
  --silent      Suppress chat signals, passed through to setup-review.sh
  --no-model    Skip inference entirely; exercises the plumbing in seconds
  --save-only   Report and save /tmp/pr-<N>-review.json, keep the worktree, stop.
                For agent harnesses: a human decides, then --post-saved posts.
  --post-saved  Post the saved review with the chosen event. Runs no model.
                post-review.sh refuses if the PR head moved since the review.
                DISCARD posts nothing: it clears the chat :eyes: and removes
                the worktree and saved review (post-review.sh cleanup only).
  --note TEXT   Your own words, appended verbatim to the end of the review body
                (any choice except DISCARD). Also applies at the interactive gate.
                `--note -` reads the text from stdin (use a quoted heredoc).

Every review run also logs to /tmp/prr-local-<N>.log as it goes (tail -f it
from another terminal); cleanup leaves the log in place.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SETUP = os.path.join(SCRIPT_DIR, "setup-review.sh")
POST = os.path.join(SCRIPT_DIR, "post-review.sh")

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
DEFAULT_MODEL = os.environ.get("PRR_LOCAL_MODEL", "gemma4-26b-a4b-32k:latest")

# One context size for every call. Ollama reloads a model whenever num_ctx
# changes, which on the 26B is ~15 s per file. 32768 matches the Modelfile pin
# of the default tag, so the runner the harness (pi) loaded is reused as-is.
NUM_CTX = int(os.environ.get("PRR_LOCAL_NUM_CTX", "32768"))

POST_CHOICES = ("APPROVE", "APPROVE_BARE", "REQUEST_CHANGES", "COMMENT")
# What --post-saved accepts: a posting choice, or DISCARD to drop the review.
SAVED_CHOICES = POST_CHOICES + ("DISCARD",)

# Per-call ceiling. A local box is bandwidth-bound, so a runaway context costs
# minutes rather than cents; splitting a huge file into hunk groups is cheaper
# than one call that thrashes.
MAX_CHUNK_CHARS = 60_000

# Files where a line-by-line read is never worth the wall time. Generated and
# vendored content dominates diff size and produces nothing actionable.
SKIP_PATHS = re.compile(
    r"(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|poetry\.lock|uv\.lock"
    r"|go\.sum|Cargo\.lock|\.terraform\.lock\.hcl|.*\.min\.(js|css)|.*\.snap|.*generated.*)$"
)

# Ollama's cloud models (`name:cloud`, `name-cloud`) ignore `format`, the
# schema and plain "json" alike, and answer in prose, often in a ```json fence.
# They get the schema in the system prompt too, and fences are stripped before
# parsing. Measured on gpt-oss:120b-cloud and gemma4:31b-cloud, 2026-10-13.
CLOUD_MODEL = re.compile(r"[-:]cloud$")
FENCE = re.compile(r"^```(?:json)?\s*|\s*```$")


def system_for(model, system, schema):
    if not CLOUD_MODEL.search(model):
        return system
    return (f"{system}\n\nReply with only a JSON object matching this schema: "
            f"{json.dumps(schema)}")


def parse_content(text):
    return json.loads(FENCE.sub("", text.strip()))


def fast_think(model):
    """What "no thinking" means for a model. gpt-oss can't turn reasoning off:
    with think:false it returns empty content, so it reasons at "low"."""
    return "low" if model.startswith("gpt-oss") else False


FINDINGS_SCHEMA = {
    "type": "object",
    "properties": {
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "severity": {"type": "string", "enum": ["blocker", "notable", "nit"]},
                    "line": {"type": "integer"},
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["severity", "line", "title", "body"],
            },
        },
        "cleared": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["findings"],
}

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {"summary": {"type": "string"}},
    "required": ["summary"],
}

REVIEW_BRIEF = """\
You are reviewing one file from a pull request. Report only defects you can \
justify from the lines shown.

Every line is prefixed with its real line number in the new file, then a marker:
  `+` added by this PR, ` ` unchanged context, `-` removed.

Rules:
- `line` MUST be a number you can see in the prefix of a `+` or ` ` line. Never
  a removed line, never a number you computed yourself.
- Report a finding only if you can name the concrete input or sequence that
  makes it fail. No style preferences, no "consider extracting", no praise.
- severity: `blocker` breaks correctness or security. `notable` is a real bug in
  an edge case. `nit` is small and non-blocking.
- `body` is the comment the author will read. Plain ASCII, no em-dashes. State
  the failure, then the fix. Two or three sentences.
- An empty findings list is the correct answer for a clean file. Say nothing
  rather than inventing something.
- `cleared`: up to three short notes on what you checked and found fine.
"""

DELETED_BRIEF = """\
This file is deleted by the pull request. Every line shown is removed. Use the \
PR overview to see what else changed.

Report a finding only for a concrete problem the deletion itself causes:
- something the PR keeps still depends on what this file provided, or
- behaviour the PR description says is kept is lost with it (an auth check,
  error mapping, validation) and nothing in the overview replaces it.

Rules:
- `line` is always 0: a deleted file has no lines to comment on.
- severity and `body` follow the usual rules: name the failure, then the fix.
  Plain ASCII, no em-dashes. Two or three sentences.
- A deletion the PR intends, with nothing left depending on it, is clean:
  return an empty findings list. Say nothing rather than inventing something.
- `cleared`: up to three short notes on what you checked and found fine.
"""

SUMMARY_BRIEF = """\
Write the summary body for a pull request review, given the findings below.

- Two short paragraphs at most. Plain ASCII, no em-dashes, no bullet lists.
- Say what the change does and whether it is sound.
- Do not re-list the findings. Inline ones are posted as comments, and ones
  marked "(deleted file)" are printed in full right after your summary.
- If there are no findings, say what you checked and that it looks right.
- Write like a colleague, not a report generator. No praise padding.
"""

REREVIEW_BRIEF = """\
A prior review left findings on this pull request. Given those findings and the
diff of what changed since, decide the status of each one.

For each prior finding, output a `line` of 0 and a `body` of the form
"<Fixed|Partially fixed|Not addressed|Unclear>: <what the evidence shows>".
Use severity `notable` for anything not fixed, `nit` for fixed.
Cite the file and line that resolves it, or say why you cannot tell.
Plain ASCII, no em-dashes.
"""

# Enforced rather than requested. The hosted flow asks a model to self-check
# these; a substitution table cannot forget.
ASCII_MAP = {
    "—": " - ", "–": "-", "→": "->", "⇒": "=>",
    "←": "<-", "↔": "<->", "•": "-", "…": "...",
    "“": '"', "”": '"', "‘": "'", "’": "'",
    " ": " ", "≤": "<=", "≥": ">=",
}


def ascii_clean(text):
    """Force the plain-ASCII prose rule, then drop anything still non-ASCII."""
    for bad, good in ASCII_MAP.items():
        text = text.replace(bad, good)
    text = re.sub(r"(?i)footgun", "sharp edge", text)
    return text.encode("ascii", "ignore").decode("ascii")


def run(cmd, check=True, capture=True):
    return subprocess.run(
        cmd, check=check, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def ollama_chat(model, system, user, schema, num_ctx, think=False, stats=None,
                budget=0, extra=None):
    """One non-streaming call with schema-constrained output.

    `think: false` is dropped on a retry: thinking models spend minutes of a
    bandwidth-bound box on reasoning, but older builds reject the field
    outright. `think: true` (--think) is never dropped silently. The reasoning
    arrives apart from the schema-constrained content; its length goes into
    `stats`, and the text itself is discarded. With a `budget` the reasoning is
    capped (see ollama_chat_budgeted); without one, nothing stops a long think
    short of the request timeout. `extra` messages follow the user's.
    """
    if think and budget:
        return ollama_chat_budgeted(model, system, user, schema, num_ctx, budget, stats)
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_for(model, system, schema)},
            {"role": "user", "content": user},
            *(extra or []),
        ],
        "stream": False,
        "format": schema,
        "think": think or fast_think(model),
        # No num_thread: it is a load-time option, so setting it would force a
        # reload against every client that doesn't, and the model runs on the GPU.
        "options": {"temperature": 0.15, "num_ctx": num_ctx},
    }
    for attempt in (1, 2):
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/chat",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=1800) as resp:
                payload = json.load(resp)
            if stats is not None:
                stats["thinking_chars"] = len(payload["message"].get("thinking") or "")
            return parse_content(payload["message"]["content"])
        except urllib.error.HTTPError as exc:
            if attempt == 1 and body.get("think") is False:
                body.pop("think")  # older Ollama: unknown field
                continue
            sys.exit(f"ollama error {exc.code}: {exc.read().decode()[:300]}")
        except json.JSONDecodeError as exc:
            sys.exit(f"ollama returned unparseable content: {exc}")


def consume_thinking(lines, budget):
    """Read streamed /api/chat lines until the reasoning reaches `budget` chunks
    (Ollama streams about one token per chunk). Returns (notes, content, cut)."""
    notes, content, tokens = [], [], 0
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        data = json.loads(raw)
        if data.get("error"):
            raise RuntimeError(data["error"])
        message = data.get("message") or {}
        if message.get("thinking"):
            notes.append(message["thinking"])
            tokens += 1
            if tokens >= budget:
                return "".join(notes), "", True
        if message.get("content"):
            content.append(message["content"])
    return "".join(notes), "".join(content), False


def ollama_chat_budgeted(model, system, user, schema, num_ctx, budget, stats):
    """Budget forcing, as in hearth's thinking replies: stream with thinking on,
    hang up at `budget` reasoning tokens, then ask again with thinking off and
    the reasoning so far handed back as notes. A model that finishes under the
    budget answers in the first call."""
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_for(model, system, schema)},
            {"role": "user", "content": user},
        ],
        "stream": True,
        "format": schema,
        "think": True,
        "options": {"temperature": 0.15, "num_ctx": num_ctx},
    }
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        # Leaving the `with` closes the connection, which stops generation.
        with urllib.request.urlopen(req, timeout=1800) as resp:
            notes, content, cut = consume_thinking(resp, budget)
    except urllib.error.HTTPError as exc:
        sys.exit(f"ollama error {exc.code}: {exc.read().decode()[:300]}")
    except RuntimeError as exc:
        sys.exit(f"ollama error: {exc}")
    if stats is not None:
        stats["thinking_chars"] = len(notes)
        stats["cut"] = cut
    if not cut:
        try:
            return parse_content(content)
        except json.JSONDecodeError as exc:
            sys.exit(f"ollama returned unparseable content: {exc}")
    answer_now = {
        "role": "user",
        "content": "(Your private reasoning so far, not shown to me:)\n"
                   f"{notes}\n\nThinking time is up. Give your findings now.",
    }
    return ollama_chat(model, system, user, schema, num_ctx, extra=[answer_now])


def split_diff(diff_text):
    """Per-file annotated hunks plus the set of anchorable line numbers.

    Returns {path: {"text": annotated, "lines": {int, ...}}}. Anchorable means
    present on the right side of the diff, which is what GitHub accepts for an
    inline comment; removed lines are shown to the model but never offered as
    an anchor.
    """
    files = {}
    path = None
    new_line = 0
    usable = False
    in_hunk = False

    for raw in diff_text.splitlines():
        if raw.startswith("diff --git "):
            match = re.search(r" b/(.+)$", raw)
            path = match.group(1) if match else None
            usable = bool(path) and not SKIP_PATHS.search(path)
            in_hunk = False
            if usable:
                files.setdefault(path, {"text": [], "lines": set()})
            continue
        if path is None or not usable:
            continue
        if raw.startswith("@@"):
            match = re.search(r"\+(\d+)", raw)
            new_line = int(match.group(1)) if match else 1
            in_hunk = True
            files[path]["text"].append(f"      | {raw}")
            continue
        # Header sniffing is only safe before the first hunk. Inside one, a
        # removed SQL comment arrives as `--- foo` and an added `++x` as
        # `+++x`; mistaking either for a header desyncs every line number
        # after it, which is the one error this whole design exists to avoid.
        if not in_hunk:
            if raw.startswith("Binary files"):
                files.pop(path, None)
                usable = False
            elif raw.startswith("deleted file mode"):
                # Context only: no right-side lines, so nothing to anchor, but
                # in a removal PR what disappeared is the substance.
                files[path]["deleted"] = True
            continue
        if raw.startswith("\\"):  # "\ No newline at end of file"
            continue

        if raw.startswith("+"):
            files[path]["text"].append(f"{new_line:6}| {raw}")
            files[path]["lines"].add(new_line)
            new_line += 1
        elif raw.startswith("-"):
            files[path]["text"].append(f"      | {raw}")
        else:
            files[path]["text"].append(f"{new_line:6}| {raw}")
            files[path]["lines"].add(new_line)
            new_line += 1

    return {
        p: {"text": "\n".join(v["text"]), "lines": v["lines"],
            "deleted": v.get("deleted", False)}
        for p, v in files.items()
        if v["lines"] or v.get("deleted")
    }


def diff_overview(diff_text):
    """One line per changed file: added, deleted, renamed or modified, and
    whether this pipeline skips it. Each file is reviewed alone, so this is
    the only view a call gets of the rest of the PR."""
    entries, current, in_hunk = [], None, False
    for raw in diff_text.splitlines():
        if raw.startswith("diff --git "):
            match = re.search(r" b/(.+)$", raw)
            current = {"path": match.group(1) if match else "?", "status": "modified"}
            entries.append(current)
            in_hunk = False
            continue
        if current is None or in_hunk:
            continue
        if raw.startswith("@@"):
            in_hunk = True
        elif raw.startswith("new file mode"):
            current["status"] = "added"
        elif raw.startswith("deleted file mode"):
            current["status"] = "deleted"
        elif raw.startswith("rename from "):
            current["status"] = f"renamed from {raw[len('rename from '):]}"
        elif raw.startswith("Binary files"):
            current["binary"] = True
    lines = []
    for e in entries:
        note = ""
        if e.get("binary"):
            note = " (binary, not reviewed)"
        elif SKIP_PATHS.search(e["path"]):
            note = " (generated or lock file, not reviewed)"
        lines.append(f"- {e['status']}: {e['path']}{note}")
    return "PR overview, every changed file:\n" + "\n".join(lines)


def chunk_text(text):
    """Split an oversized file into pieces that each stay under the ceiling."""
    if len(text) <= MAX_CHUNK_CHARS:
        return [text]
    pieces, current = [], []
    size = 0
    for line in text.splitlines(keepends=True):
        if size + len(line) > MAX_CHUNK_CHARS and current:
            pieces.append("".join(current))
            current, size = [], 0
        current.append(line)
        size += len(line)
    if current:
        pieces.append("".join(current))
    return pieces


def parse_setup(output):
    """Pull the fields we need out of setup-review.sh's report."""
    info = {}
    for key, dest in (("repo", "repo"), ("head sha", "sha"), ("MODE", "mode")):
        match = re.search(rf"^\s*{re.escape(key)}:\s*(\S+)", output, re.M)
        if match:
            info[dest] = match.group(1)
    missing = {"repo", "sha", "mode"} - info.keys()
    if missing:
        sys.exit(f"could not parse setup output, missing: {', '.join(sorted(missing))}")
    return info


def review_files(model, chunks, pr_context, no_model, think=False, budget=0):
    """The map phase: one call per file, findings validated on the way out."""
    findings = []
    cleared = []
    dropped = 0
    total = len(chunks)

    for index, (path, data) in enumerate(sorted(chunks.items()), start=1):
        if no_model:
            print(f"  [{index}/{total}] {path} (skipped, --no-model)")
            continue
        for piece in chunk_text(data["text"]):
            started = time.time()
            stats = {}
            result = ollama_chat(
                model,
                DELETED_BRIEF if data["deleted"] else REVIEW_BRIEF,
                f"{pr_context}\n\nFile: {path}"
                f"{' (deleted by this PR)' if data['deleted'] else ''}\n\n{piece}",
                FINDINGS_SCHEMA,
                NUM_CTX,
                think=think,
                stats=stats,
                budget=budget,
            )
            kept = 0
            for item in result.get("findings", []):
                # The model never names the file: it reviewed one, and trusting
                # it to echo the path back is a failure mode with no upside.
                # A deleted file's findings have no anchor (line None) and go
                # in the review body instead of inline.
                if data["deleted"]:
                    line = None
                elif item.get("line") in data["lines"]:
                    line = item["line"]
                else:
                    dropped += 1
                    continue
                findings.append({
                    "severity": item.get("severity", "nit"),
                    "path": path,
                    "line": line,
                    "title": ascii_clean(item.get("title", "")).strip(),
                    "body": ascii_clean(item.get("body", "")).strip(),
                })
                kept += 1
            cleared.extend(ascii_clean(c) for c in result.get("cleared", [])[:3])
            thought = (f", thought {stats['thinking_chars']} chars"
                       f"{' (cut at budget)' if stats.get('cut') else ''}"
                       if think else "")
            print(f"  [{index}/{total}] {path}: {kept} kept, "
                  f"{time.time() - started:.0f}s{thought}")

    order = {"blocker": 0, "notable": 1, "nit": 2}
    findings.sort(key=lambda f: (order.get(f["severity"], 3), f["path"], f["line"] or 0))
    return findings, cleared, dropped


def where(finding):
    """path:line, or the path marked deleted for a finding with no anchor."""
    if finding["line"] is None:
        return f"{finding['path']} (deleted file)"
    return f"{finding['path']}:{finding['line']}"


def build_summary(model, pr_context, findings, no_model):
    if no_model:
        return "Local pipeline check, no model pass was run."
    digest = "\n".join(
        f"- {f['severity']}: {where(f)} {f['title']}" for f in findings
    ) or "(no findings)"
    result = ollama_chat(
        model, SUMMARY_BRIEF, f"{pr_context}\n\nFindings:\n{digest}",
        SUMMARY_SCHEMA, NUM_CTX,
    )
    return ascii_clean(result.get("summary", "")).strip()


def gate(verdict, count, mode):
    """Interactive choice. Non-interactive runs report only, never post."""
    if mode == "self-review":
        print("\nself-review: nothing is posted. Report above.")
        return "none"
    if not sys.stdin.isatty():
        print("\nnot a tty: reporting only, nothing posted.")
        return "none"

    if verdict == "APPROVE":
        options = [("APPROVE", f"approve with {count} inline comments"),
                   ("APPROVE_BARE", "approve, no inline comments"),
                   ("COMMENT", f"comment only ({count} comments), no approval"),
                   ("none", "post nothing")]
    else:
        options = [("REQUEST_CHANGES", f"request changes with {count} comments"),
                   ("COMMENT", f"comment only ({count} comments), do not block"),
                   ("none", "post nothing")]

    print()
    for number, (_, label) in enumerate(options, start=1):
        print(f"  {number}) {label}")
    while True:
        choice = input(f"\nchoice [1-{len(options)}]: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(options):
            return options[int(choice) - 1][0]
        print("pick a number from the list.")


def selftest():
    """Assert the line arithmetic, including the lines that look like headers.

    Run with --selftest. No framework, no network, no PR needed.
    """
    diff = (
        "diff --git a/q.sql b/q.sql\n"
        "index 111..222 100644\n"
        "--- a/q.sql\n"
        "+++ b/q.sql\n"
        "@@ -10,3 +10,4 @@ context\n"
        " select 1;\n"
        "--- legacy note\n"          # a removed `-- legacy note`
        "+++x = 1;\n"                # an added `++x = 1;`
        "+select 2;\n"
        "diff --git a/pnpm-lock.yaml b/pnpm-lock.yaml\n"
        "@@ -1,2 +1,2 @@\n"
        "+noise\n"
        "diff --git a/img.png b/img.png\n"
        "Binary files a/img.png and b/img.png differ\n"
    )
    out = split_diff(diff)
    assert set(out) == {"q.sql"}, f"skip/binary handling: {sorted(out)}"
    # 10 context, 11 added (`++x = 1;`), 12 added. The removed line consumes no
    # right-side number. Getting this wrong shifts every later anchor.
    assert out["q.sql"]["lines"] == {10, 11, 12}, out["q.sql"]["lines"]
    assert "    11| +++x = 1;" in out["q.sql"]["text"], out["q.sql"]["text"]
    # A deleted file is kept as context: no anchorable lines, flagged deleted.
    # The overview names every file's status, skipped ones included.
    removal = (
        "diff --git a/old.ts b/old.ts\n"
        "deleted file mode 100644\n"
        "index 111..000\n"
        "--- a/old.ts\n"
        "+++ /dev/null\n"
        "@@ -1,2 +0,0 @@\n"
        "-export const x = 1\n"
        "-export const y = 2\n"
        "diff --git a/a.test.ts b/b.test.ts\n"
        "similarity index 90%\n"
        "rename from a.test.ts\n"
        "rename to b.test.ts\n"
        "diff --git a/new.ts b/new.ts\n"
        "new file mode 100644\n"
        "@@ -0,0 +1 @@\n"
        "+new file mode 100644\n"   # an added line that looks like a header
        "diff --git a/src/generated/g.ts b/src/generated/g.ts\n"
        "@@ -1 +1 @@\n"
        "-a\n"
        "+b\n"
    ) + diff
    out = split_diff(removal)
    assert out["old.ts"]["deleted"] and out["old.ts"]["lines"] == set(), out["old.ts"]
    assert "-export const y = 2" in out["old.ts"]["text"], out["old.ts"]["text"]
    assert not out["new.ts"]["deleted"] and out["new.ts"]["lines"] == {1}
    assert "src/generated/g.ts" not in out and "img.png" not in out, sorted(out)
    overview = diff_overview(removal)
    for expected in ("- deleted: old.ts", "- renamed from a.test.ts: b.test.ts",
                     "- added: new.ts",
                     "- modified: src/generated/g.ts (generated or lock file, not reviewed)",
                     "- modified: img.png (binary, not reviewed)", "- modified: q.sql"):
        assert expected in overview, (expected, overview)
    assert ascii_clean("a—b → c “d”") == 'a - b -> c "d"'
    assert ascii_clean("a Footgun here") == "a sharp edge here"
    # Splits on line boundaries only, so an oversized file yields >1 piece and
    # every line survives exactly once.
    big = ("x" * 80 + "\n") * (MAX_CHUNK_CHARS // 40)
    pieces = chunk_text(big)
    assert len(pieces) > 1 and "".join(pieces) == big, len(pieces)
    # A saved review carries state GitHub must never see; each choice yields
    # only the payload keys, and APPROVE_BARE drops the inline comments.
    state = {"pr": "7", "repo": "o/r", "commit_id": "abc", "mode": "first-review",
             "model": "m", "proposed_verdict": "APPROVE", "summary": "Fine.",
             "findings": [{"severity": "nit", "path": "q.sql", "line": 11,
                           "title": "t", "body": "b"}]}
    keys = {"commit_id", "event", "body", "comments", "slack_summary"}
    for choice in POST_CHOICES:
        payload = build_payload(state, choice)
        assert set(payload) == keys, (choice, sorted(payload))
    bare = build_payload(state, "APPROVE_BARE")
    assert bare["event"] == "APPROVE" and bare["comments"] == [], bare
    full = build_payload(state, "COMMENT")
    assert full["comments"] == [{"path": "q.sql", "line": 11, "side": "RIGHT", "body": "b"}]
    assert "no verdict" in full["slack_summary"], full["slack_summary"]
    # A deleted file's finding (line None) goes in the body, never inline,
    # and survives APPROVE_BARE; a note lands last, verbatim.
    mixed = dict(state, findings=state["findings"] + [
        {"severity": "notable", "path": "old.ts", "line": None,
         "title": "Lost check", "body": "Nothing replaces it."}])
    payload = build_payload(mixed, "APPROVE", note="  Ship it — after the deploy.  ")
    assert payload["comments"] == full["comments"], payload["comments"]
    assert payload["body"] == ("Fine.\n\nOn deleted files:\n- `old.ts`: Lost check. "
                               "Nothing replaces it.\n\nShip it — after the deploy."), payload["body"]
    assert payload["slack_summary"].endswith("approved with 2 comments."), payload
    assert choice_line(mixed, "APPROVE", payload, "x") == (
        "choice: APPROVE  (1 inline comment, 1 deleted-file note in the body, "
        "your note at the end)"), choice_line(mixed, "APPROVE", payload, "x")
    bare = build_payload(mixed, "APPROVE_BARE")
    assert bare["comments"] == [] and "Lost check" in bare["body"], bare
    # The body still carries the deleted-file finding, so chat must not say "looks good".
    assert bare["slack_summary"].endswith("approved with 1 comment."), bare["slack_summary"]
    assert build_payload(state, "COMMENT")["body"] == "Fine.", "no note, body unchanged"
    try:
        build_payload(state, "none")
        raise AssertionError("an unknown choice must not build a payload")
    except ValueError:
        pass
    # Budget forcing: stop at the budget without reading on, and pass a
    # finished-early reply through whole.
    def stream(*parts):
        return [json.dumps({"message": p}).encode() + b"\n" for p in parts]
    long_think = stream(*({"thinking": f"t{i} "} for i in range(10)), {"content": "{}"})
    notes, content, cut = consume_thinking(long_think, 3)
    assert cut and notes == "t0 t1 t2 " and content == "", (notes, content, cut)
    short_think = stream({"thinking": "a"}, {"thinking": "b"},
                         {"content": '{"findings"'}, {"content": ": []}"})
    notes, content, cut = consume_thinking(short_think, 3)
    assert not cut and notes == "ab" and json.loads(content) == {"findings": []}
    try:
        consume_thinking([b'{"error": "model crashed"}\n'], 3)
        raise AssertionError("a streamed error must not be swallowed")
    except RuntimeError:
        pass
    # Cloud models: the schema goes in the prompt, fences come off; local ones unchanged.
    assert system_for("gemma4:31b-cloud", "S", {"a": 1}).endswith('schema: {"a": 1}')
    assert "schema" in system_for("nemotron-3-ultra:cloud", "S", {})
    assert system_for("gemma4-26b-a4b-32k:latest", "S", {"a": 1}) == "S"
    assert parse_content('```json\n{"findings": []}\n```') == {"findings": []}
    assert parse_content(' {"findings": []} ') == {"findings": []}
    assert fast_think("gpt-oss:120b-cloud") == "low" and fast_think("gemma4:31b-cloud") is False
    # post-review.sh removes every /tmp/pr-<N>-* file; the log must not match.
    import fnmatch
    assert not fnmatch.fnmatch(log_path("7"), "/tmp/pr-7-*"), log_path("7")
    print("selftest ok")


def main():
    if "--selftest" in sys.argv:
        return selftest()

    parser = argparse.ArgumentParser()
    parser.add_argument("pr")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--silent", action="store_true")
    parser.add_argument("--no-model", action="store_true")
    parser.add_argument("--save-only", action="store_true")
    parser.add_argument("--think", action="store_true",
                        help="let the model reason before each file's findings (slower)")
    parser.add_argument("--think-budget", type=int, default=0, metavar="N",
                        help="cap the reasoning at N tokens per call; implies --think")
    parser.add_argument("--post-saved", choices=SAVED_CHOICES, metavar="CHOICE")
    parser.add_argument("--note", default="", metavar="TEXT",
                        help="your own words, appended to the end of the review body")
    args = parser.parse_args()
    if args.note == "-":
        # Read from stdin, so a harness can pass the text through a quoted
        # heredoc: backticks and $ inside "..." would be run by the shell.
        args.note = sys.stdin.read()
    if args.note and args.post_saved == "DISCARD":
        parser.error("--note has nothing to attach to: DISCARD posts nothing")
    if args.think_budget < 0:
        parser.error("--think-budget must be positive")
    args.think = args.think or args.think_budget > 0
    if args.post_saved:
        return post_saved(args.pr, args.post_saved, args.note)

    number_match = re.search(r"(\d+)\s*$", args.pr)
    if not number_match:
        sys.exit("could not read a PR number from that argument")
    number = number_match.group(1)
    start_log(number)
    if args.think and not args.no_model and supports_thinking(args.model) is False:
        # The skill asks for a budget by default; a model that can't think
        # reviews without it rather than failing on the first file.
        print(f"note: {args.model} does not support thinking; reviewing without it.")
        args.think, args.think_budget = False, 0

    setup_cmd = [SETUP] + (["--silent"] if args.silent else []) + [args.pr]
    setup = run(setup_cmd, check=False)
    print(setup.stdout, end="")
    if setup.returncode != 0:
        sys.exit(f"setup-review.sh failed ({setup.returncode})")
    info = parse_setup(setup.stdout)

    posted = False
    try:
        view = json.load(open(f"/tmp/pr-{number}-view.json"))
        diff_path = f"/tmp/pr-{number}-diff.txt"
        if info["mode"] == "re-review":
            since = f"/tmp/pr-{number}-since-diff.txt"
            diff_path = since if os.path.exists(since) else diff_path
        diff_text = open(diff_path, encoding="utf-8", errors="replace").read()

        pr_context = (
            f"Pull request: {view.get('title', '')}\n"
            f"Description:\n{(view.get('body') or '(none)')[:4000]}\n\n"
            f"{diff_overview(diff_text)}"
        )

        chunks = split_diff(diff_text)
        if not chunks:
            print("\nnothing reviewable in the diff (generated or binary only).")
        print(f"\nreviewing {len(chunks)} file(s) with {args.model}"
              f"{think_label(args)}, "
              f"single-source (Source A only)\n")

        findings, cleared, dropped = review_files(
            args.model, chunks, pr_context, args.no_model, think=args.think,
            budget=args.think_budget,
        )
        summary = build_summary(args.model, pr_context, findings, args.no_model)

        verdict = ("REQUEST_CHANGES"
                   if any(f["severity"] == "blocker" for f in findings)
                   else "APPROVE")

        print("\n" + "=" * 72)
        print(f"SINGLE-SOURCE local review of #{number} ({info['repo']})")
        print(f"model: {args.model}{think_label(args)}   head: {info['sha'][:12]}   mode: {info['mode']}")
        print("=" * 72)
        for finding in findings:
            print(f"\n[{finding['severity']}] {where(finding)}")
            print(f"  {finding['title']}")
            for line in finding["body"].splitlines():
                print(f"    {line}")
        if not findings:
            print("\nno findings.")
        if cleared:
            print("\nchecked and found fine:")
            for item in cleared:
                print(f"  - {item}")
        if dropped:
            print(f"\n{dropped} finding(s) dropped: line not anchorable in the diff.")
        print(f"\nsummary body:\n{summary}")
        print(f"\nproposed verdict: {verdict}")
        print("\nThis was one pass by a local model. It is weaker than the "
              "dual-source flow:\nverify anything you would not have caught "
              "yourself before posting it.")

        state = {
            "pr": args.pr,
            "repo": info["repo"],
            "commit_id": info["sha"],
            "mode": info["mode"],
            "model": args.model,
            "think": args.think,
            "think_budget": args.think_budget,
            "proposed_verdict": verdict,
            "summary": ascii_clean(summary),
            "findings": findings,
        }

        if args.save_only:
            with open(saved_path(number), "w") as handle:
                json.dump(state, handle, indent=2)
            # The worktree stays for the human's decision; the finally block
            # below must not clean it up.
            posted = True
            print(f"\nsaved {saved_path(number)}. Nothing was posted.")
            print(f"  decide:  prr-local.py {args.pr} --post-saved <CHOICE>  "
                  f"({', '.join(SAVED_CHOICES)})")
            print("  DISCARD posts nothing and cleans up.")
            print("  add a note of your own to any other choice: it goes at the "
                  "end of the review body (--note TEXT, or --note - from stdin).")
            return

        choice = gate(verdict, len(findings), info["mode"])
        if choice == "none":
            return
        code = post_payload(state, choice, number, args.note)
        if code != 0:
            sys.exit(f"post-review.sh failed ({code})")
        posted = True
    finally:
        # Cleanup is unconditional in prr, and a half-posted run must still
        # remove the worktree. post-review.sh with no payload does that.
        if not posted:
            run([POST, args.pr], check=False, capture=False)


def supports_thinking(model):
    """Whether Ollama lists `thinking` among the model's capabilities. Ollama
    rejects think:true for a model without it, which would end the run on the
    first file. None when it can't tell (older Ollama, model not pulled)."""
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/show",
        data=json.dumps({"model": model}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            caps = json.load(resp).get("capabilities")
    except (urllib.error.URLError, OSError, ValueError):
        return None
    return None if caps is None else "thinking" in caps


def think_label(args):
    if not args.think:
        return ""
    return f" (thinking, <={args.think_budget} tokens)" if args.think_budget else " (thinking, uncapped)"


class Tee:
    """Every line to the terminal (or whatever launched us) and to a log file,
    flushed as it goes. A killed run keeps its progress, and a harness that
    only shows output when the script ends can be followed with tail -f."""

    def __init__(self, stream, log):
        self.stream, self.log = stream, log

    def write(self, text):
        self.stream.write(text)
        self.stream.flush()
        self.log.write(text)
        self.log.flush()

    def flush(self):
        self.stream.flush()
        self.log.flush()


def log_path(number):
    return f"/tmp/prr-local-{number}.log"


def start_log(number):
    """Log a review run to /tmp/prr-local-<N>.log. Deliberately outside the
    /tmp/pr-<N>-* prefix post-review.sh sweeps: the log is most useful after a
    run that failed or was killed, which is exactly when cleanup has run."""
    path = log_path(number)
    log = open(path, "w", encoding="utf-8")
    sys.stdout = Tee(sys.stdout, log)
    sys.stderr = Tee(sys.stderr, log)
    print(f"log: {path}   started {time.strftime('%Y-%m-%d %H:%M:%S')}")


def saved_path(number):
    return f"/tmp/pr-{number}-review.json"


def build_payload(state, choice, note=""):
    """The reviews-endpoint payload for one choice, plus post-review.sh's
    slack_summary. Only these keys: the saved state carries more, and anything
    extra would be sent to GitHub."""
    if choice not in POST_CHOICES:
        raise ValueError(f"choice must be one of {', '.join(POST_CHOICES)}")
    event = "APPROVE" if choice == "APPROVE_BARE" else choice
    comments = [] if choice == "APPROVE_BARE" else [
        {"path": f["path"], "line": f["line"], "side": "RIGHT", "body": f["body"]}
        for f in state["findings"] if f["line"] is not None
    ]
    # Findings on deleted files have no line to hang on, so they go in the
    # body, which APPROVE_BARE keeps: it drops inline comments, not the body.
    body = state["summary"]
    general = [f for f in state["findings"] if f["line"] is None]
    if general:
        body += "\n\nOn deleted files:\n" + "\n".join(
            f"- `{f['path']}`: {f['title']}. {f['body']}" for f in general)
    if note.strip():
        # The human's own words: verbatim, not ascii_clean'd.
        body += "\n\n" + note.strip()
    # Deleted-file findings count as comments for chat: they are in the body,
    # and "looks good" with no hint of them would undersell the review.
    count = len(comments) + len([f for f in state["findings"] if f["line"] is None])
    noun = "comment" if count == 1 else "comments"
    slack = {
        "APPROVE": f"Reviewed it, looks good, approved with {count} {noun}.",
        "REQUEST_CHANGES": f"Took a look, left {count} {noun} to sort out.",
        "COMMENT": f"Read through it, left {count} {noun}, no verdict yet.",
    }[event]
    if event == "APPROVE" and not count:
        slack = "Reviewed it, looks good to me, approved."
    return {
        "commit_id": state["commit_id"],
        "event": event,
        "body": body,
        "comments": comments,
        "slack_summary": ascii_clean(slack),
    }


def choice_line(state, choice, payload, note):
    """Name the choice outright, with everything the review carries. A harness
    model relaying "inline comments=0" alone called a plain APPROVE "bare"."""
    notes = len([f for f in state["findings"] if f["line"] is None])
    parts = [f"{len(payload['comments'])} inline comment"
             f"{'' if len(payload['comments']) == 1 else 's'}"]
    if notes:
        parts.append(f"{notes} deleted-file note{'' if notes == 1 else 's'} in the body")
    if note.strip():
        parts.append("your note at the end")
    return f"choice: {choice}  ({', '.join(parts)})"


def post_payload(state, choice, number, note=""):
    """Write the payload and hand it to post-review.sh, which checks the head
    sha, posts, signals chat and removes the worktree."""
    payload_path = f"/tmp/pr-{number}-post.json"
    payload = build_payload(state, choice, note)
    print(choice_line(state, choice, payload, note))
    with open(payload_path, "w") as handle:
        json.dump(payload, handle, indent=2)
    return run([POST, state["pr"], payload_path, state["repo"]],
               check=False, capture=False).returncode


def post_saved(pr, choice, note=""):
    """The second half of --save-only: no model, just the saved findings."""
    number_match = re.search(r"(\d+)\s*$", pr)
    if not number_match:
        sys.exit("could not read a PR number from that argument")
    number = number_match.group(1)
    if choice == "DISCARD":
        # Cleanup-only mode: nothing posted, :eyes: cleared, worktree and the
        # saved review (a /tmp/pr-<N>-* artifact) removed.
        sys.exit(run([POST, pr], check=False, capture=False).returncode)
    try:
        state = json.load(open(saved_path(number)))
    except FileNotFoundError:
        sys.exit(f"no saved review at {saved_path(number)}: run with --save-only first")
    if state.get("mode") == "self-review":
        sys.exit("this was a self-review: prr never posts those.")
    code = post_payload(state, choice, number, note)
    if code == 0:
        # post-review.sh's cleanup usually removed it already (it clears every
        # /tmp/pr-<N>-* artifact); this catches a run where it didn't.
        try:
            os.remove(saved_path(number))
        except FileNotFoundError:
            pass
    sys.exit(code)


if __name__ == "__main__":
    main()
