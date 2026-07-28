#!/bin/bash
# Generic reviewer invocation via acpx CLI.
# Replaces invoke-codex.sh, invoke-gemini.sh, invoke-opus.sh, invoke-openai-compat.sh.
#
# Usage: invoke-acpx.sh <config_file> <work_dir> <reviewer_name> [timeout]
#   config_file   — path to JSON config (e.g. ~/.claude/debate-acpx.json)
#   work_dir      — temp directory (must contain plan.md)
#   reviewer_name — e.g. "codex", "antigravity", "kimi"
#   timeout       — optional override; falls back to config value, then 120s
#
# Config schema:
#   {
#     "reviewers": {
#       "<name>": {
#         "agent": "codex",
#         "timeout": 120,
#         "system_prompt": "You are The Executor..."
#       }
#     }
#   }
#
# Prompt resolution (in order):
#   1. $work_dir/<name>-prompt.txt  (debate/revision rounds write this)
#   2. reviewers.<name>.system_prompt from config + plan.md
#   3. Built-in fallback: generic plan reviewer + plan.md
#
# Output files (all written to $work_dir):
#   <name>-output.md   review text
#   <name>-stderr.log  acpx stderr (for debugging)
#   <name>-exit.txt    exit code (0=success, 124=timeout, 1=error)

set -euo pipefail

CONFIG_FILE="${1:-}"
WORK_DIR="${2:-}"
REVIEWER="${3:-}"
TIMEOUT_ARG="${4:-}"

if [ -z "$CONFIG_FILE" ] || [ -z "$WORK_DIR" ] || [ -z "$REVIEWER" ]; then
  echo "Usage: $0 <config_file> <work_dir> <reviewer_name> [timeout]" >&2
  exit 1
fi

# --- Resolve acpx binary (support npx fallback) ---

ACPX_BIN=()
if command -v acpx > /dev/null 2>&1; then
  ACPX_BIN=(acpx)
elif command -v npx > /dev/null 2>&1; then
  ACPX_BIN=(npx acpx@latest)
else
  echo "invoke-acpx: acpx not found. Install: npm install -g acpx@latest" >&2
  # Write a meaningful exit file if we can
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ] && [ -d "$WORK_DIR" ]; then
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    echo "acpx not installed. Run: npm install -g acpx@latest" > "$WORK_DIR/${REVIEWER}-output.md"
  fi
  exit 1
fi

# --- Trap: ensure exit file is always written on unexpected exit ---
# Only fires on abnormal termination — normal exit paths call trap - EXIT before returning.

create_exit_file() {
  local code="${1:-1}"
  if [ -n "$WORK_DIR" ] && [ -n "$REVIEWER" ]; then
    echo "$code" > "$WORK_DIR/${REVIEWER}-exit.txt"
    if [ ! -f "$WORK_DIR/${REVIEWER}-output.md" ]; then
      echo "invoke-acpx: process terminated unexpectedly (exit $code)" > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  fi
}

trap 'create_exit_file "$?"' EXIT

if [ ! -d "$WORK_DIR" ]; then
  echo "invoke-acpx: work_dir does not exist: $WORK_DIR" >&2
  exit 1
fi

if [ ! -f "$WORK_DIR/plan.md" ]; then
  echo "invoke-acpx: plan.md not found in $WORK_DIR" >&2
  exit 1
fi

if [ ! -s "$WORK_DIR/plan.md" ]; then
  echo "invoke-acpx: plan.md is empty in $WORK_DIR" >&2
  exit 1
fi

# --- Config ---

if [ ! -f "$CONFIG_FILE" ]; then
  echo "invoke-acpx: config not found: $CONFIG_FILE" >&2
  exit 1
fi

AGENT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].agent // empty' "$CONFIG_FILE")
if [ -z "$AGENT" ]; then
  echo "invoke-acpx: no agent for '$REVIEWER' in $CONFIG_FILE" >&2
  exit 1
fi

CONFIG_TIMEOUT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].timeout // empty' "$CONFIG_FILE")
CONFIG_SYSTEM_PROMPT=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].system_prompt // empty' "$CONFIG_FILE")
CONFIG_MODEL=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].model // empty' "$CONFIG_FILE")

# --- Repo access (resolved once; used by both the prompt builder and the agy call) ---
# Whether this reviewer can actually open repo source to ground the plan's citations.
# It must match reality in BOTH places: the prompt tells the reviewer to verify
# citations only when it really can, and the agy invocation adds the repo only when
# the prompt asked for it. A mismatch is not cosmetic — telling a reviewer with no
# repo to go looking makes agy reach for a terminal command, which headless mode
# soft-denies, and a denied permission returns NO output at all: the review dies with
# exit 1 rather than degrading. (observed 2026-07-28: antigravity went 0 -> 0 -> 1
# the moment an ungated grounding directive shipped.)
#
# acpx reviewers always have it — the runner passes --approve-reads. The antigravity
# reviewer gets it by adding the repo read-only with --add-dir; opt out per reviewer
# with "add_repo": false to restore the plan-only throwaway-workspace behaviour.
CONFIG_ADD_REPO=$(jq -r --arg rev "$REVIEWER" '.reviewers[$rev].add_repo // true' "$CONFIG_FILE")
REPO_TOP=""
HAS_REPO_ACCESS=1
if [ "$AGENT" = "antigravity" ]; then
  HAS_REPO_ACCESS=0
  if [ "$CONFIG_ADD_REPO" != "false" ]; then
    if REPO_TOP=$(git -C "$WORK_DIR" rev-parse --show-toplevel 2>/dev/null) \
       && [ -n "$REPO_TOP" ] && [ -d "$REPO_TOP" ]; then
      HAS_REPO_ACCESS=1
    else
      REPO_TOP=""
    fi
  fi
fi

# --- Nested Claude guard ---
# When the agent is `claude`, Claude Code's nested-session guard (CLAUDECODE=1)
# blocks acpx from spawning it as an ACP subprocess. Unset the guard vars so the
# child process can start. This was required in v1.x and remains necessary in v2.

if [ "$AGENT" = "claude" ] || [ "$AGENT" = "opus" ]; then
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
fi

# --- Session setup: ensure a session exists for this agent ---
# `sessions ensure` is idempotent: creates a session if none exists for the
# current cwd, reuses one if it does. Avoids accumulating sessions on every run.
# Skip if SKIP_SESSION_CHECK is set (for testing with mock acpx)

if [ -z "${SKIP_SESSION_CHECK:-}" ]; then
  # Antigravity and Opus use direct CLI invocation — skip acpx session check.
  if [ "$AGENT" != "antigravity" ] && [ "$AGENT" != "opus" ]; then
    echo "[$REVIEWER] Ensuring acpx session for '$AGENT'..." >&2
    if ! "${ACPX_BIN[@]}" "$AGENT" sessions ensure > /dev/null 2>&1; then
      echo "[$REVIEWER] Failed to ensure acpx session for '$AGENT'." >&2
      echo "  Check that the agent CLI is installed and authenticated." >&2
      echo "  Run /debate:acpx-setup to diagnose." >&2
      echo "4" > "$WORK_DIR/${REVIEWER}-exit.txt"
      echo "Failed to ensure acpx session for '$AGENT'. Run /debate:acpx-setup to diagnose." > "$WORK_DIR/${REVIEWER}-output.md"
      trap - EXIT
      exit 4
    fi
    echo "[$REVIEWER] Session ready." >&2
  fi
fi

TIMEOUT="${TIMEOUT_ARG:-${CONFIG_TIMEOUT:-120}}"
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -le 0 ]; then
  echo "invoke-acpx: invalid timeout '$TIMEOUT' for '$REVIEWER', using 120s" >&2
  TIMEOUT=120
fi

# --- Prompt ---

PROMPT_FILE=""

if [ -f "$WORK_DIR/${REVIEWER}-prompt.txt" ]; then
  # Debate/revision round — prompt file is the full message
  PROMPT_FILE="$WORK_DIR/${REVIEWER}-prompt.txt"
else
  # Initial review — build prompt from system_prompt + plan
  SYSTEM_PROMPT="${CONFIG_SYSTEM_PROMPT:-You are a senior engineer reviewing an implementation plan. Be specific, direct, and focus on what could go wrong.}"

  {
    echo "$SYSTEM_PROMPT"
    echo ""
    echo "READ-ONLY REVIEW — HARD RULE: You are reviewing a plan, nothing more. Do NOT create, edit, write, move, rename, or delete any file, and do NOT run any command that mutates the filesystem or repository (no patches, no fixes applied in place). You have read-only access only. Output your review as text in your reply — that text is the entire deliverable. Any write attempt is denied by the sandbox and only wastes the round."
    echo ""
    echo "Review this implementation plan:"
    echo ""
    cat "$WORK_DIR/plan.md"
    echo ""
    echo "SCOPE — this is a plan, not a diff. The code it describes does not exist yet, so a question about that code has no answer to find, only an answer to invent. Sort every concern before reporting it: (a) the plan specifies something that will be wrong -- report it; (b) the plan is silent on something that must be decided -- report it, this is the most valuable thing a plan review finds; (c) you would need to see the implementation to know -- do NOT report it as a finding, list it in one line under 'Check at code-review time' instead."
    echo ""
    if [ "$HAS_REPO_ACCESS" -eq 1 ]; then
      echo "GROUNDING — before building a critique on any file, line, function, or symbol the plan cites, confirm it exists by reading it. A citation you cannot confirm is itself the finding: report that the plan cites something that does not exist, rather than reasoning on top of it. Your own citations are held to the same bar -- cite only file:line you actually read this session, and never approximate a line number."
      if [ "$AGENT" = "antigravity" ]; then
        echo ""
        echo "Use your file reading and file search tools to do this. Do NOT shell out to terminal commands (grep, find, ls, cat, git) to go looking: you are running non-interactively and cannot be prompted, so a command that needs approval is denied and your ENTIRE review is discarded -- not just that one command. File reads need no approval; terminal commands do. Writes are denied too, which is expected: you are a reviewer, and the review text is your only deliverable."
      fi
    else
      echo "GROUNDING — you have NO access to the repository: you are running in an empty throwaway workspace, and the plan above is the entirety of what you have been given. Do not attempt to read, grep, list, or otherwise go looking for source files, and do not run terminal commands to find them; there is nothing there, and the attempt will end your review without producing one. Review the plan as a self-contained document. Where the plan's correctness depends on a file, symbol, or line you cannot see, say so explicitly and treat it as an assumption the plan is making -- an unverifiable citation is a legitimate finding to raise, and is the correct outcome here rather than a failure. Do not invent file:line citations of your own."
    fi
    echo ""
    echo "FINDING FORMAT — give every finding a severity, a confidence, and a disproof."
    echo "  Severity is defined by consequence, not by how interesting the finding is:"
    echo "    CRITICAL -- ships broken: data loss, security breach, corruption, failed deploy."
    echo "    MAJOR    -- a user or an on-call engineer will notice this as a bug."
    echo "    MINOR    -- quality, clarity, or consistency; will not produce a defect."
    echo "  Confidence is CONFIRMED (you read the code or spec that proves it -- cite it), LIKELY (strong inference), or HYPOTHESIS (plausible but untested). Reporting a HYPOTHESIS is fine; reporting one as though it were CONFIRMED is not."
    echo "  Disproof is one line: the single check -- a file to read, a command to run, a spec line to quote -- that would show this finding is wrong, doable in under five minutes."
    echo ""
    echo "A review with no findings is a valid and valuable result. If the plan is sound, say so and approve it. Do not manufacture concerns to justify your presence -- a reviewer that always finds something teaches the reader to ignore all of it."
    echo ""
    echo "Be specific and actionable. End your review with exactly one verdict line, chosen by severity and not by how many findings you have:"
    echo ""
    echo "VERDICT: APPROVED -- if you have no CRITICAL and no MAJOR findings. List any MINOR findings anyway; they get read, they just do not block."
    echo ""
    echo "VERDICT: REVISE -- only if you have at least one CRITICAL or MAJOR finding."
  } > "$WORK_DIR/${REVIEWER}-acpx-prompt.txt"

  PROMPT_FILE="$WORK_DIR/${REVIEWER}-acpx-prompt.txt"
fi

# --- Resolve timeout binary ---

TIMEOUT_BIN=""
if command -v timeout > /dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  echo "[$REVIEWER] WARNING: neither timeout nor gtimeout found — running without timeout enforcement" >&2
  echo "  Install: brew install coreutils (macOS) / apt install coreutils (Linux)" >&2
fi

# --- Shared result handler ---
# Call after running any reviewer command. Uses globals: REVIEWER, WORK_DIR, TIMEOUT, EXIT_CODE.
# $1: label used in log/error messages (e.g. "agy (Antigravity CLI)" or "acpx")

handle_invocation_result() {
  local label="$1"
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[$REVIEWER] Timed out after ${TIMEOUT}s." >&2
  elif [ "$EXIT_CODE" -ne 0 ]; then
    echo "[$REVIEWER] $label failed (exit $EXIT_CODE)." >&2
    if [ -s "$WORK_DIR/${REVIEWER}-stderr.log" ]; then
      echo "[$REVIEWER] stderr: $(head -5 "$WORK_DIR/${REVIEWER}-stderr.log")" >&2
    fi
    if [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
      {
        echo "$label error (exit $EXIT_CODE):"
        echo ""
        cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
      } > "$WORK_DIR/${REVIEWER}-output.md"
    fi
  else
    echo "[$REVIEWER] Review received." >&2
  fi

  echo "$EXIT_CODE" > "$WORK_DIR/${REVIEWER}-exit.txt"

  if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$WORK_DIR/${REVIEWER}-output.md" ]; then
    echo "[$REVIEWER] Empty response from $label." >&2
    {
      echo "Empty response from $label. Stderr:"
      echo ""
      cat "$WORK_DIR/${REVIEWER}-stderr.log" 2>/dev/null || echo "(no stderr)"
    } > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  trap - EXIT
  exit "$EXIT_CODE"
}

# --- Antigravity: direct CLI invocation ---
# Antigravity CLI's `agy` is the successor to the Gemini CLI for plan review.
# acpx has no native ACP support for it yet, so invoke `agy` directly. Three quirks
# drive this block (all verified against agy v1.0.x):
#   1. Prompt is a POSITIONAL ARGUMENT — `agy -p "<prompt>"`. stdin is NOT read in
#      print mode (it echoes the input and then times out waiting for a response).
#   2. Non-TTY stdout bug — `agy -p` drops its final response (and can hang) when
#      stdout is not a TTY, which is exactly our case (capturing to a file). We run
#      it under a PTY via `script`, then strip the PTY's ANSI/CR/EOT noise.
#   3. No hard read-only FLAG — unlike gemini's `--approval-mode plan`, agy has no
#      equivalent, and `--sandbox` only restricts terminal commands (it does NOT
#      prevent file writes). `--mode plan` is NOT one either: measured 2026-07-28,
#      it changes nothing about write behaviour here.
#
#      Read-only is enforced instead by headless mode itself. In `-p` runs agy
#      cannot prompt for a permission, so it SOFT-DENIES any tool needing one and
#      prints a stderr notice. `write_file` needs one; reads of an --add-dir'd
#      directory do not. Verified directly: asked to create a file and overwrite
#      an existing one inside its own workspace, agy wrote neither (both with and
#      without `--mode plan`) — the target file was untouched.
#
#      That is why we do NOT pass --dangerously-skip-permissions. It would auto-
#      approve write_file and is the one flag that turns this reviewer loose on
#      the repo. The stderr notice suggests it; do not take the suggestion.
#
#      The same soft-deny is a hazard on the read side: a denied permission
#      produces NO output at all and kills the whole review (exit 1), rather than
#      degrading. So the prompt tells this reviewer to use file reads and avoid
#      terminal commands, which need the "command" permission.
#
#      The repo is added read-only via --add-dir (see REPO_ROOT below) so the
#      reviewer can actually ground the plan's citations instead of taking them on
#      faith. Set "add_repo": false on the reviewer in debate-acpx.json to go back
#      to the old plan-only behaviour (throwaway workspace, no repo visibility).
# Works with OAuth (run `agy` once to sign in) or ANTIGRAVITY_API_KEY auth.

if [ "$AGENT" = "antigravity" ]; then
  if ! command -v agy > /dev/null 2>&1; then
    echo "[$REVIEWER] agy CLI not found. Install the Antigravity CLI and run 'agy' once to sign in." >&2
    echo "agy CLI not installed. Install the Antigravity CLI (https://antigravity.google) and run 'agy' to sign in." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  # A PTY is needed (quirk 2): agy drops its output unless stdout is a TTY. We use a
  # small Python runner rather than `script(1)` because BSD `script` aborts
  # ("tcgetattr/ioctl: Operation not supported on socket") when stdin is not a real
  # TTY — which is exactly how the debate runner launches us (nohup, stdin a
  # pipe/socket). The runner puts ONLY agy's stdout on a pty (stderr stays on our
  # stderr → ${REVIEWER}-stderr.log) and falls back to a plain pipe if the
  # environment forbids pty allocation (e.g. a restrictive sandbox), so it degrades
  # instead of failing. Identical on macOS and Linux.
  PY_BIN=""
  if command -v python3 > /dev/null 2>&1; then
    PY_BIN="python3"
  elif command -v python > /dev/null 2>&1; then
    PY_BIN="python"
  else
    echo "[$REVIEWER] python3 not found — required to run agy under a PTY." >&2
    echo "python3 not installed. Install Python 3 to use the antigravity reviewer." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting plan to agy (Antigravity CLI) directly (timeout: ${TIMEOUT}s)..." >&2

  # Prompt as a positional argument (quirk 1). Pass via env so plan content (newlines,
  # quotes, anything) reaches agy verbatim with zero shell/Python re-escaping.
  AGY_PROMPT="$(cat "$PROMPT_FILE")"
  export AGY_PROMPT
  export AGY_BIN; AGY_BIN="$(command -v agy)"
  export AGY_PRINT_TIMEOUT="${TIMEOUT}s"     # Go duration for --print-timeout
  # --model is optional; its value is a display name from `agy models`
  # (e.g. "Gemini 3.1 Pro (High)").
  if [ -n "$CONFIG_MODEL" ]; then
    export AGY_MODEL="$CONFIG_MODEL"
  else
    unset AGY_MODEL || true
  fi

  # Throwaway workspace stays the cwd (quirk 3): agy writes any scratch it wants
  # here, not into the repo.
  AGY_WORKSPACE="$WORK_DIR/.agy-workspace"
  mkdir -p "$AGY_WORKSPACE"

  # Repo access resolved once, up top. Reads inside an --add-dir'd tree need no
  # permission; writes stay soft-denied by headless mode (quirk 3).
  export AGY_ADD_DIR="$REPO_TOP"
  if [ -n "$AGY_ADD_DIR" ]; then
    echo "[$REVIEWER] Repo added read-only for citation grounding: $AGY_ADD_DIR" >&2
  else
    echo "[$REVIEWER] No repo access — reviewing the plan as a self-contained document." >&2
  fi

  TIMEOUT_PREFIX=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    TIMEOUT_PREFIX=("$TIMEOUT_BIN" "$TIMEOUT")
  fi

  # Strip the PTY's ANSI escapes (literal ESC via printf — portable across BSD/GNU sed),
  # carriage returns, and EOT (^D) bytes from the captured output.
  ESC=$(printf '\033')

  set +e
  # Expand the array 3.2-safely: on bash < 4.4 (macOS ships 3.2), "${arr[@]}" of an
  # EMPTY array under `set -u` throws "unbound variable". The +"${...}" guard yields
  # nothing when TIMEOUT_PREFIX is empty (no timeout/gtimeout on PATH) and the elements
  # otherwise — so the agy reviewer runs instead of crashing on timeout-less macOS.
  ( cd "$AGY_WORKSPACE" && "${TIMEOUT_PREFIX[@]+"${TIMEOUT_PREFIX[@]}"}" "$PY_BIN" -c '
import os, sys, subprocess
cmd = [os.environ["AGY_BIN"], "-p", os.environ["AGY_PROMPT"],
       "--sandbox", "--print-timeout", os.environ["AGY_PRINT_TIMEOUT"]]
model = os.environ.get("AGY_MODEL")
if model:
    cmd += ["--model", model]
# Repo added read-only so the reviewer can ground the plan citations; writes are
# still soft-denied by headless mode. Never add --dangerously-skip-permissions here.
add_dir = os.environ.get("AGY_ADD_DIR")
if add_dir:
    cmd += ["--add-dir", add_dir]
# Put only agy stdout on a pty so isatty(stdout) is true; stderr stays on fd 2.
master = None
try:
    master, slave = os.openpty()
except OSError:
    master = None
out = b""
if master is not None:
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=slave, close_fds=True)
    os.close(slave)
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.close(master)
    rc = p.wait()
else:
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    out = p.stdout
    rc = p.returncode
sys.stdout.buffer.write(out)
sys.stdout.buffer.flush()
sys.exit(rc if rc and rc > 0 else (1 if rc else 0))
' ) 2>"$WORK_DIR/${REVIEWER}-stderr.log" \
    | sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" | tr -d '\r\004' > "$WORK_DIR/${REVIEWER}-output.md"
  EXIT_CODE=${PIPESTATUS[0]}
  set -e

  handle_invocation_result "agy (Antigravity CLI)"
fi

# --- Opus: direct Claude CLI invocation ---
# Uses `claude --print --model <model>` via stdin — bypasses acpx entirely.
# Model comes from the reviewer's config `.model`, defaulting to a CURRENT opus id.
# (A stale id like claude-opus-4-6 makes --print return empty with exit 0 — a silent
# review failure. Keep this default current, or set `.model` per reviewer in config.)
# CLAUDECODE is already unset above so the nested-session guard doesn't block it.

if [ "$AGENT" = "opus" ]; then
  if ! command -v claude > /dev/null 2>&1; then
    echo "[$REVIEWER] claude CLI not found — is Claude Code installed?" >&2
    echo "claude CLI not installed. Ensure Claude Code is on PATH." > "$WORK_DIR/${REVIEWER}-output.md"
    echo "1" > "$WORK_DIR/${REVIEWER}-exit.txt"
    trap - EXIT
    exit 1
  fi

  echo "[$REVIEWER] Submitting plan to Claude Opus directly (timeout: ${TIMEOUT}s)..." >&2

  OPUS_CMD=()
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
    OPUS_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
  fi
  # --permission-mode plan: read-only mode — the reviewer cannot edit/write files.
  OPUS_CMD+=(claude --print --permission-mode plan --model "${CONFIG_MODEL:-claude-opus-4-8}")

  set +e
  "${OPUS_CMD[@]}" < "$PROMPT_FILE" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
  EXIT_CODE=$?
  set -e

  handle_invocation_result "Claude Opus"
fi

# --- acpx call ---

echo "[$REVIEWER] Submitting plan to $AGENT via acpx (timeout: ${TIMEOUT}s)..." >&2

ACPX_CMD=()
if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" -gt 0 ]; then
  ACPX_CMD+=("$TIMEOUT_BIN" "$TIMEOUT")
fi
# Read-only enforcement: --approve-reads auto-approves read/search requests;
# --non-interactive-permissions deny auto-denies any write/edit/exec the agent
# requests (headless can't prompt, so it denies rather than hangs). This is the
# hard guarantee that a reviewer (e.g. an over-eager external agent) cannot
# modify the plan doc or any file in the repo while reviewing.
ACPX_CMD+=("${ACPX_BIN[@]}" --format quiet --approve-reads --non-interactive-permissions deny "$AGENT" --file "$PROMPT_FILE")

set +e
"${ACPX_CMD[@]}" > "$WORK_DIR/${REVIEWER}-output.md" 2>"$WORK_DIR/${REVIEWER}-stderr.log"
EXIT_CODE=$?
set -e

handle_invocation_result "acpx"
