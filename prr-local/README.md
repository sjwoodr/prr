# prr-local: maintainer notes

Kept out of SKILL.md so they do not take up the local model's context.

## Status (2026-09-30)

No local model tested so far is accurate enough to trust. Tried: `qwen3:8b`,
`qwen2.5-coder:7b` and `gemma4:26b-a4b-it-qat`. Across three PRs with
known-good answers, not one finding survived checking. The misses were
judgement, not speed or anchoring: findings that re-raise problems the author's
own comments already handle, or fixes that would break the code. Capped
thinking (`--think-budget`) cut the noise but kept a confident, wrong blocker.
Treat the output as a reading aid and verify every finding before posting. The
skill is kept so the next model can be tried without rebuilding it.

## Why it lives inside prr

It shares prr's setup and posting scripts. An agent harness running a local
model (pi, via a `~/.agents/skills` link) loads it instead of prr, whose
procedure is far too long for a local context window. Claude Code also sees it,
through the `~/.claude/skills/prr-local` link; its description keeps Claude
models from choosing it over prr.

## Flag and timing notes

- `--think-budget 400` lets the model reason for up to 400 tokens per file,
  about 17 s more per file. A model without thinking support in Ollama's
  capabilities (e.g. `qwen3-coder`) skips it with a note.
- Default model `gemma4-26b-a4b-32k:latest`; override with `--model` or
  `$PRR_LOCAL_MODEL`.
- Expect seconds to a minute per file, plus about 15 s if the model has to load.

## How the pipeline works

It splits the diff per file, asks the local model about one file at a time
under a JSON schema, validates every line anchor against the diff, and derives
the verdict from the findings. Every call also gets a one-line-per-file overview
of the whole PR. Deleted files are reviewed as context: their findings have no
line, so they go in the review body under "On deleted files". Having the model
read the whole PR itself costs more and produces worse anchors.
