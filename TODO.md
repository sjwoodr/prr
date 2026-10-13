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
