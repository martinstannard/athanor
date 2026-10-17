# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Add hierarchical memory system (Athanor.Memory) (#6)
- Support pasting multi-line text blocks into the TUI prompt, with bracketed-paste detection so a pasted block is never mistaken for a typed Enter (#34)
- Add a log file for the detached Athanor daemon (#13)
- Add a `/clear` TUI command that resets a session's conversation context in place, without restarting the daemon or spawning a new session (#31)
- Stack prompts while a session is streaming, with a pending-queue indicator and `/clear-queue` / `/unqueue` to drop the stack or its newest entry (#18)
- Add a `/kill <id>` TUI command that removes a running session (a bare `/kill` lists what is running); only the process dies, so the transcript is kept and `/resume` can still offer it. A mid-turn session needs `--force` (#19)

### Fixed
- Test suite is red when run from a default worktree (~/.athanor/worktrees) (#40)
- TUI is silent when wedged: no activity indicator, no daemon connectivity, discarded command failures (#24)

### Changed
- Document chainlink's single-session-per-database model and its multi-agent workarounds (#32)
