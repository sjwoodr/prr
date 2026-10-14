# TODO

## Beta: prr in other harnesses (pi + Ollama cloud), 2026-10-13

On the `beta` branch. Trial: gpt-oss:120b-cloud in pi on one clean PR (a test
port with nothing to find), scored against Opus /prr on the same PR.

- Round 1 (plain skill): skipped Source B with a made-up reason, said
  "no-ticket" for a linked one, invented findings and line numbers, posted 8
  comments after 5 were approved, non-ASCII.
- Round 2 (with check-payload.py, the setup summary, source-b.sh, the
  checklist): honest and on-procedure, the same APPROVE as Opus, but hollow:
  Source B returned empty JSON after 2 s, Source A read 800 of 1909 diff
  lines and never opened the worktree, the existing review comment went
  unacknowledged.

Open:
- source-b.sh: treat an empty report (no cleared items, no prose) or a run
  under ~30 s as failed, not returned; pass a thinking level (`--thinking high`).
- pi runs: start with `--no-extensions`; round 2 web-searched the internal
  ticket key. The skill should say never to web-search internal identifiers.
- Diligence can't be enforced by the scripts. The real test is a PR with a
  known planted bug; also try a stronger open model (kimi-k3, glm-5.3).
- check-payload.py, the draft lock and PRR_POST=off are worth keeping for any
  model; decide whether they go to main on their own.
- prr-auto's beta branch carries the one line that saves drafts; keep the two
  repos' branches in step.

## Opt-in third pass from a different model family

Sources A and B are both Claude, so they share blind spots. Add an opt-in
Source C: a model from another family, run through Ollama (a cloud-hosted
frontier model such as `glm-5.3:cloud` or `kimi-k3:cloud`, or a local model).

- Run it as a read-only agent that searches the worktree itself, not with
  hand-picked files, e.g. pi:
  `pi -p --no-session --no-mcp --no-extensions --tools read,grep,find,ls --model ollama/<model>`.
  Anything it can read but not search sees only what the caller chose.
- Opt-in only: a flag (`/prr third <PR>`) or an env var naming the model.
  Default off, since it sends the diff to another provider.
- Treat its findings as Source B's are treated: verify each against the code
  before it reaches the gate. In trials, small local models (Gemma 26B,
  gpt-oss 20B) reached wrong conclusions or cited files that do not exist;
  gpt-oss 120B (cloud) checked its claims and got them right. Local models
  are not worth the wait for this.
- Same JSON output contract and wait budget as Source B; record its outcome
  in `prr-meta`.

### Shape: `scripts/source-c.sh <PR>`

A script in this repo, not a dependency on a personal helper, since the
repo has to work for anyone who installs it.

- On when `PRR_SOURCE_C_MODEL` is set (e.g. `ollama/glm-5.3:cloud`), off
  otherwise, like `PRR_SOURCE_B_TIMEOUT` and `PRR_FANOUT`.
- Runs pi read-only in `/tmp/pr-<N>-wt`, with the diff path and the JSON
  contract in the prompt; writes its report to `/tmp/prr-source-c-<N>.json`
  for the review to read. Stamped by the same clock as Source B.
- Needs an agent loop, so pi (or a similar CLI) is a hard dependency.
  `ollama run` alone is chat with no tools: the model would see only the
  pasted diff, which is the hand-picked-context weakness this pass exists to
  avoid. Ollama's API supports tool calls, but driving that loop from bash
  means rewriting pi.
- Missing pi, a refused model (e.g. a free plan) or a timeout: skip Source C,
  say so at the gate, and carry on dual-source. Never block the review.
- Bare single-statement invocation, so it matches the allow-list like the
  other scripts.
- Skipped for plain-prose changes, by the same rule as Source B.
