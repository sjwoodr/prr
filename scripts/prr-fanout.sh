#!/usr/bin/env bash
# prr-fanout.sh — multi-PR fan-out router. Selects a backend from
# PRR_FANOUT=[tmux|wezterm] and hands the whole batch to prr-fanout-<backend>.sh:
#
#   tmux     -> prr-fanout-tmux.sh    one window, a tiled tmux pane per PR
#                                     (portable; the default backend)
#   wezterm  -> prr-fanout-wezterm.sh wezterm-native panes, no tmux (Linux only)
#
# Each backend does the real work and its own guards (GUI present, tools on PATH,
# etc.); this script only resolves the selection and execs. The human approval
# gate lives in the per-PR `/prr` review, untouched by either backend.
#
# Config (env):
#   PRR_FANOUT   "tmux" or "wezterm". Unset => refuse with exit 3 (the skill then
#                reviews sequentially). Back-compat: PRR_FANOUT=true and the legacy
#                PRR_TMUX_FANOUT=true both normalize to "tmux".
#   (PRR_FANOUT_TIMEOUT_MINS / PRR_FANOUT_GEOMETRY / PRR_FANOUT_TERMINAL are read
#    by the backends; see their headers.)
#
# Usage (run in the BACKGROUND from the skill; blocks until every review ends):
#   prr-fanout.sh <PR-url-or-number> <PR-url-or-number> ...
#   prr-fanout.sh test-mode <N> <N> ...     no-Claude plumbing smoke test
#
# Author: Steve Woodruff (@sjwoodr)
# SPDX-License-Identifier: MIT
set -euo pipefail

# `test-mode` (no-Claude smoke test) bypasses the enable gate but still honors the
# backend selection, defaulting to tmux when PRR_FANOUT is unset.
TEST=0
if [[ "${1:-}" == "test-mode" ]]; then TEST=1; shift; fi

# Resolve the backend. Back-compat: PRR_FANOUT=true and legacy PRR_TMUX_FANOUT=true
# both mean "tmux".
backend="${PRR_FANOUT:-}"
[[ "$backend" == "true" ]] && backend="tmux"
[[ -z "$backend" && "${PRR_TMUX_FANOUT:-}" == "true" ]] && backend="tmux"
if [[ "$TEST" -eq 1 ]]; then
  [[ -n "$backend" ]] || backend="tmux"
else
  [[ -n "$backend" ]] \
    || { echo "prr-fanout: PRR_FANOUT is not set; not fanning out." >&2; exit 3; }
fi
case "$backend" in
  tmux|wezterm) ;;
  *) echo "prr-fanout: PRR_FANOUT must be 'tmux' or 'wezterm' (got '$backend')." >&2; exit 3 ;;
esac

# Hand off to the selected backend. Export the normalized value so the backend's
# own guard sees the canonical name regardless of which alias was used.
export PRR_FANOUT="$backend"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="$here/prr-fanout-$backend.sh"
[[ -x "$target" ]] || { echo "prr-fanout: backend script not found: $target" >&2; exit 3; }
if [[ "$TEST" -eq 1 ]]; then
  exec "$target" test-mode "$@"
else
  exec "$target" "$@"
fi
