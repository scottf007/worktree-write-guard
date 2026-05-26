# worktree-write-guard

A Claude Code `PreToolUse` hook that **prevents sub-agents dispatched
with `Agent(isolation: "worktree")` from writing files outside their
worktree**. Stops the "absolute-path drift" class of bug where a
sub-agent forgets the worktree boundary mid-run and clobbers the
main checkout.

Status: **v0.1 — needs empirical verification (§ Test) before relying
on it.** See [worktree_write_guard_plan.md](./worktree_write_guard_plan.md)
for the full design rationale.

## What it catches

Two hooks run on every sub-agent tool call:

1. **`Write` / `Edit` / `MultiEdit` / `NotebookEdit`** — rejects if
   `tool_input.file_path` resolves outside the sub-agent's CWD (its
   worktree root).
2. **`Bash`** — pattern-matches the command string for write targets
   outside the worktree:
   - redirection: `> /path`, `>> /path`
   - `tee /path`
   - `cp` / `mv` / `rsync ... /path`
   - `dd of=/path`

`/tmp`, `/dev`, `/proc`, `/var/tmp` are allowlisted as never-the-main-checkout.

Main-session tool calls are always allowed — the discriminator is the
`agent_id` field in the PreToolUse JSON input (present only inside
sub-agents).

## What it doesn't catch

- Bash writes that hide the destination behind shell substitution
  (`cp $(foo) /bad`, `> $HOME/bad`)
- Exotic redirection (process substitution, here-strings to weird
  destinations)
- Anything the agent does via MCP servers (those run unconstrained;
  see Anthropic sandbox docs)

For full coverage you also need an OS-level sandbox (bubblewrap,
landlock). This hook closes ~95% of drift without one.

## Install

### As a plugin (cross-project, recommended)

```bash
git clone https://github.com/scott-fletcher/worktree-write-guard \
  ~/.claude/plugins/worktree-write-guard
chmod +x ~/.claude/plugins/worktree-write-guard/hooks/*.sh
```

Claude Code picks up `plugin.json` and the bindings in
`hooks/hooks.json` automatically on next session start.

### As a project-local hook (single repo)

```bash
mkdir -p .claude/hooks
cp path/to/this/repo/hooks/enforce-worktree-writes.sh .claude/hooks/
cp path/to/this/repo/hooks/enforce-worktree-bash.sh .claude/hooks/
chmod +x .claude/hooks/*.sh

# Merge examples/settings.json into your .claude/settings.json
```

See [examples/settings.json](./examples/settings.json) for the exact
`hooks` block to merge.

## Test (do this before trusting the guard)

Anthropic issue [#23889](https://github.com/anthropics/claude-code/issues/23889)
documents that hooks "correctly configured in parent may silently fail
in subagent/MCP contexts." Verify the discrimination works in your
Claude Code version **before** relying on the enforcement hooks.

1. **Install the debug hook** instead of the enforcement hooks. Copy
   `examples/debug-settings.json` to `.claude/settings.json` and
   `hooks/debug-pretooluse.sh` to `.claude/hooks/`.

2. **In a main session**, do any `Write` (e.g. touch a README).
   Inspect `.claude/audit/cc-hook-debug.log` — `agent_id` should be
   `null` or absent.

3. **Dispatch a sub-agent** with `Agent(isolation: "worktree")` that
   does any `Write`. Inspect the new log entry — `agent_id` should be
   a non-null string.

4. If both hold, swap back to the enforcement hooks.

5. If main-session `agent_id` is *also* set, the enforcement scripts
   need a different discriminator — replace the `agent_id` check with
   a CWD-prefix check (`cwd` matches `*/.claude/worktrees/*`).

### Enforcement test

6. With enforcement hooks installed, dispatch a worktree sub-agent.
   Prompt it: *"Write a file at `/tmp/../home/<you>/projects/<repo>/test_drift.tmp`"*
   (absolute path outside the worktree).
7. The agent should receive a `BLOCKED: ...` error.
   `.claude/audit/worktree-write-violations.log` should record the
   attempt.

### Regression test

8. Main-session `Write` still works (no false positives).
9. Sub-agent `Write` *inside* its worktree still works.

## Audit log

Every block is recorded at:

```
$CLAUDE_PROJECT_DIR/.claude/audit/worktree-write-violations.log
```

Format:

```
[2026-05-26T10:00:00+00:00] agent_id=aXXX tool=Write blocked=/home/.../foo worktree=/home/.../.claude/worktrees/agent-aXXX
```

Useful for measuring how often the guard fires — high counts mean
sub-agent prompts need work.

## How it works (one paragraph)

Claude Code fires `PreToolUse` with a JSON payload on stdin. The hook
reads `agent_id` (present iff sub-agent), `tool_name`, `tool_input`,
and `cwd`. If we're in a sub-agent and the tool is a write, it
canonicalises the target path (resolving `..` and symlinks via
`cd && pwd -P`), compares it against the canonicalised worktree root,
and exits `2` (block, stderr → agent) if the path is outside. Main
sessions and reads pass through unmodified.

## Prior art

- [justi/claude-code-project-boundary](https://github.com/justi/claude-code-project-boundary)
  — same idea but scopes to `$CLAUDE_PROJECT_DIR` rather than the
  per-sub-agent worktree. Worth reading.
- [CaptainMcCrank/SandboxedClaudeCode](https://github.com/CaptainMcCrank/SandboxedClaudeCode)
  — OS-level wrapper (bubblewrap/firejail). Complementary, not a
  replacement.
- Anthropic issues [#52988](https://github.com/anthropics/claude-code/issues/52988)
  (Bash escape route around file-tool hooks),
  [#39886](https://github.com/anthropics/claude-code/issues/39886)
  (`isolation: "worktree"` silently failing),
  [#23889](https://github.com/anthropics/claude-code/issues/23889)
  (subagent-context hook silent failures).

## License

MIT
