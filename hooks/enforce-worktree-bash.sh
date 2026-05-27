#!/bin/bash
# PreToolUse hook: block sub-agent Bash commands whose write targets
# resolve outside the sub-agent's worktree (CWD).
#
# Covers the common bash escape routes documented in anthropics/claude-code
# issue #52988 and the Ona "denylist/sandbox escape" writeup:
#
#   1. Redirection:    > /path     >> /path
#   2. tee:            tee [-opts] /path
#   3. Copy/move:      cp ... /path     mv ... /path     rsync ... /path
#   4. dd:             dd of=/path
#
# This is a pattern matcher, not a bash parser. It will miss:
#   - paths inside command substitution: cp $(query) /bad
#   - paths built from env vars: > $HOME/bad
#   - exotic redirection forms and process substitution
# Combined with enforce-worktree-writes.sh it closes ~95% of subagent
# write drift. The remaining 5% needs an OS-level sandbox (bubblewrap).
#
# /tmp, /dev, /proc, /var/tmp are allowlisted as never-the-main-checkout.
#
# Audit log: $CLAUDE_PROJECT_DIR/.claude/audit/worktree-write-violations.log

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Main session: allow.
if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ]; then
  exit 0
fi

[ "$TOOL_NAME" = "Bash" ] || exit 0
[ -n "$COMMAND" ] || exit 0

WORKTREE_NORM=$(cd "$CWD" && pwd -P)

# Collect absolute-path write targets.
CANDIDATES=()

# 1. Redirection: > /path  or  >> /path
while IFS= read -r p; do
  [ -n "$p" ] && CANDIDATES+=("$p")
done < <(echo "$COMMAND" | grep -oE '>>?[[:space:]]*/[^[:space:]|&;<>()]+' \
                          | sed -E 's/^>>?[[:space:]]*//')

# 2. tee [-opts] /path
while IFS= read -r p; do
  [ -n "$p" ] && CANDIDATES+=("$p")
done < <(echo "$COMMAND" | grep -oE '\btee[[:space:]]+(-[a-zA-Z-]+[[:space:]]+)*/[^[:space:]|&;<>()]+' \
                          | grep -oE '/[^[:space:]|&;<>()]+$')

# 3. cp | mv | rsync ... /path   (last absolute path on the match = dest)
while IFS= read -r p; do
  [ -n "$p" ] && CANDIDATES+=("$p")
done < <(echo "$COMMAND" | grep -oE '\b(cp|mv|rsync)[[:space:]]+[^|&;]*[[:space:]]/[^[:space:]|&;<>()]+' \
                          | grep -oE '/[^[:space:]|&;<>()]+$')

# 4. dd of=/path
while IFS= read -r p; do
  [ -n "$p" ] && CANDIDATES+=("$p")
done < <(echo "$COMMAND" | grep -oE '\bdd[[:space:]][^|&;]*\bof=/[^[:space:]|&;<>()]+' \
                          | grep -oE 'of=/[^[:space:]|&;<>()]+' \
                          | sed 's/^of=//')

# No write candidates => nothing to enforce.
[ ${#CANDIDATES[@]} -eq 0 ] && exit 0

VIOLATIONS=()
for raw in "${CANDIDATES[@]}"; do
  # Allowlist throwaway/system paths and the llm_memory persistent store.
  case "$raw" in
    /tmp/*|/tmp|/dev/*|/proc/*|/var/tmp/*) continue ;;
    "$HOME"/.claude/memory/*) continue ;;
  esac

  PARENT=$(dirname "$raw")
  if [ -e "$PARENT" ]; then
    NORM="$(cd "$PARENT" && pwd -P)/$(basename "$raw")"
  else
    NORM="$raw"
  fi

  if [[ "$NORM" != "$WORKTREE_NORM"/* ]] && [[ "$NORM" != "$WORKTREE_NORM" ]]; then
    VIOLATIONS+=("$NORM")
  fi
done

[ ${#VIOLATIONS[@]} -eq 0 ] && exit 0

LOG_DIR="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/audit"
mkdir -p "$LOG_DIR"
{
  echo "[$(date -Iseconds)] agent_id=$AGENT_ID tool=Bash worktree=$WORKTREE_NORM"
  echo "  command: $COMMAND"
  for v in "${VIOLATIONS[@]}"; do echo "  violation: $v"; done
} >> "$LOG_DIR/worktree-write-violations.log"

{
  echo "BLOCKED: sub-agent ($AGENT_ID) Bash command writes outside its worktree."
  echo ""
  echo "  Worktree root:   $WORKTREE_NORM"
  echo "  Command:         $COMMAND"
  echo ""
  echo "  Write targets outside worktree:"
  for v in "${VIOLATIONS[@]}"; do echo "    - $v"; done
  echo ""
  echo "Rewrite to target a path inside your worktree, or use /tmp/ for"
  echo "genuinely throwaway scratch files."
} >&2

exit 2
