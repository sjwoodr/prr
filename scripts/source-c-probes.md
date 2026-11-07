
## Self-review addendum: probe, don't only read

This is the author's own PR, so the author has already reasoned about it. A
second pass that only reasons shares their blind spots. On this review, the
"read only; do not modify files or run tests" rule above is lifted, inside
these limits:

- Make your own probe checkout and work only there and in a scratch
  directory: `git -C /tmp/pr-{{N}}-wt worktree add --detach
  /tmp/pr-{{N}}-probe HEAD`. Never modify `/tmp/pr-{{N}}-wt`; the other
  passes are reading it. Remove the probe checkout when you finish (`git -C
  /tmp/pr-{{N}}-wt worktree remove --force /tmp/pr-{{N}}-probe`).
- No pushes, no commits outside the probe checkout, no calls to deployed
  services or live servers, no credentials. Installing the repository's
  locked dependencies into the probe checkout is fine when a probe cannot run
  without them; prefer a single test file or a small script over a full
  suite.
- If a probe cannot run (dependencies will not install, it needs a live
  service), say which and why in a `cleared` entry. Do not fall back to
  reasoning and present it as probed.

Run at least these, and fold the results into the lenses above:

1. Tests can fail (lens 6, executed). For each test the PR adds or edits:
   revert the production change it pins in the probe checkout and run the
   test; it must fail. Then run it against empty or degenerate input (no
   files, empty list, zero rows, a stub that does nothing); it must fail or
   assert a positive result. A test that passes in either run is a finding.
2. The bug class (lenses 4 and 7). Name in one line the mechanism the change
   fixes or alters (for example "a path filter applied to an absolute path",
   "an algorithm the new dependency version removed"). Search the whole
   repository for every other instance of that mechanism, starting with the
   same function, and check each. An unfixed sibling is a finding.
3. Risky inputs (lenses 4 and 8). For each input class the change depends on
   (path or directory shapes, empty or partial data, an older peer or
   server, the previous dependency version), build the smallest fixture,
   local server or script that exercises it and run the changed code against
   it. Report what happened.

For a finding a probe produced, set `verified` to `probed` and put the
command and the relevant output in `evidence`.
