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
- Done 2026-10-14: source-b.sh fails an empty report or a run under 30 s,
  passes `--thinking high`, closes pi's stdin (`pi -p` with a non-TTY stdin
  waits on it forever), and detaches itself with `--bg`. Both trial models
  passed Claude Code's `run_in_background` to pi's bash, which pi ignores, so
  Source B ran in the foreground and nothing could cap its cost. `--bg` is
  untested in a real pi run yet.
- pi runs: start with `--no-extensions`; round 2 web-searched the internal
  ticket key. The skill should say never to web-search internal identifiers.
  `--no-extensions` is not enough: kimi-k2.7-code, unprompted, curled the
  local SearXNG through pi's bash (a placeholder query, nothing leaked). The
  main session needs bash for the scripts, so only the network can stop it.
- Diligence can't be enforced by the scripts. The real test is a PR with a
  known planted bug; also try a stronger open model (kimi-k3, glm-5.3).
- check-payload.py, the draft lock and PRR_POST=off are worth keeping for any
  model; decide whether they go to main on their own.
- prr-auto's beta branch carries the one line that saves drafts; keep the two
  repos' branches in step.

## Opt-in third pass (Source C): built on beta 2026-10-14, untried

`/prr third <PR>` or `third=<model>`, model from `PRR_SOURCE_C_MODEL` when
bare. Any model: a Claude one runs as a subagent, anything else through
`scripts/source-c.sh` (pi, read-only). Both use `scripts/source-c-brief.md`,
a general review rather than a second security pass, since glm's one useful
find on #1875 was about test coverage. Every Source C finding is verified by
Claude before the gate (kimi's Source B marked two wrong findings
`read-the-code`); the gate names what only Source C found. Clock `c-start`,
`c-check`, `c-done`; `source_c`/`source_c_model` in the payload, checked by
check-payload.py and recorded in prr-meta only when present.

Next:
- First real run: `/prr third=sonnet <PR>` (free) to exercise the subagent
  path end to end, then one pi run with glm-5.3 when there is credit.
- Watch what Source C alone found across runs; if it is nothing, say so in
  the README and stop recommending it.
