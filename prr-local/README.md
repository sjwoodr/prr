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
