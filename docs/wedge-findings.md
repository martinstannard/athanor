# Wedge findings (live debugging session)

Date: 2026-10-16. Author: Athanor conductor, while debugging "everything keeps getting
wedged; Esc doesn't cancel anything".

This is the evidence log. The fixes live in the code; this file records *why*.

## How the evidence was gathered

A live system was inspected over Erlang distribution (`:erpc` into
`athanor_daemon@127.0.0.1`): process counts, per-process `message_queue_len`/`status`/
`current_function`, ports, `Registry.lookup(Athanor.AgentRegistry, …)`, and
`sched:get_state/1` of live agents. Reproductions were run in isolated `mix run` VMs.

## Confirmed live state

- Daemon `athanor_daemon@127.0.0.1`, `conductor-main` was **`status=:executing_tools`**,
  `turn_count=26`, with a **live `current_task`** and a **`/usr/bin/bash` port open**
  (`Port<…302>`, `os_pid` a `sleep` descendant).
- Several **stale TUI client nodes** (`athanor_tui_*`) plus stale `epmd` registrations.
- The only on-disk artifact for a crash is `erl_crash.dump`; **there is no application
  log file** (called out in `docs/handover.md` §5). The detached daemon's `Logger` output
  goes nowhere.

## Confirmed reproductions

1. **Bash tool leaks its OS child on timeout.** `Tools.execute("bash", %{"command" =>
   "exec sleep 900"}, timeout: 300)` returns
   `{:error, "Command timed out after 300ms"}` but a **new `sleep` process is left
   running** (`=> LEAKED 1 process(es)`). `Task.shutdown/1` kills the Erlang task (closing
   its port) but the OS child is not in the task's process group, so it survives.

2. **`:erpc.call/4` has an `:infinity` timeout.** `lib/athanor/daemon.ex`'s `rpc/4` calls
   `:erpc.call(node, module, function, args)` — arity 4 — whose default is `:infinity`
   (verified in `kernel-10.5/src/erpc.erl`: `-spec call/4 … default: infinity`). Every
   TUI→daemon RPC (`send_session`, `cancel_session`, `launch_subagent`,
   `start_conductor`, `resume_*`) therefore blocks the **single** TUI loop process
   forever if the daemon is slow/wedged/unreachable-but-connected.

3. **Process-group kill via `setsid` is unreliable here.** `setsid --wait` *forks*, so the
   port's `os_pid` is the wrapper, not the new group leader, and `kill -TERM -<os_pid>`
   misses (`kill: sending signal to -<pid> failed: No such process`). Plain `setsid`
   likewise left the real children in a different group. The shipped fix therefore walks
   the process **tree** from the port's `os_pid` (recursively collecting descendants
   *before* signalling) and TERMs/KILLs them bottom-up — verified to reap both an `exec`'d
   child and a `bash -c` that backgrounded children.

4. **Streaming re-render is O(transcript) per token.** `Athanor.TUI.render_frame/1`
   re-renders the whole transcript for every `{:text_delta, _}`. Measured: `~20ms` per
   token at a 150-turn / ~450-entry transcript (`500 renders: 9913ms`). A fast token
   stream saturates the TUI loop, so input (Esc) queues behind a growing delta backlog —
   the UI looks frozen.

5. **Esc is gated on the TUI's *cached* status.** `handle_key(tui, "\e")` cancels only
   when `active_status(tui) != :idle`; that value is a client-side cache updated by
   relayed `{:status, _}` events. If the cache is stale/missed, Esc is a silent no-op
   even though the daemon-side session is busy. And even when it does dispatch, it then
   hits finding #2.

6. **In-flight tasks have no watchdog.** `Athanor.Agent` `spawn_monitor`s the LLM/tool
   task and waits for its result; the only bound is the transport's own timeout
   (`receive_timeout: 120_000` for the LLM, `30_000` for bash). Nothing catches a task
   that hangs *past* those, and nothing logs/trips a wedge.

## Root-cause summary (as shipped)

| # | Mechanism | Symptom | Fix (commit: this change) |
|---|---|---|---|
| 1 | `:erpc.call/4` = infinity for every TUI→daemon RPC | Esc / submit freeze the whole UI | `Athanor.Daemon.rpc/4` is public and bounds the call with `Athanor.Config.rpc_timeout_ms/0`, returning `{:error, :rpc_timeout}`/`{:error, :rpc_failed}`; TUI dispatch surfaces the failure instead of crashing |
| 2 | Esc gated on cached status | "Esc does nothing" | `handle_key(tui, "\e")` now always returns `{:cancel, tui}`; the agent makes an idle cancel a cheap no-op |
| 3 | O(n) render per delta, no coalescing | streaming "wedge" | `Athanor.TUI.drain_pending_events/1` folds a queued token burst into one state update before the next render |
| 4 | bash child outlives its task | leaked OS processes | `Tools` spawns the port directly, reports `os_pid`, and on timeout walks the process tree bottom-up (TERM then KILL), not just closing the port |
| 5 | no task watchdog | stuck turn never recovers | `Athanor.Agent` arms a `turn_timeout_ms` watchdog per LLM/tool task; on expiry it kills the task, transitions to `:error` and logs a `wedge` event |
| 6 | no on-disk log | nothing to diagnose later | `Athanor.Log` installs a rotating file handler at `<home>/logs/athanor.log` at boot, plus `event/2` and `wedge/2` helpers |

## Bonus: the tool-call budget itself

While debugging this, a live conductor session hit the harness's own
`max_turns`/tool-call cap — a reminder that a runaway *loop* (rather than a hang) is the
other way a session can look wedged. The `turn_timeout_ms` watchdog and the existing
`max_turns` bound now cover both: the first catches a task that never returns, the second
a loop that keeps returning.

## Later find (2026-10-16, while implementing #28)

7. **Stacking a prompt on a busy agent replaced the agent's state with `:ok`.**
   `Athanor.Agent.notify_prompt_queue/1` ended on `notify/2`, which returns
   `Athanor.Bus.publish_event/3`'s `:ok`, and three callers use it as their return value
   (`do_enqueue_prompt/2` while the agent is busy, `do_clear_prompt_queue/1`, and `do_cancel/1`
   through it). So `{:noreply, ...}` / `{:reply, :ok, ...}` handed `:ok` back as the GenServer
   *state*. Every subsequent message then failed to match its handler and fell through to
   `handle_info(_msg, state)` — the session stopped reacting with nothing in the log, the same
   "wedged, no evidence" shape as the rest of this document. It is reachable from the TUI and from
   `Orchestrator.send_session/2`, both of which stack prompts over PubSub rather than by reply.
   No test covered prompt stacking at all.

   Fixed by returning the state explicitly from `notify_prompt_queue/1`; the regression test
   stacks a prompt onto a busy agent and requires the turn to complete afterwards.
   (Same family as #1–#6: a value that is not the state reaching the state slot.)
