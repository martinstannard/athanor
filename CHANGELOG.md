# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `meta.json` records the session's `cd` and, for a worktree-isolated session, `worktree_path` — both written by the Recorder from the Agent's session snapshot — so a resume can tell "never had a worktree" from "its worktree is gone" instead of inferring both from a path that was never stored (#58)
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
- `Athanor.Memory` resolved the **project** tier from `:cd`/`File.cwd!()` and ignored `:root`, so a call that explicitly scoped itself to a scratch directory still read the ambient checkout's `.athanor/learnings.jsonl` — ascension, following a worktree's `.git` pointer to the main repo when there was one. Any `remember`ed fact whose text contained a word an unrelated test asserted against then failed that test repo-wide, for every developer and every CI run on that checkout, until the entry was forgotten. An explicit `root:` is now authoritative and **literal** across `remember`/`recall`/`forget`/`distill`/`resolve` — project tier `<root>/.athanor`, global tier `<root>/memory`, no ascent — so a `:root` can no longer escape into the ambient repo. Production callers pass `cd` and never `root`, so their behaviour is unchanged, and `global_dir:` still wins over `root:` (#51)
- Resumed worktree workers came back with `cd` set to the **main checkout** and silently edited it: `Orchestrator` only computed the worktree on the create path, so `--resume` rebuilt every session from a `meta.json` that never held the worktree path, and a *relative* `edit_file`/`write_file` then landed in `main` while the worker's own tree stayed clean. A resume now reinstates the worktree (from `Athanor.Worktree.Server`'s mapping, or from the `worktree_path` the record now carries) and reports a worktree that no longer exists as skipped (`{:worktree_missing, path}`) rather than quietly reopening the repository root (#58)
- Resolved-goal ETS table grew for the daemon's whole lifetime: records now carry the monotonic time they resolved at (`{id, status, resolved_at_ms}`) and are swept once older than `ATHANOR_GOAL_RESOLVED_RETENTION_MS` (default 1h, well beyond any plausible worker lifetime) — on the goal manager's periodic tick and at every insert — so a terminal goal stops occupying the table without ever forgetting the recent past that #50's late-completion accounting depends on (#55)
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
- The TUI no longer makes any *awaited* daemon call on its input/render loop (#54). `Enter`/prompt submit, the queue verbs and `Esc`'s cancel are delivered one-way through the new `Athanor.Daemon.cast/4` (`:erpc.cast/4` against a remote daemon, a direct call locally); the reply-bearing verbs (`/spawn`, `/conductor`, `/kill`, `/resume`, `/clear`) run in a `Task` whose result the loop applies as a later message. Bounding those calls was not enough — a loaded or wedged daemon still parked the only process that reads keys or renders, which is indistinguishable from a frozen UI
- `/.athanor/` (harness memory for a checkout) is gitignored as runtime state; commit a curated `MEMORY.md` with `git add -f` (#46)
- Document deps/_build bootstrap for fresh worktrees (design §7.1 OQ-W5) (#39)
- `learnings.jsonl` compacts itself past 256 KB (`ATHANOR_MEMORY_COMPACT_BYTES`) (#41)
- TUI header: show daemon connectivity (#25)
- `write_file`/`edit_file` from a session that has a worktree now refuse a path inside a *different* git working tree (such as the main checkout it was branched from), which is the shape of the #58 breach that `cd` cannot protect against — an absolute path names a checkout directly. Paths inside its own worktree, paths outside any repository, and every read are unaffected (#58)
- `write_file`/`edit_file` now refuse to modify an existing file the session has not read; creating a new file is unaffected. Disable with `ATHANOR_TOOL_GUARD=0` (#7)
- Document chainlink's single-session-per-database model and its multi-agent workarounds (#32)
