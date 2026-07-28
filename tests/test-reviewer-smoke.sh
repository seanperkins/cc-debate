#!/bin/bash
# Smoke test: does every configured reviewer still produce a review at all?
#
# NOT a quality test. It asks one question per reviewer -- exit 0 and non-empty
# output on a trivial plan -- and that question is worth asking on its own,
# because the ways a reviewer dies are silent. On 2026-07-28 a prompt change told
# the antigravity reviewer to go read repo files it had no access to; agy reached
# for a terminal command, headless mode auto-denied the permission, and the whole
# review came back EMPTY with exit 1. The panel silently shrank from five
# reviewers to four and the run continued. This test would have caught it in the
# time it takes to read this comment.
#
# Usage:
#   bash tests/test-reviewer-smoke.sh [config] [reviewer1,reviewer2,...]
#
# Costs real API calls against real agents, so it is NOT part of run-all.sh.
# Run it after touching prompt construction, agent invocation, or the config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${1:-$HOME/.claude/debate-acpx.json}"
ONLY="${2:-}"

echo "=== reviewer smoke test ==="
echo "config: $CONFIG"

if [ ! -f "$CONFIG" ]; then
  echo "  config not found — run /debate:acpx-setup" >&2
  exit 1
fi
if ! command -v jq > /dev/null 2>&1; then
  echo "  jq not found" >&2
  exit 1
fi

# The work dir must sit inside a git repo: invoke-acpx.sh resolves the toplevel
# from it to decide whether a reviewer can be given repo access.
WORK_DIR="$REPO_ROOT/.tmp/smoke-$$"
mkdir -p "$WORK_DIR"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# A deliberately dull plan. We are testing that a review comes back, not what it
# says, so it must be something every reviewer can answer without deep analysis.
cat > "$WORK_DIR/plan.md" <<'PLAN'
# Plan: add a --version flag

Add a `--version` flag to the CLI that prints the version string from
package metadata and exits 0. No other behaviour changes. No new dependencies.
PLAN

if [ -n "$ONLY" ]; then
  REVIEWERS=$(echo "$ONLY" | tr ',' '\n' | tr -d ' ')
else
  REVIEWERS=$(jq -r '.reviewers | keys[]' "$CONFIG")
fi

PASS=0; FAIL=0; FAILED_NAMES=""

for rev in $REVIEWERS; do
  agent=$(jq -r --arg r "$rev" '.reviewers[$r].agent // empty' "$CONFIG")
  if [ -z "$agent" ]; then
    echo "  $rev: not in config — skipping"
    continue
  fi
  printf "  %-14s (%s) ... " "$rev" "$agent"

  rm -f "$WORK_DIR/${rev}-output.md" "$WORK_DIR/${rev}-exit.txt" "$WORK_DIR/${rev}-stderr.log"
  bash "$REPO_ROOT/scripts/invoke-acpx.sh" "$CONFIG" "$WORK_DIR" "$rev" \
       > "$WORK_DIR/${rev}-invoke.log" 2>&1

  code=$(cat "$WORK_DIR/${rev}-exit.txt" 2>/dev/null || echo "?")
  bytes=$(wc -c < "$WORK_DIR/${rev}-output.md" 2>/dev/null | tr -d ' ' || echo 0)

  # Empty-but-exit-0 is the failure mode that matters most: the runner records a
  # success and synthesis proceeds with a reviewer that said nothing.
  if [ "$code" = "0" ] && [ "${bytes:-0}" -gt 200 ]; then
    echo "PASS (${bytes}b)"
    PASS=$((PASS + 1))
  else
    echo "FAIL (exit=$code, ${bytes}b)"
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES $rev"
    if [ -s "$WORK_DIR/${rev}-stderr.log" ]; then
      echo "      stderr: $(head -c 220 "$WORK_DIR/${rev}-stderr.log" | tr '\n' ' ')"
    fi
  fi
done

echo
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "  failed:$FAILED_NAMES"
  echo "  A reviewer returning empty output does NOT stop a debate run — the panel"
  echo "  just silently shrinks. Fix before relying on a review."
  exit 1
fi
exit 0
