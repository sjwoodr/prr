#!/usr/bin/env bash
# clock-test.sh -- checks source-b-clock.sh's verdicts, including the done
# stamp: a real one ends the wait, garbage or a stale one from an earlier run
# of the same PR does not. Uses a PR number no real review has and removes its
# /tmp files before and after. Run: tests/clock-test.sh
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -u

clock="$(cd "$(dirname "$0")/.." && pwd)/scripts/source-b-clock.sh"
N=999990
fails=0
clean() { rm -f /tmp/pr-${N}-*; }
trap clean EXIT

expect() {
  local name="$1" want="$2" got
  got="$("${@:3}" 2>/dev/null | sed -n 's/^VERDICT=\([a-z]*\).*/\1/p')"
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: want $want, got '${got}'"; fails=$((fails + 1)); fi
}

for pass in b c; do
  pre=""; [[ "$pass" == c ]] && pre="c-"
  clean
  expect "$pass: no start"                nostamp "$clock" "${pre}check" "$N"
  "$clock" "${pre}start" "$N" >/dev/null
  expect "$pass: started, not done"       wait    "$clock" "${pre}check" "$N"
  "$clock" "${pass}-done" "$N" >/dev/null
  expect "$pass: done stamp"              done    "$clock" "${pre}check" "$N"

  clean; "$clock" "${pre}start" "$N" >/dev/null
  echo junk >"/tmp/pr-${N}-${pass}-done"
  expect "$pass: garbage done stamp"      wait    "$clock" "${pre}check" "$N"

  # Stale stamp written after start (start would remove it): check ignores it.
  clean; "$clock" "${pre}start" "$N" >/dev/null
  echo $(( $(date +%s) - 3600 )) >"/tmp/pr-${N}-${pass}-done"
  expect "$pass: done stamp older than start" wait "$clock" "${pre}check" "$N"

  # Stale stamp from an earlier run: start removes it, the new done replaces it.
  clean; echo $(( $(date +%s) - 3600 )) >"/tmp/pr-${N}-${pass}-done"
  "$clock" "${pre}start" "$N" >/dev/null
  if [[ -e "/tmp/pr-${N}-${pass}-done" ]]; then echo "FAIL $pass: start left the old done stamp"; fails=$((fails + 1)); else echo "ok   $pass: start removes an old done stamp"; fi
  expect "$pass: after start, old stamp gone" wait "$clock" "${pre}check" "$N"
  "$clock" "${pass}-done" "$N" >/dev/null
  expect "$pass: new done stamp"          done    "$clock" "${pre}check" "$N"

  clean; "$clock" "${pre}start" "$N" >/dev/null
  echo $(( $(date +%s) - 1000 )) >"/tmp/pr-${N}-source${pass}-started"
  expect "$pass: budget spent"            timeout "$clock" "${pre}check" "$N"
  "$clock" "${pass}-done" "$N" >/dev/null
  expect "$pass: done after budget spent" done    "$clock" "${pre}check" "$N"
done

# Each pass's stamp is its own: b-done must not end Source C's wait.
clean; "$clock" c-start "$N" >/dev/null; "$clock" b-done "$N" >/dev/null
expect "b-done does not finish c-check"   wait    "$clock" c-check "$N"

(( fails == 0 )) && echo "all passed" || echo "$fails failed"
(( fails == 0 ))
