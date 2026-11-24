---
name: blacksmith-continue
description: Prepare a durable context handoff for ongoing Blacksmith VR implementation when conversation history is heavy and the next issue is independently resumable; start a separate continuation task only when explicitly requested by the user.
---

# Blacksmith continuation

Use the repository's AGENTS.md and live Git/GitHub state as authority. Preserve
the user's standing authorization to implement issue by issue and merge PRs after
current-head CI passes. A context handoff must not turn sustained work into
repeated permission requests or treat unvalidated M0 work as finished.

## Choose a useful boundary

Continue working when the current issue still benefits from recent debugging or
design context. Prefer finishing its tests, PR and merge before handing off.
Heavy context plus a separately resumable next issue is a useful boundary; the
mere completion of a PR is not. Do not defer authorized work just to generate a
handoff. A playable testing checkpoint or real blocker follows AGENTS.md instead.

## Make state durable

Create a tracking issue before new documentation work if no existing issue covers
it. Update AGENTS.md's API/state notes and record a concise handoff in the current
issue or an issue-linked repository file. Include:

- Current commit/branch, merged PRs and next issue with acceptance criteria.
- What is implemented, measured and untested; exact working verification commands.
- Relevant accepted decisions and remaining questions/dependencies.
- Uncommitted changes with ownership; preserve other agents' and the user's work.

Prefer links to maintained code/docs over copying conversation history. Never
write secrets, credentials or full tool dumps. Verify git status and issue/CI
state before claiming a clean or merged checkpoint.

## Continue in a fresh task when authorized

Discover available task tools. The host's `mcp__codex_tui__create_thread` requires
an explicit user request for a new task; creating this skill or a general wish to
reduce context does not remove that requirement. If the user explicitly requests
starting a separate continuation task, use it with a concise prompt (at most
1,000 UTF-8 bytes) pointing to AGENTS.md, the durable handoff and the next issue.
Omit model overrides unless requested. Prefer a fresh task to a fork carrying the
heavy history. Do not start concurrent writers to the same worktree.

After acknowledged creation, report the returned task identifier and stop editing
in the old task. Do not archive a parent task in a way that might stop its new
continuation. If creation fails ambiguously, check for the returned task before
retrying to avoid duplicate workers. Do not claim a task exists without tool
confirmation, or claim to have cleared the current conversation.

If explicit new-task authorization or the tool is unavailable, provide a ready
prompt such as: "Read AGENTS.md and the handoff on issue #N. Continue issue #M,
merge after CI passes, and keep working under the repository workflow." Suggest
opening a fresh session at that boundary. Keep working when no handoff boundary
or real stopping condition has been reached.
