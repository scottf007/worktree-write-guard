#!/bin/bash
# PreToolUse hook: block sub-agent Write/Edit/MultiEdit/NotebookEdit calls
# whose target file_path resolves outside the sub-agent's worktree (CWD).
#
# Discrimination: `agent_id` field in the PreToolUse JSON input.
#   - present  => sub-agent run; enforce boundary
#   - absent/null => main session; allow
# (Anthropic docs: "Present only when hook fires inside a subagent".
#  Issue #23889 warns subagent hook behavior may diverge from docs —
#  always confirm with hooks/debug-pretooluse.sh in your CC version.)
#
# Exit codes:
#   0 = allow tool call
#   2 = block; stderr is shown to the agent as the rejection reason
#
# Audit log: $CLAUDE_PROJECT_DIR/.claude/audit/worktree-write-violations.log

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Main session: allow.
if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ]; then
  exit 0
fi

# Only enforce on tools that take a file_path.
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

[ -n "$FILE_PATH" ] || exit 0

# Resolve to absolute.
if [[ "$FILE_PATH" = /* ]]; then
  ABS_PATH="$FILE_PATH"
else
  ABS_PATH="$CWD/$FILE_PATH"
fi

# Canonicalize via parent dir (works even if the file doesn't exist yet,
# as long as the parent does).
PARENT=$(dirname "$ABS_PATH")
if [ -e "$PARENT" ]; then
  NORM_PATH="$(cd "$PARENT" && pwd -P)/$(basename "$ABS_PATH")"
else
  NORM_PATH="$ABS_PATH"
fi

# Canonicalize the worktree root too — defends against symlinked worktrees.
WORKTREE_NORM=$(cd "$CWD" && pwd -P)

# Allowlist: ~/.claude/memory/ is the llm_memory persistent store and
# is writable from any subagent regardless of CWD. The delta-extractor
# subagent (invoked by /narrative) writes deltas there from a fresh
# CWD that is not the memory dir.
case "$NORM_PATH" in
  "$HOME"/.claude/memory/*) exit 0 ;;
esac

# Inside worktree? Allow.
if [[ "$NORM_PATH" == "$WORKTREE_NORM"/* ]] || [[ "$NORM_PATH" == "$WORKTREE_NORM" ]]; then
  exit 0
fi

# Outside worktree — log and block.
LOG_DIR="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/audit"
mkdir -p "$LOG_DIR"
echo "[$(date -Iseconds)] agent_id=$AGENT_ID tool=$TOOL_NAME blocked=$NORM_PATH worktree=$WORKTREE_NORM" \
  >> "$LOG_DIR/worktree-write-violations.log"

{
  echo "BLOCKED: sub-agent ($AGENT_ID) attempted to $TOOL_NAME outside its worktree."
  echo ""
  echo "  Attempted path:  $NORM_PATH"
  echo "  Worktree root:   $WORKTREE_NORM"
  echo ""
  echo "Use a path inside your worktree:"
  echo "  - relative to your CWD (e.g. 'src/foo.py'), or"
  echo "  - absolute under $WORKTREE_NORM/"
} >&2

exit 2
