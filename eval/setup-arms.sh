#!/bin/bash
# Materialise both prompt versions side by side so an A/B needs no checkout dance.
#
#   bash eval/setup-arms.sh [old-ref] [new-ref] [dest]
#   defaults: main  prompt-calibration  /tmp/cc-debate-arms
#
# Uses `git archive` rather than `git worktree`: archive produces two fully
# independent snapshots with no .git metadata, no worktree registration inside
# the plugin repo, and nothing to prune afterwards. Deleting the dest directory
# is a complete cleanup.
#
# Why both arms must exist at once: the old prompts are no longer installed
# anywhere, and flipping the marketplace clone between refs mid-experiment is
# how you end up scoring one arm's reviews against the other arm's prompts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

OLD_REF="${1:-main}"
NEW_REF="${2:-prompt-calibration}"
DEST="${3:-/tmp/cc-debate-arms}"

for ref in "$OLD_REF" "$NEW_REF"; do
  if ! git -C "$REPO" rev-parse --verify --quiet "$ref" > /dev/null; then
    echo "error: no such ref in $REPO: $ref" >&2
    exit 1
  fi
done

rm -rf "$DEST"
mkdir -p "$DEST/old" "$DEST/new"

git -C "$REPO" archive "$OLD_REF" | tar -x -C "$DEST/old"
git -C "$REPO" archive "$NEW_REF" | tar -x -C "$DEST/new"

# Record exactly what each arm is, so a result set can never be traced to the
# wrong commit later.
{
  echo "old_ref=$OLD_REF"
  echo "old_sha=$(git -C "$REPO" rev-parse "$OLD_REF")"
  echo "new_ref=$NEW_REF"
  echo "new_sha=$(git -C "$REPO" rev-parse "$NEW_REF")"
  echo "created_from=$REPO"
} > "$DEST/ARMS.txt"

chmod +x "$DEST"/old/scripts/*.sh "$DEST"/new/scripts/*.sh 2>/dev/null || true
chmod +x "$DEST"/new/eval/*.py 2>/dev/null || true

echo "arms ready in $DEST"
sed 's/^/  /' "$DEST/ARMS.txt"
echo
echo "  old footer lines: $(awk '/\*\*Shared reviewer footer/{f=1} f&&/^```$/{c++; if(c==1){b=1;next} if(c==2){exit}} b' "$DEST/old/commands/run.md" | wc -l | tr -d ' ')"
echo "  new footer lines: $(awk '/\*\*Shared reviewer footer/{f=1} f&&/^```$/{c++; if(c==1){b=1;next} if(c==2){exit}} b' "$DEST/new/commands/run.md" | wc -l | tr -d ' ')"
echo
echo "next: bash eval/run-arm.sh --arm $DEST/old --plan <plan.md> --out <dir>"
