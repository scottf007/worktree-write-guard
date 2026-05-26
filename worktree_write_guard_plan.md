# Worktree-Write Guard — Implementation Plan

A small Claude Code plugin (or just a project-local hook) that **prevents
sub-agents dispatched with `Agent(isolation: "worktree")` from writing
to paths outside their worktree**. Solves the "absolute-path drift"
class of bug where LLM agents forget the worktree boundary mid-run and
clobber the main checkout.

**Status:** v0.1 implemented. See [README.md](./README.md) for install
and use. This doc remains the design rationale.

**Author audience:** Scott (or whoever builds this) with prior Claude
Code familiarity. Linux / WSL2 target.

---

## 0. Research Update (2026-05-26)

Four research agents verified the plan against current Claude Code
docs, surveyed other CLI LLMs (Codex, Cursor, Gemini, OpenCode, Aider,
Cline, Continue), and searched community discussion. Summary of what
changed between this design and the shipped v0.1:

| Plan claim | Status | Action |
|---|---|---|
| `agent_id` field present only in subagents | Documented (code.claude.com/docs/en/hooks.md). Issue [#23889](https://github.com/anthropics/claude-code/issues/23889) warned of silent failures, but **empirically verified working** on CC 2.1.x (2026-05-26, mailsort): main=`null`, subagent=`"a5b56fda72ad096eb"` | Discriminator confirmed. Re-test in new CC versions. |
| Field name `agent_type` (not `subagent_type`) | Confirmed | No change |
| Exit 2 vs `permissionDecision` JSON | Both canonical | Using exit 2 |
| Plugin packaging via `plugin.json` + `hooks/hooks.json` | Confirmed | Shipped both — install path `~/.claude/plugins/worktree-write-guard/` |
| `${CLAUDE_PROJECT_DIR}` / `${CLAUDE_PLUGIN_ROOT}` in commands | Confirmed | Used both |
| No `CLAUDE_AGENT_ID` env var (must parse JSON) | Confirmed | Parsing JSON stdin |
| No OS-level subagent boundary in Claude Code | Confirmed (sandboxed Bash uses bubblewrap, but file tools run unconstrained) | This plugin fills a real gap |
| Bash guard deferred to v2 | **Reversed.** Anthropic issue [#52988](https://github.com/anthropics/claude-code/issues/52988) documents bash as the main escape route; Ona "denylist escape" writeup confirms | **Bash matcher shipped in v1** as `enforce-worktree-bash.sh` |

**Prior art** (none did per-subagent-worktree scoping — that's the
genuine contribution here):

- [justi/claude-code-project-boundary](https://github.com/justi/claude-code-project-boundary)
  (70★) — same pattern, but scopes to `$CLAUDE_PROJECT_DIR`, not the
  per-subagent worktree path.
- [derek-larson14/claude-guard](https://github.com/derek-larson14/claude-guard)
  — adds macOS `sandbox-exec` backstop.
- [CaptainMcCrank/SandboxedClaudeCode](https://github.com/CaptainMcCrank/SandboxedClaudeCode)
  (31★) — bubblewrap/firejail wrapper, ~5ms overhead. Complementary
  OS-level defense.

**Adjacent solved-elsewhere problems** (worth knowing about but not
adopted):

- **OpenAI Codex CLI** enforces filesystem isolation at the syscall
  level via Bubblewrap + Landlock + seccomp, subagents inherit it,
  and `.git`/`.codex` are read-only even inside `WorkspaceWrite`. If
  you ever shell out to `codex` for sub-agent dispatch, this plugin
  becomes redundant for that path.
- **Cursor CLI** accepts Claude-Code-format hooks verbatim — this
  plugin is portable to Cursor with zero changes.
- **Cline** sidesteps the problem by making subagents read-only by
  capability (no Write tool exposed). Different design point.

---

## 1. Problem & Design Goal

### 1.1 The pain

Claude Code's `Agent(isolation: "worktree")` tool creates a git
worktree at `.claude/worktrees/agent-<id>/` and sets that as the
sub-agent's starting CWD. The intent is "isolated workspace per
sub-agent so concurrent agents don't trample each other."

The reality:

- The worktree is **only an isolated git ref + directory**.
  Nothing prevents the sub-agent from calling
  `Write(file_path="/absolute/path/to/main/checkout/file.py")`.
- LLM agents drift to absolute paths as their conversation context
  grows. After ~30 minutes / hundreds of tool calls, they forget the
  `$WORKTREE_ROOT` discipline and write directly to the shared
  filesystem.
- The branch-isolation is technically working — `git status` in the
  worktree shows clean — but the file content is on disk in the main
  checkout. The work is **dangling between the two**.

In a recent finance_nexus session, this happened **5+ times in a
single ~6-hour multi-agent run**, despite explicit warnings in every
agent prompt. Concrete impact:

- Migration files (`migrations/145_*.sql`) appeared in main checkout
  as untracked files while the corresponding sub-agent's worktree
  thought it was clean.
- The dispatcher (me / human / orchestrator) had to stash the drift
  manually, hope the sub-agent re-commits the same content to its
  own branch, and reconcile.
- Several times the drift caused unrelated test failures (line-shift
  in shared files broke allowlist tests) before being detected.

### 1.2 Why prompts don't work

Adding "do not use absolute paths; bind `$WORKTREE_ROOT` and prefix
every Write call" to the agent prompt **fails reliably**. Reasons:

- Context erosion: as the agent's working buffer fills with tool
  calls, the early prompt gets compressed and the discipline rule
  fades.
- LLM agents reach for familiar paths: `/home/scott/projects/<repo>/`
  is what they see in `git log`, in error messages, in fixture
  templates. The "correct" worktree path is unfamiliar.
- A single drifted Write doesn't error immediately — the file lands
  in main, the agent continues, the damage is invisible until later
  reconciliation.

Prompt-level mitigation is **detection after the fact** (via post-run
`git status`), not **prevention**. We want prevention.

### 1.3 Design goal

A **PreToolUse hook** that:

1. Fires on every `Write` / `Edit` tool call.
2. In a sub-agent session: rejects the call if `file_path` resolves
   to a path outside the sub-agent's worktree.
3. In the main session: lets every call through (the dispatcher
   needs full filesystem access to coordinate).
4. Logs every rejection so we can audit drift attempts.
5. Returns a clear error message the agent can recover from
   (`"BLOCKED: write to /home/.../foo is outside your worktree at
   /home/.../.claude/worktrees/agent-xxx/"`).

### 1.4 Out of scope

- **Bash commands.** ~~Defer to v2.~~ **Promoted to v1** after
  Anthropic issue #52988 made clear bash is the primary escape route.
  Shipped as `hooks/enforce-worktree-bash.sh` — pattern-matches `>`,
  `>>`, `tee`, `cp`, `mv`, `rsync`, `dd of=`. Hides remaining gaps
  for shell-substituted destinations (`cp $(foo) /bad`) and exotic
  redirection.
- **Network egress.** Sub-agent making `curl` calls is unrelated to
  this concern.
- **Read-only access.** Sub-agents can still read anywhere. We only
  block writes.
- **Inter-agent coordination.** Two sub-agents writing to the same
  file in their respective worktrees is fine — git merge resolves
  it at ff-merge time.
- **MCP server writes.** Anthropic docs explicitly state MCP servers
  run unconstrained on the host. A subagent that calls an MCP tool
  that writes files bypasses this hook entirely. Mitigation requires
  per-MCP-server review, not a hook.

---

## 2. Claude Code Hooks Background

### 2.1 Hook events available

Claude Code exposes several hook events. The relevant ones:

| Event | Fires when | Can it block? |
|---|---|---|
| `PreToolUse` | Before any tool call (Read, Write, Edit, Bash, Agent, etc.) | **Yes** — exit 2 or `{"permissionDecision": "deny"}` |
| `PostToolUse` | After a tool call succeeds | No (audit only) |
| `Stop` | When the agent's run ends | No |
| `SubagentStop` | When a sub-agent run ends | No |

We need `PreToolUse`.

### 2.2 Hook input contract

A hook is a shell command (or executable file) that runs every time
its event fires. The hook receives **JSON on stdin** with this shape
(confirmed from Claude Code docs):

```json
{
  "session_id": "abc123def456",
  "cwd": "/home/scott/projects/finance_nexus/.claude/worktrees/agent-aXXXXX",
  "hook_event_name": "PreToolUse",
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/home/scott/projects/finance_nexus/migrations/145_foo.sql",
    "content": "CREATE TABLE..."
  },
  "agent_id": "aXXXXX",
  "agent_type": "general-purpose",
  "transcript_path": "/home/scott/.claude/sessions/abc123def456.jsonl",
  "permission_mode": "default"
}
```

**Critical fields for our use case:**

- `agent_id` — present (typically) when running inside a sub-agent;
  may be absent or null in the main session. **This is the
  discrimination signal.** The exact behaviour needs empirical
  confirmation (see §3.4).
- `cwd` — the sub-agent's working directory. For worktree-isolated
  agents, this looks like `.../.claude/worktrees/agent-XYZ/`.
- `tool_name` — `"Write"` / `"Edit"` / `"Bash"` etc.
- `tool_input.file_path` — the target path (Write/Edit only). May
  be relative or absolute.

### 2.3 Exit code semantics

The hook's exit code controls whether the tool call proceeds:

| Exit | Effect |
|---|---|
| `0` | Allow. Tool call proceeds normally. |
| `2` | **Block.** Tool call is rejected; stderr is shown to the agent as the rejection reason. |
| Other non-zero | Hook error. Logged; tool call proceeds (failsafe). |

Alternative: emit a JSON response on stdout:

```json
{"hookSpecificOutput": {"permissionDecision": "deny", "reason": "..."}}
```

Same effect as `exit 2`, slightly more structured. Either is fine.

### 2.4 Environment variables available to the hook

When the hook runs, Claude Code sets:

- `$CLAUDE_PROJECT_DIR` — the project root (where `.claude/` lives).
- `$CLAUDE_PLUGIN_ROOT` — the plugin's directory (if installed as a
  plugin).
- `$CLAUDE_EFFORT` — current effort level.

**Notably absent:**

- `$CLAUDE_AGENT_ID` — not exposed as env var. Must read from JSON
  stdin via `agent_id`.
- `$WORKTREE_ROOT` — not exposed.

### 2.5 Settings.json wiring

Hooks are registered in one of three settings files:

| File | Scope | Checked into git? |
|---|---|---|
| `.claude/settings.json` | Project — applies to anyone working in this checkout | Yes |
| `.claude/settings.local.json` | Project — local override | No (gitignored) |
| `~/.claude/settings.json` | User — applies across all projects | n/a |

For a write-guard hook you want **project-level**
(`.claude/settings.json`, checked in) so every collaborator (and
every sub-agent dispatched from any session) gets the protection.

Example settings entry:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/enforce-worktree-writes.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

The `matcher` is a regex against the `tool_name`. `Write|Edit`
catches both. `timeout` is seconds; 5 is generous for a path check.

---

## 3. Architecture & Detection Strategy

### 3.1 Hook flow

```
sub-agent calls Write(file_path="/home/scott/.../migrations/145.sql")
         ↓
Claude Code fires PreToolUse hook
         ↓
hook reads JSON on stdin
         ↓
hook decides:
  - agent_id present? → in sub-agent
    - file_path inside CWD's worktree? → exit 0 (allow)
    - else → exit 2 (block) + write rejection message to stderr
  - agent_id absent? → main session → exit 0 (allow)
         ↓
if exit 2: Claude Code rejects the tool call, agent sees the stderr
         ↓
agent retries with a worktree-relative path (or fails gracefully)
```

### 3.2 Worktree root resolution

The sub-agent's CWD looks like
`/home/scott/projects/finance_nexus/.claude/worktrees/agent-aXXXXX`.

The worktree root for the sub-agent is the **entire CWD** (anything
under it is fair game). The "main checkout boundary" we want to
protect is **anything OUTSIDE the worktree directory but inside the
project**.

So the check is:

```
absolute_path = resolve(file_path, cwd)
worktree_root = cwd  # the agent's full worktree path
if absolute_path startswith worktree_root: allow
else: block
```

For the special case where `file_path` is relative, resolve it
against `cwd`:

```
if file_path starts with "/": absolute_path = file_path
else: absolute_path = cwd + "/" + file_path
```

Then normalise (resolve `..`, `.`, symlinks):

```
absolute_path = realpath(absolute_path)
```

### 3.3 Main-session discrimination

The hook fires for ALL tool calls — including those from the main
session. We must not block the main session, only sub-agents.

**Discrimination rule:** `agent_id` field present in JSON input → sub-agent. Absent or null → main session.

This is the **one empirical question** to confirm before deployment
(see §3.4).

### 3.4 The agent_id empirical test

Before deploying the enforcement hook, drop a debug hook that logs
the full JSON input on every Write call:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "cat | tee -a /tmp/cc-hook-debug.log"
          }
        ]
      }
    ]
  }
}
```

Then:

1. In the main session: do a `Write` (e.g., edit a README). Inspect
   `/tmp/cc-hook-debug.log` — note whether `agent_id` is absent,
   `null`, or has a value.
2. Dispatch a sub-agent with `Agent(isolation: "worktree")` that
   does a `Write`. Inspect the log entry from that sub-agent's
   call. Confirm `agent_id` is present and non-null.

If both behave as documented (main = absent/null, sub-agent =
populated), the discrimination check
`[ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ]` works.

If main session ALSO has `agent_id` set to some value (e.g., the
session ID), you need a different discriminator — probably
`tool_input.file_path` vs `cwd` (always treat absolute paths
outside the project as suspicious regardless of session).

---

## 4. Implementation

### 4.1 The hook script

**File:** `.claude/hooks/enforce-worktree-writes.sh`

```bash
#!/bin/bash
# PreToolUse hook: block sub-agent writes outside their worktree.
#
# Reads the hook JSON on stdin, inspects the tool call, and either:
#   - exit 0: allow (main session, or sub-agent write inside its
#     worktree, or non-Write/Edit tool)
#   - exit 2: block (sub-agent write outside its worktree); stderr
#     becomes the rejection reason shown to the agent
#
# Logs every blocked attempt to:
#   $CLAUDE_PROJECT_DIR/.claude/audit/worktree-write-violations.log

set -euo pipefail

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Main session: no agent_id (or null). Allow everything.
if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ]; then
  exit 0
fi

# Sub-agent + Write/Edit: enforce path is inside CWD (the worktree).
# Other tools (Bash, Read, Grep, etc.) pass through unmodified —
# see §1.4 "Out of scope" for the Bash gap.
if [[ "$TOOL_NAME" =~ ^(Write|Edit)$ ]] && [ -n "$FILE_PATH" ]; then
  # Resolve to absolute path.
  if [[ "$FILE_PATH" = /* ]]; then
    ABS_PATH="$FILE_PATH"
  else
    ABS_PATH="$CWD/$FILE_PATH"
  fi

  # Normalise (resolve .. / . / double slashes). realpath handles
  # this safely even if the file doesn't exist yet, as long as the
  # parent dir exists.
  if [ -e "$(dirname "$ABS_PATH")" ]; then
    NORM_PATH=$(cd "$(dirname "$ABS_PATH")" && pwd)/$(basename "$ABS_PATH")
  else
    NORM_PATH="$ABS_PATH"  # best effort; let downstream catch missing dir
  fi

  # Check: NORM_PATH must start with CWD.
  if [[ "$NORM_PATH" == "$CWD"* ]]; then
    exit 0
  fi

  # Outside the worktree — block.
  LOG_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/audit"
  mkdir -p "$LOG_DIR"
  echo "[$(date -Iseconds)] agent_id=$AGENT_ID tool=$TOOL_NAME blocked=$NORM_PATH worktree=$CWD" \
    >> "$LOG_DIR/worktree-write-violations.log"

  {
    echo "BLOCKED: sub-agent ($AGENT_ID) attempted to $TOOL_NAME outside its worktree."
    echo ""
    echo "  Attempted path:  $NORM_PATH"
    echo "  Worktree root:   $CWD"
    echo ""
    echo "Use a path relative to your worktree, or prefix with \$WORKTREE_ROOT."
    echo "Example: instead of '/home/scott/projects/foo/bar.py',"
    echo "         use '$CWD/bar.py' or 'bar.py' (relative to CWD)."
  } >&2

  exit 2
fi

# Non-Write/Edit tool, or no file_path — pass through.
exit 0
```

Make executable:

```bash
chmod +x .claude/hooks/enforce-worktree-writes.sh
```

### 4.2 The settings entry

**File:** `.claude/settings.json` (create or merge):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/enforce-worktree-writes.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

If `.claude/settings.json` already exists with other config, merge
the `hooks.PreToolUse` array into the existing structure.

### 4.3 Optional debug hook (for the empirical test)

For the one-time `agent_id` discrimination test (§3.4), use this
instead of the enforcement hook:

**File:** `.claude/hooks/debug-pretooluse.sh`

```bash
#!/bin/bash
# Debug hook: log every PreToolUse JSON input for inspection.
# Use ONLY during initial setup to confirm agent_id behaviour.
INPUT=$(cat)
LOG_DIR="${CLAUDE_PROJECT_DIR:-/tmp}/.claude/audit"
mkdir -p "$LOG_DIR"
echo "$INPUT" | jq -c '{ts: now | todate, session_id, agent_id, agent_type, tool_name, cwd}' \
  >> "$LOG_DIR/cc-hook-debug.log"
exit 0
```

Wire via the same `settings.json` but point at this script
temporarily. Run one main-session Write + one sub-agent Write. Read
the log. Decide if the enforcement hook's `agent_id` check needs
adjustment.

### 4.4 File layout

```
<project>/
├── .claude/
│   ├── settings.json                          ← committed
│   ├── hooks/
│   │   ├── enforce-worktree-writes.sh         ← committed, chmod +x
│   │   └── debug-pretooluse.sh                ← committed, chmod +x (optional)
│   └── audit/                                 ← gitignored (created by hook)
│       ├── worktree-write-violations.log
│       └── cc-hook-debug.log                  (during the empirical test)
└── .gitignore
    └── .claude/audit/                         ← add this line
```

---

## 5. Testing, Limitations, Distribution

### 5.1 Test plan

**Pre-deployment empirical test:**

1. Install the debug hook (§4.3).
2. In your main Claude Code session, do `Write` (e.g., touch a
   README). Inspect `.claude/audit/cc-hook-debug.log` — confirm
   `agent_id` is empty or `null`.
3. Dispatch a worktree-isolated sub-agent that does any `Write`.
   Inspect the new log entry. Confirm `agent_id` is set.
4. Disable the debug hook (delete from settings.json or comment
   out).

**Enforcement test:**

5. Install the enforcement hook.
6. Dispatch a worktree sub-agent. In its prompt, instruct it to
   "write a file at /home/<you>/projects/<project>/test_drift.tmp".
7. Confirm the agent receives a "BLOCKED: ..." error and either
   recovers (writes to the worktree instead) or fails the task
   loudly.
8. Inspect `.claude/audit/worktree-write-violations.log` — confirm
   the block was recorded.

**Regression test:**

9. Confirm main-session Writes still work normally (no false
   positives).
10. Confirm sub-agent Writes INSIDE the worktree still work (e.g.,
    `<worktree-root>/foo.py`).

### 5.2 Known limitations

- **Bash gap.** A sub-agent doing `Bash(command="cat > /home/.../foo
  <<EOF\n...EOF")` bypasses the hook (no `file_path` to inspect).
  Bash commands are arbitrary strings — parsing them deterministically
  is hard. Mitigation: a second `PreToolUse` hook with
  `matcher: "Bash"` that regex-blocks the obvious patterns (`> /`,
  `tee /`, `cp ... /`). Punted to v2.
- **Symlink ambiguity.** If the project uses symlinks (e.g., a
  shared `docling_cache` symlinked into the worktree), the `cd
  && pwd` normalisation may resolve to an external path even
  though the agent intends it as worktree-local. Fix: use Python's
  `os.path.realpath` instead of bash `cd && pwd`, and add an
  allowlist of "external-but-fine" symlinks.
- **Race condition on first sub-agent dispatch.** If the project
  was freshly cloned and the hook script isn't executable yet
  (`chmod +x` not run), Claude Code will treat it as a hook error
  and let the tool call through. Mitigation: a one-time post-clone
  bootstrap that `chmod`s all hook scripts.
- **No protection from another running Claude Code session.** Hook
  applies only to sub-agents OF THE CURRENT session. If you have
  two Claude Code sessions open, each will only police their own
  sub-agents. Acceptable for single-developer setups.

### 5.3 Future work

- **Bash command guard** (v2): parse common write-outside patterns
  in Bash commands.
- **Audit dashboard:** a small Python script that reads
  `worktree-write-violations.log` and surfaces "agent X tried to
  drift Y times this session" to the orchestrator.
- **Inter-session lock:** record the active worktree root per
  session in a small SQLite db; reject any write to a path that's
  already a different session's worktree.
- **Plugin packaging:** see §5.4.

### 5.4 Distribution as a Claude Code plugin

Claude Code supports plugins as installable units (drop-in
`~/.claude/plugins/<name>/` directories). To package this as a
shareable plugin:

```
worktree-write-guard/
├── plugin.json                                ← plugin metadata
├── hooks/
│   └── enforce-worktree-writes.sh
└── README.md                                  ← installation steps
```

**plugin.json:**

```json
{
  "name": "worktree-write-guard",
  "version": "0.1.0",
  "description": "Prevents sub-agents dispatched with Agent(isolation:'worktree') from writing outside their worktree.",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/enforce-worktree-writes.sh",
        "timeout": 5
      }
    ]
  }
}
```

**Installation by a user:**

```bash
git clone https://github.com/<you>/worktree-write-guard ~/.claude/plugins/worktree-write-guard
chmod +x ~/.claude/plugins/worktree-write-guard/hooks/*.sh
```

Or via Claude Code's plugin install command if/when one ships.

Publish on GitHub with a README explaining the problem this solves
and the empirical-test procedure (§5.1). Likely first plugin in the
ecosystem for this use case — community will find it.

---

## Appendix A — Build checklist for the independent project

1. [ ] Create `worktree-write-guard/` directory.
2. [ ] Write `hooks/enforce-worktree-writes.sh` (copy §4.1).
3. [ ] `chmod +x hooks/enforce-worktree-writes.sh`.
4. [ ] Write `hooks/debug-pretooluse.sh` (copy §4.3).
5. [ ] `chmod +x hooks/debug-pretooluse.sh`.
6. [ ] Write `plugin.json` (copy §5.4).
7. [ ] Write `README.md` covering: what it solves, the empirical
       test procedure, the enforcement test procedure, known
       limitations.
8. [ ] In a TEST PROJECT (NOT production), install the debug hook,
       run the empirical test (§3.4 / §5.1 steps 1–4). Note
       whether `agent_id` is absent/null in main session.
9. [ ] Adjust the enforcement script's discrimination check based
       on step 8 findings.
10. [ ] Install the enforcement hook in the test project, run the
        enforcement test (§5.1 steps 5–8).
11. [ ] Run the regression test (§5.1 steps 9–10).
12. [ ] If all green: tag v0.1.0, push to GitHub, publish.
13. [ ] Install in `finance_nexus` (or any project that uses
        multi-agent worktrees).

---

## Appendix B — Things to confirm with Claude Code docs before
building

These are claims in this plan that depend on Claude Code's current
behaviour. Confirm against
[docs.claude.com/en/docs/claude-code/hooks](https://docs.claude.com/en/docs/claude-code/hooks)
(or wherever the canonical docs live at build time):

1. PreToolUse hook fires for sub-agent tool calls (not just main
   session) — **assumed true** based on the docs saying "hooks
   fire on every tool use".
2. `agent_id` field is present in PreToolUse JSON for sub-agent
   calls — **needs empirical confirmation** (§3.4).
3. Exit code `2` from a hook blocks the tool call and surfaces
   stderr to the agent — **assumed true** based on the docs'
   exit-code table.
4. `${CLAUDE_PROJECT_DIR}` is available in `settings.json` `command`
   strings — **assumed true** based on the docs' env-var reference.
5. The `matcher` field accepts a regex against `tool_name` —
   **assumed true** based on docs.

If any of these turn out false at build time, the plan adjusts:

- If (1) is false: this whole approach doesn't work. Fall back to
  post-tool detection + `git status` reconciliation.
- If (2) is false: use a different discriminator (e.g., parse
  `cwd` against a known main-checkout path).
- If (3) is false: use the JSON output variant
  (`{"permissionDecision": "deny"}`).
- If (4) is false: hardcode the project path or use a relative
  path from `.claude/`.
- If (5) is false: split into two separate hook entries (one for
  Write, one for Edit).
