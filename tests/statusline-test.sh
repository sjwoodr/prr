#!/usr/bin/env bash
# statusline-test.sh -- checks prr-statusline.sh's idle line in a throwaway repo
# with a stub gh on PATH: a worktree named after its branch shows the main
# checkout's path, one named otherwise keeps its own, and the open PR for the
# branch shows on the second line once the background lookup has cached it,
# without a second gh call inside the cache lifetime. Run: tests/statusline-test.sh
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -u

sl="$(cd "$(dirname "$0")/.." && pwd)/scripts/prr-statusline.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
fails=0
cleanup() {
  local t b
  for t in "$tmp/repo/.worktrees/ABC-1-fix" "$tmp/repo/.worktrees/scratch"; do
    for b in "ABC-1+fix" "other"; do
      rm -rf "/tmp/prr-statusline-pr-$(printf '%s|%s' "$t" "$b" | cksum | cut -d' ' -f1)"*
    done
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

git_q() { git -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }
git_q init -b main "$tmp/repo"
git_q -C "$tmp/repo" commit --allow-empty -m init
git_q -C "$tmp/repo" worktree add -b "ABC-1+fix" "$tmp/repo/.worktrees/ABC-1-fix"
git_q -C "$tmp/repo" worktree add -b "other" "$tmp/repo/.worktrees/scratch"

mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
echo call >> "$tmp/gh-calls"
case " \$* " in *" ABC-1+fix "*) echo "42 APPROVED" ;; esac
EOF
chmod +x "$tmp/bin/gh"

render() {
  printf '{"session_id":"statusline-test","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5"}}' "$1" \
    | PATH="$tmp/bin:$PATH" NO_COLOR=1 PRR_STATUSLINE_TIMINGS=0 "$sl"
}
expect() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$3', got '$2'"; fails=$((fails + 1)); fi
}
wait_lookup() { # until the background refresh has released its lock
  local i
  for i in $(seq 1 50); do ls -d /tmp/prr-statusline-pr-*.lock >/dev/null 2>&1 || return 0; sleep 0.1; done
}

home_rel() { if [ "${1#"$HOME"}" != "$1" ]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi; }
main_dir="$(home_rel "$tmp/repo")"
wt="$tmp/repo/.worktrees/ABC-1-fix"

first="$(render "$wt")"
expect "worktree named after its branch shows the main checkout" \
  "$(printf '%s\n' "$first" | head -1)" "$main_dir (ABC-1+fix) [Opus 5]"
expect "first render has no PR yet" "$(printf '%s\n' "$first" | sed -n 2p)" ""
wait_lookup
expect "PR shows on line 2 once cached" "$(render "$wt" | sed -n 2p)" "PR #42"
expect "one gh call within the cache lifetime" "$(wc -l < "$tmp/gh-calls" | tr -d ' ')" "1"
expect "other worktree name keeps its own path" \
  "$(render "$tmp/repo/.worktrees/scratch" | head -1)" "$(home_rel "$tmp/repo/.worktrees/scratch") (other) [Opus 5]"
wait_lookup
expect "branch with no open PR shows none" "$(render "$tmp/repo/.worktrees/scratch" | sed -n 2p)" ""
expect "main checkout looks nothing up" "$(render "$tmp/repo" | sed -n 2p)" ""

[[ "$fails" -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
