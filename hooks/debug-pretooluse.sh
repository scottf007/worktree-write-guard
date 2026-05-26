#!/bin/bash
# Debug hook: log each PreToolUse JSON input so you can confirm the
# `agent_id` discrimination behavior in your Claude Code version.
#
# Why this exists: Anthropic issue #23889 documents that hooks
# "correctly configured in parent may silently fail in subagent/MCP
# contexts". The docs say `agent_id` is "present only when hook fires
# inside a subagent" — but always verify empirically before trusting
# the enforcement hooks.
#
# How to use:
#   1. Wire this hook in place of (or alongside) the enforcement hooks
#      with matcher "Write|Edit|MultiEdit|NotebookEdit|Bash".
#   2. In a MAIN session, do any Write. Inspect the log entry —
#      agent_id should be null or absent.
#   3. Dispatch a sub-agent with Agent(isolation:"worktree") that does
#      any Write. Inspect the new entry — agent_id should be set.
#   4. If both behave as expected, swap back to the enforcement hooks.
#   5. If main-session agent_id is also set, the enforcement hooks need
#      a different discriminator (e.g., parse cwd to detect the
#      .claude/worktrees/ prefix instead).
#
# Log: $CLAUDE_PROJECT_DIR/.claude/audit/cc-hook-debug.log

set -euo pipefail

INPUT=$(cat)

LOG_DIR="${CLAUDE_PROJECT_DIR:-/tmp}/.claude/audit"
mkdir -p "$LOG_DIR"

echo "$INPUT" | jq -c '{
  ts: now | todate,
  session_id: .session_id,
  agent_id: .agent_id,
  agent_type: .agent_type,
  tool_name: .tool_name,
  cwd: .cwd,
  file_path: .tool_input.file_path,
  command_prefix: (.tool_input.command // "" | .[0:80])
}' >> "$LOG_DIR/cc-hook-debug.log"

exit 0
