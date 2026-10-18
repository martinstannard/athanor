# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Pick up a stacked prompt between tool rounds, not only when a whole task finishes: a prompt enqueued while a tool loop is running is appended as a `user` message at the next tool-round boundary (exactly one per round, FIFO), so a follow-up typed mid-task reaches the model without cancelling the turn. `ATHANOR_MID_TURN_QUEUE=0` restores the old "wait for the task" behaviour; a session with a live goal always waits (#44)
- Add Agent Skills support (`Athanor.Skills`): discover `SKILL.md` bundles from ordered roots (`~/.agents/skills`, then `~/work/skills/.agents/skills`; `ATHANOR_SKILL_PATHS`), resolve symlinks and de-duplicate by name (later root wins, so workspace overrides global). A conductor's system prompt carries a short name+description catalogue and the `skill(name)` tool loads one full skill on demand, so bodies never bloat the prompt (#23)
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
- GoalManager escalated healthy goals: a contradicted verifier verdict was treated as evidence of idleness, so a `:streaming` worker was nudged on every tick and escalated within ~90s. The budget now counts *consecutive unproductive* ticks — reset only by a `report_progress` receipt or a `:verified` verdict, never by a completion claim or a bare turn boundary, so the escalation path cannot be cleared by the very nudge it answers — and a stalled worker must be genuinely quiet (#48)
- Goal nudges never reached the worker: they were queued on the conversational prompt queue, which a goal-attached session never drains mid-task (#44), so the remedy sat behind the condition it had to cure. Nudges now travel a separate control plane drained at tool-round boundaries, gated independently of `mid_turn_injection?/1`, and delivery is reported separately from sending (`nudges_delivered` vs `nudge_count`) (#49)
- A `set_goal` shell verifier that could pass on partial work closed the goal early and swallowed the worker's real completion: closure now requires the worker's own `===ATHANOR_DONE===` claim *and* a `:verified` verdict, and a resolved goal no longer mutes its worker's later completion to the parent (#50)
- resume_all silently drops sessions: --resume reports success while skipping some (or all) (#46)
- `ProjectContext.load/1` looped forever when the working directory had no `.git` boundary, hanging an agent at init (#45)
- GoalManagerTest flake: 'a verified result closes the goal' races Process.alive? (#42)
- Test suite is red when run from a default worktree (~/.athanor/worktrees) (#40)
- TUI is silent when wedged: no activity indicator, no daemon connectivity, discarded command failures (#24)

### Changed
- Isolate parallel workers' builds: `Worktree.add/2` now seeds a worktree-local `_build` (self-ignoring, never clobbering an existing one), and the private-`_build` rule — build with your own `_build`, **never** symlink it into another checkout; `deps` may be symlinked — is stated in the worker system prompt and both worktree tool messages. A `_build` symlink is warned about rather than written through. Two workers sharing a `_build` corrupt each other's `.beam` files *silently*, which made a `mix check` verdict (and `set_goal`'s shell verifier) unsound (#47)
- `/.athanor/` (harness memory for a checkout) is gitignored as runtime state; commit a curated `MEMORY.md` with `git add -f` (#46)
- Document deps/_build bootstrap for fresh worktrees (design §7.1 OQ-W5) (#39)
- `learnings.jsonl` compacts itself past 256 KB (`ATHANOR_MEMORY_COMPACT_BYTES`) (#41)
- TUI header: show daemon connectivity (#25)
- `write_file`/`edit_file` now refuse to modify an existing file the session has not read; creating a new file is unaffected. Disable with `ATHANOR_TOOL_GUARD=0` (#7)
- Document chainlink's single-session-per-database model and its multi-agent workarounds (#32)
