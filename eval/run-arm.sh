#!/bin/bash
# Run one plan through one arm's reviewers and collect the reviews.
#
#   bash eval/run-arm.sh --arm /tmp/cc-debate-arms/old \
#                        --plan variants/control-plan.md \
#                        --out results/old-control \
#                        [--rep 1] [--acpx codex,antigravity] \
#                        [--personas "Opus Skeptic:opus,Pentester:opus"] \
#                        [--config ~/.claude/debate-acpx.json] [--dry-run]
#
# Each arm directory is a full snapshot (see setup-arms.sh), so the acpx
# reviewers run through THAT arm's invoke-acpx.sh and the Claude personas get a
# prompt assembled from THAT arm's reviewer-prompts.md + run.md footer. Nothing
# is read from the installed plugin, so the experiment is unaffected by whatever
# happens to be in the cache.
#
# Outputs into --out:
#   <reviewer>-output.md    the review (scored by eval/score-run.py)
#   <reviewer>-exit.txt     exit code
#   RUN.txt                 arm, plan, rep, personas — provenance for the result

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARM=""; PLAN=""; OUT=""; REP="1"; DRY=0
ACPX="codex,antigravity"
PERSONAS="Opus Skeptic:opus,Fable Skeptic:fable,Pentester:opus"
CONFIG="$HOME/.claude/debate-acpx.json"
PERSONA_TIMEOUT="900"      # seconds per Claude reviewer; see the note at the call site

while [ $# -gt 0 ]; do
  case "$1" in
    --arm) ARM="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --rep) REP="$2"; shift 2 ;;
    --acpx) ACPX="$2"; shift 2 ;;
    --personas) PERSONAS="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --persona-timeout) PERSONA_TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for req in ARM PLAN OUT; do
  if [ -z "${!req}" ]; then echo "error: --${req,,} is required" >&2; exit 2; fi
done
[ -d "$ARM" ] || { echo "error: arm dir not found: $ARM" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "error: plan not found: $PLAN" >&2; exit 2; }

# GNU timeout is `timeout`; on macOS via coreutils it is `gtimeout`. Absent
# either, run uncapped rather than refusing to run at all.
TIMEOUT_BIN=""
if command -v timeout > /dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
else echo "  note: no timeout binary; Claude reviewers will run uncapped" >&2; fi

mkdir -p "$OUT"
PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

{
  echo "arm=$ARM"
  [ -f "$ARM/../ARMS.txt" ] && sed 's/^/  /' "$ARM/../ARMS.txt"
  echo "plan=$PLAN_ABS"
  echo "rep=$REP"
  echo "acpx=$ACPX"
  echo "personas=$PERSONAS"
  echo "persona_timeout=${PERSONA_TIMEOUT}s"
} > "$OUT/RUN.txt"

echo "=== arm: $ARM   plan: $(basename "$PLAN")   rep: $REP ==="

# --- acpx reviewers -----------------------------------------------------------
# invoke-acpx.sh expects a work dir containing plan.md, and resolves the repo
# toplevel from it -- so the work dir must live inside the repo under review.
if [ -n "$ACPX" ]; then
  WORK="$(dirname "$PLAN_ABS")/.eval-work-$$"
  mkdir -p "$WORK"
  cp "$PLAN_ABS" "$WORK/plan.md"
  for rev in $(echo "$ACPX" | tr ',' ' '); do
    printf "  acpx %-12s ... " "$rev"
    if [ "$DRY" = "1" ]; then echo "(dry-run)"; continue; fi
    bash "$ARM/scripts/invoke-acpx.sh" "$CONFIG" "$WORK" "$rev" \
        > "$OUT/${rev}-invoke.log" 2>&1
    code=$(cat "$WORK/${rev}-exit.txt" 2>/dev/null || echo "?")
    if [ -s "$WORK/${rev}-output.md" ]; then
      cp "$WORK/${rev}-output.md" "$OUT/${rev}-output.md"
    fi
    echo "$code" > "$OUT/${rev}-exit.txt"
    bytes=$(wc -c < "$OUT/${rev}-output.md" 2>/dev/null | tr -d ' ' || echo 0)
    echo "exit=$code ${bytes}b"
  done
  rm -rf "$WORK"
fi

# --- Claude persona reviewers -------------------------------------------------
# Assembled from this arm's own sources and run headless. Delivery is redirected
# to stdout by the harness override (see build-prompt.py) identically in both
# arms. Reads are pre-approved so the reviewer can ground citations; no write
# tool is granted, so a review cannot modify the repo under test.
if [ -n "$PERSONAS" ]; then
  ROSTER=$(echo "$PERSONAS" | sed 's/:[^,]*//g')
  IFS=',' read -ra PLIST <<< "$PERSONAS"
  for entry in "${PLIST[@]}"; do
    persona="${entry%%:*}"
    model="${entry##*:}"
    [ "$model" = "$persona" ] && model="opus"
    slug=$(echo "$persona" | tr 'A-Z ' 'a-z-')
    printf "  claude %-16s (%s) ... " "$persona" "$model"

    if ! python3 "$SCRIPT_DIR/build-prompt.py" --arm "$ARM" --persona "$persona" \
         --plan "$PLAN_ABS" --roster "$ROSTER" > "$OUT/${slug}-prompt.txt" 2>"$OUT/${slug}-prompt.err"; then
      echo "PROMPT BUILD FAILED"; sed 's/^/      /' "$OUT/${slug}-prompt.err"; continue
    fi
    if [ "$DRY" = "1" ]; then
      echo "(dry-run, prompt $(wc -c < "$OUT/${slug}-prompt.txt" | tr -d ' ')b)"; continue
    fi

    # Nested Claude guard: when this harness is itself run from inside Claude
    # Code, CLAUDECODE=1 / CLAUDE_CODE_ENTRYPOINT are exported, and the child
    # `claude --print` refuses to start -- it writes the bare string
    # "Execution error" to stdout, exits without stderr, and looks for all the
    # world like a model failure. scripts/invoke-acpx.sh unsets the same two
    # vars for the same reason. Unset them only in the subshell so the parent
    # environment is untouched.
    # A grounding reviewer on a large plan genuinely takes many minutes -- opus
    # with Read/Grep on a 40KB prompt regularly runs past ten. Without a cap, one
    # slow reviewer stalls a 12-run experiment indefinitely, so bound it and
    # record the timeout as a data point instead of hanging.
    ( cd "$(dirname "$PLAN_ABS")" && \
      unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && \
      ${TIMEOUT_BIN:+$TIMEOUT_BIN $PERSONA_TIMEOUT} \
      claude --print --model "$model" \
             --allowedTools "Read,Grep,Glob" \
             < "$OUT/${slug}-prompt.txt" ) \
        > "$OUT/${slug}-output.md" 2>"$OUT/${slug}-stderr.log"
    code="$?"
    echo "${code:-1}" > "$OUT/${slug}-exit.txt"

    # "Execution error" with exit 0 is the nested-guard signature; treat it as a
    # failure rather than letting an empty review through as a valid data point.
    if [ "$(head -c 40 "$OUT/${slug}-output.md" 2>/dev/null)" = "Execution error" ]; then
      echo "1" > "$OUT/${slug}-exit.txt"
      code=1
    fi
    bytes=$(wc -c < "$OUT/${slug}-output.md" 2>/dev/null | tr -d ' ' || echo 0)
    if [ "$code" = "0" ] && [ "${bytes:-0}" -gt 200 ]; then
      echo "exit=0 ${bytes}b"
    else
      if [ "$code" = "124" ]; then
        echo "TIMEOUT after ${PERSONA_TIMEOUT}s (${bytes}b partial)"
      else
        echo "FAILED exit=$code ${bytes}b"
      fi
      [ -s "$OUT/${slug}-stderr.log" ] && echo "      $(head -c 200 "$OUT/${slug}-stderr.log" | tr '\n' ' ')"
    fi
  done
fi

echo "  -> $OUT"
