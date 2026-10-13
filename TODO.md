# TODO

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
