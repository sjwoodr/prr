# prr-fanout-common.sh — shared helpers for the prr fan-out backends
# (prr-fanout-tmux.sh and prr-fanout-wezterm.sh). This file is NOT executable;
# each backend `source`s it after setting TAG (its log prefix) and TEST. The
# functions read the caller's globals (TAG, TEST, refs, numbers, done_map) at
# call time, which is how the backends share state with them.
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# TAG, TEST, numbers, and done_map are provided by the sourcing backend at call
# time (bash dynamic scope); shellcheck cannot see those assignments from here.
# shellcheck disable=SC2154

# Parse a PR ref (full URL or bare number) to its number; same rule as
# setup-review.sh / post-review.sh.
prnum() {
  if [[ "$1" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
  else
    echo "$TAG: '$1' is neither a PR URL nor a number." >&2; return 2
  fi
}

# The shell command a single pane runs: $1 = PR ref, $2 = index. In test mode it
# mocks a review (no Claude) by writing its own result file after a staggered
# wait, then idling until the launcher closes it.
pane_cmd() {
  local ref="$1" idx="$2"
  if [[ "$TEST" -eq 1 ]]; then
    local n="${numbers[$idx]}" delay=$(( 3 + idx * 2 ))
    printf 'echo "[TEST MODE] mock review of PR %s; finishing in %ss"; sleep %s; echo "pr=%s status=test comments=%s" > /tmp/prr-fanout-%s.result; echo "[TEST MODE] PR %s result written; waiting for launcher to close this pane"; sleep 600' \
      "$n" "$delay" "$delay" "$n" "$idx" "$n" "$n"
  else
    printf 'PRR_FANOUT_PANE=1 claude "/prr %s"' "$ref"
  fi
}

# PR numbers not yet accounted for (no result file seen yet). Reads numbers + done_map.
remaining() {
  local out=() n
  for n in "${numbers[@]}"; do [[ -n "${done_map[$n]:-}" ]] || out+=("$n"); done
  echo "${out[*]}"
}

# Print the consolidated rollup of every PR's outcome. Reads numbers + done_map.
print_rollup() {
  echo
  echo "===== prr-fanout rollup ====="
  local n
  for n in "${numbers[@]}"; do
    if [[ -n "${done_map[$n]:-}" ]]; then
      echo "  #$n  ${done_map[$n]}"
    else
      echo "  #$n  (no result — still open or aborted)"
    fi
  done
}
