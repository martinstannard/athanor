# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Search past session transcripts from `recall` (scope `transcripts`) (#41)
- TUI header: show how full the active session's context is (#43)
- Add /stats command: tokens, turns, tool calls and estimated cost (#26)
- Cap concurrent worktrees in Athanor.Worktree.Server (design §7.1 OQ-W8) (#38)
- Add hierarchical memory system (Athanor.Memory) (#6)
- Support pasting multi-line text blocks into the TUI prompt, with bracketed-paste detection so a pasted block is never mistaken for a typed Enter (#34)
- Add a log file for the detached Athanor daemon (#13)
- Add a `/clear` TUI command that resets a session's conversation context in place, without restarting the daemon or spawning a new session (#31)
- Stack prompts while a session is streaming, with a pending-queue indicator and `/clear-queue` / `/unqueue` to drop the stack or its newest entry (#18)
- Add a `/kill <id>` TUI command that removes a running session (a bare `/kill` lists what is running); only the process dies, so the transcript is kept and `/resume` can still offer it. A mid-turn session needs `--force` (#19)

### Fixed
- resume_all silently drops sessions: --resume reports success while skipping some (or all) (#46)
- `ProjectContext.load/1` looped forever when the working directory had no `.git` boundary, hanging an agent at init (#45)
- GoalManagerTest flake: 'a verified result closes the goal' races Process.alive? (#42)
- Test suite is red when run from a default worktree (~/.athanor/worktrees) (#40)
- TUI is silent when wedged: no activity indicator, no daemon connectivity, discarded command failures (#24)

### Changed
- `/.athanor/` (harness memory for a checkout) is gitignored as runtime state; commit a curated `MEMORY.md` with `git add -f` (#46)
- `learnings.jsonl` compacts itself past 256 KB (`ATHANOR_MEMORY_COMPACT_BYTES`) (#41)
- TUI header: show daemon connectivity (#25)
- Document deps/_build bootstrap for fresh worktrees (design §7.1 OQ-W5) (#39)
- `write_file`/`edit_file` now refuse to modify an existing file the session has not read; creating a new file is unaffected. Disable with `ATHANOR_TOOL_GUARD=0` (#7)
- Document chainlink's single-session-per-database model and its multi-agent workarounds (#32)
