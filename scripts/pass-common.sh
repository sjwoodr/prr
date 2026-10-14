# pass-common.sh -- shared by source-b.sh and source-c.sh: run one review pass
# as a read-only agent in an outside harness, judge whether it really returned,
# stamp the clock. Sourced, never run; it defines functions and exits nothing.
#
# Harnesses, in order of preference: pi, opencode, codex. PRR_PASS_HARNESS
# picks one; unset, the first one installed wins. Each runs with no way to
# write or reach the network, from a directory prr creates, never from the PR's
# worktree: opencode and codex read config and instructions from the directory
# they start in, and a PR can add an opencode.json that hands the "read-only"
# agent a shell (tried 2026-10-14 against opencode 2.0.24; the env overrides
# OPENCODE_CONFIG, _CONFIG_CONTENT and _CONFIG_PROJECT_DISABLE were all
# ignored). The PR is read by absolute path.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT

PASS_HARNESSES="pi opencode codex"

# pass_harness: print the harness to use, or fail with the reason.
pass_harness() {
  local h="${PRR_PASS_HARNESS:-}"
  if [[ -n "$h" ]]; then
    case " $PASS_HARNESSES " in
      *" $h "*) ;;
      *) echo "PRR_PASS_HARNESS='$h' is not one of: $PASS_HARNESSES" >&2; return 2 ;;
    esac
    command -v "$h" >/dev/null || { echo "PRR_PASS_HARNESS=$h but $h is not installed" >&2; return 2; }
    echo "$h"; return 0
  fi
  for h in $PASS_HARNESSES; do
    command -v "$h" >/dev/null && { echo "$h"; return 0; }
  done
  echo "none of $PASS_HARNESSES is installed" >&2
  return 2
}

# pass_detach <log> <script> <args...>: rerun the calling script in the
# background and return at once. For harnesses whose shell tool has no
# background option of its own (pi): two trial models passed Claude Code's
# `run_in_background` to pi's bash, pi ignored it, and the review sat blocked
# on Source B for 7 minutes with nothing able to stop it.
pass_detach() {
  local log="$1"; shift
  nohup "$@" >"$log" 2>&1 </dev/null &
  echo "started in the background (pid $!); progress in $log"
}

# The opencode agent prr runs as: everything denied, then the read-only tools,
# and the PR's own /tmp files. Loaded as project config from the run directory.
pass_opencode_config() {
  local number="$1"
  cat <<EOF
{"agents":{"prr-readonly":{"description":"prr read-only review pass","mode":"primary","permissions":[
  {"action":"*","resource":"*","effect":"deny"},
  {"action":"read","resource":"*","effect":"allow"},
  {"action":"grep","resource":"*","effect":"allow"},
  {"action":"glob","resource":"*","effect":"allow"},
  {"action":"list","resource":"*","effect":"allow"},
  {"action":"external_directory","resource":"/tmp/pr-${number}-*","effect":"allow"}]}}}
EOF
}

# pass_run <label> <number> <model> <brief> <out> <done-mode>
# Runs the pass, writes the reply to <out>, and stamps <done-mode> (b-done,
# c-done) only for a report that is really there. Returns 1 on failure.
pass_run() {
  local label="$1" number="$2" model="$3" brief="$4" out="$5" done_mode="$6"
  local clock="$PASS_DIR/source-b-clock.sh"
  local thinking="${PRR_PASS_THINKING:-}" harness started rc=0 elapsed items prose run_dir
  # Unset: high for cloud and hosted models, off for a local Ollama model. Local
  # Gemma 4 thinking without a budget runs away: through pi at "high" it
  # thought for 690 s and returned nothing; "off" reported in 40 s (2026-10-14).
  if [[ -z "$thinking" ]]; then
    if [[ "$model" == ollama/* && ! "$model" =~ [-:]cloud$ ]]; then thinking=off; else thinking=high; fi
  fi

  harness="$(pass_harness)" || { echo "$label: no harness: see above" >&2; return 1; }
  # Inside the /tmp/pr-<N>-* glob, so post-review.sh's cleanup removes it.
  run_dir="$(mktemp -d "/tmp/pr-${number}-${label}-run.XXXXXX")"
  started=$(date +%s)
  # Every harness gets a closed stdin: `pi -p` with a non-TTY stdin waits on
  # it forever, and a permission prompt must fail, not hang.
  case "$harness" in
    pi)
      (cd "$run_dir" && pi -p --no-session --no-extensions --no-skills --no-context-files \
        --tools read,grep,find,ls --model "$model" --thinking "$thinking" \
        "$brief" </dev/null >"$out" 2>&1) || rc=$?
      ;;
    opencode)
      pass_opencode_config "$number" >"$run_dir/opencode.json"
      # Refuse unless the agent really loaded with deny-all first: a config
      # the harness ignored would leave its default agent, which has a shell.
      # The first command in a new directory lists no agents at all (exit 0,
      # "[]"; opencode 2.0.24) while opencode takes the directory in, so ask a
      # few times. The model never runs before the agent shows up, and asking
      # first is also what makes the directory known before `opencode run`.
      local tries=0 loaded=0
      while (( tries++ < 5 )); do
        if (cd "$run_dir" && opencode debug agents </dev/null 2>/dev/null) \
          | jq -e '[.[] | select(.id == "prr-readonly") | .permissions[]
                   | select(.action == "*" and .resource == "*" and .effect == "deny")] | length > 0' >/dev/null 2>&1; then
          loaded=1; break
        fi
        sleep 1
      done
      if (( ! loaded )); then
        echo "$label: opencode did not load the read-only agent; refusing to run it" >&2
        return 1
      fi
      # opencode allows files outside its project by DIRECTORY, so the
      # worktree (/tmp/pr-N-wt/...) matches the rule above but the diff and
      # PR description, which sit directly in /tmp, do not. Copy those two
      # into the run directory rather than opening up all of /tmp.
      local diff="/tmp/pr-${number}-diff.txt" view="/tmp/pr-${number}-view.json"
      cp "$diff" "$run_dir/diff.txt"
      [[ -r "$view" ]] && cp "$view" "$run_dir/view.json"
      local oc_brief="${brief//$diff/$run_dir/diff.txt}"
      oc_brief="${oc_brief//$view/$run_dir/view.json}"
      # Never --auto: it approves whatever is not explicitly denied.
      (cd "$run_dir" && opencode run --agent prr-readonly -m "$model" "$oc_brief" </dev/null 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g' >"$out") || rc=$?
      ;;
    codex)
      # The OS sandbox blocks writes and network for any command the model
      # runs; AGENTS.md is ignored (project_doc_max_bytes=0). An ollama/ model
      # goes through the local Ollama, anything else to codex's own provider.
      local -a provider=()
      [[ "$model" == ollama/* ]] && provider=(--oss --local-provider ollama)
      case "$thinking" in minimal|low|medium|high) ;; off|none) thinking=minimal ;; *) thinking=high ;; esac
      (cd "$run_dir" && codex exec ${provider[@]+"${provider[@]}"} -m "${model#ollama/}" -s read-only \
        --ephemeral --skip-git-repo-check -C "$run_dir" -c project_doc_max_bytes=0 \
        -c model_reasoning_effort="$thinking" -o "$out" "$brief" \
        </dev/null >"$run_dir/codex.log" 2>&1) || rc=$?
      ;;
  esac
  if (( rc != 0 )); then
    echo "$label: the agent failed ($harness, exit $rc); see $out. Record it as failed." >&2
    return 1
  fi
  elapsed=$(( $(date +%s) - started ))

  # A clean exit is not a report. One trial returned an empty json block after
  # 2 s and was recorded as `returned`. Too fast to have read the diff, or no
  # finding, no cleared item and almost no prose, is a failure: no done stamp.
  local min_seconds="${PRR_PASS_MIN_SECONDS:-30}"
  items=$(grep -cE '"(claim|title)"[[:space:]]*:[[:space:]]*"[^"]' "$out" 2>/dev/null || true)
  prose=$(wc -c <"$out" 2>/dev/null || echo 0)
  if (( elapsed < min_seconds )) || (( items == 0 && prose < 400 )); then
    echo "$label: hollow report (${harness}, ${elapsed}s, ${items} findings/cleared, ${prose} bytes); see $out. Record it as failed." >&2
    return 1
  fi

  "$clock" "$done_mode" "$number" >/dev/null
  echo "$label: done in ${elapsed}s via ${harness}, report in $out"
}

# pass_preflight <label> <number> <model>: the checks both passes share.
pass_preflight() {
  local label="$1" number="$2" model="$3"
  [[ "$number" =~ ^[0-9]+$ ]] || { echo "$label: pr-number must be digits, got '$number'" >&2; return 2; }
  [[ -n "$model" ]] || { echo "$label: no model given" >&2; return 2; }
  pass_harness >/dev/null || return 2
  [[ -d "/tmp/pr-${number}-wt" && -r "/tmp/pr-${number}-diff.txt" ]] \
    || { echo "$label: run setup-review.sh first" >&2; return 2; }
}
