# pi-pass-common.sh -- shared by source-b.sh and source-c.sh: run one review
# pass as a read-only pi agent, judge whether it really returned, stamp the
# clock. Sourced, never run; it defines functions and exits nothing.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT

# pi_pass_detach <log> <script> <args...>: rerun the calling script in the
# background and return at once. For harnesses whose shell tool has no
# background option of its own (pi): two trial models passed Claude Code's
# `run_in_background` to pi's bash, pi ignored it, and the review sat blocked
# on Source B for 7 minutes with nothing able to stop it.
pi_pass_detach() {
  local log="$1"; shift
  nohup "$@" >"$log" 2>&1 </dev/null &
  echo "started in the background (pid $!); progress in $log"
}

# pi_pass_run <label> <number> <model> <brief> <out> <done-mode>
# Runs pi read-only (read, grep, find, ls: no bash, so no network) on the
# brief, writes the reply to <out>, and stamps <done-mode> (b-done, c-done)
# only for a report that is really there. Returns 1 on failure.
pi_pass_run() {
  local label="$1" number="$2" model="$3" brief="$4" out="$5" done_mode="$6"
  local clock="$PI_PASS_DIR/source-b-clock.sh"
  local thinking="${PRR_PASS_THINKING:-high}" started rc=0 elapsed items prose

  started=$(date +%s)
  # stdin closed: `pi -p` with a non-TTY stdin waits on it forever.
  pi -p --no-session --no-extensions --no-skills --no-context-files \
    --tools read,grep,find,ls --model "$model" --thinking "$thinking" \
    "$brief" </dev/null >"$out" 2>&1 || rc=$?
  if (( rc != 0 )); then
    echo "$label: the agent failed (exit $rc); see $out. Record it as failed." >&2
    return 1
  fi
  elapsed=$(( $(date +%s) - started ))

  # A clean exit is not a report. One trial returned an empty json block after
  # 2 s and was recorded as `returned`. Too fast to have read the diff, or no
  # finding, no cleared item and almost no prose, is a failure: no done stamp.
  local min_seconds="${PRR_PASS_MIN_SECONDS:-30}"
  items=$(grep -cE '"(claim|title)"[[:space:]]*:[[:space:]]*"[^"]' "$out" || true)
  prose=$(wc -c <"$out")
  if (( elapsed < min_seconds )) || (( items == 0 && prose < 400 )); then
    echo "$label: hollow report (${elapsed}s, ${items} findings/cleared, ${prose} bytes); see $out. Record it as failed." >&2
    return 1
  fi

  "$clock" "$done_mode" "$number" >/dev/null
  echo "$label: done in ${elapsed}s, report in $out"
}

# pi_pass_preflight <label> <number> <model>: the checks both passes share.
pi_pass_preflight() {
  local label="$1" number="$2" model="$3"
  [[ "$number" =~ ^[0-9]+$ ]] || { echo "$label: pr-number must be digits, got '$number'" >&2; return 2; }
  [[ -n "$model" ]] || { echo "$label: no model given" >&2; return 2; }
  command -v pi >/dev/null || { echo "$label: pi is not installed" >&2; return 2; }
  [[ -d "/tmp/pr-${number}-wt" && -r "/tmp/pr-${number}-diff.txt" ]] \
    || { echo "$label: run setup-review.sh first" >&2; return 2; }
}
