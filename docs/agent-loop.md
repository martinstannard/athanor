# How an Agent Loop Works

At its core, an AI agent is a loop around an LLM API call that continues executing until the model stops requesting tool calls.

## 1. The Core Loop

A standard chat interaction is a single round-trip: `User -> LLM -> User`.

An **agent** introduces a feedback loop with **tools** (functions the harness can execute on the model's behalf):

```text
[User Prompt]
      │
      ▼
┌───────────────────────────────────────────────────┐
│ 1. Append message to conversation history         │
│ 2. Send (history + tool_schemas)                  │──► LLM API (Streaming)
│    history[0] is the system prompt                │
│ 3. Receive assistant message                      │◄──
└─────────────────────┬─────────────────────────────┘
                      │
         Does the response contain tool_calls?
             /                        \
           YES                         NO
           /                            \
          ▼                              ▼
┌───────────────────────────┐   ┌───────────────────┐
│ For each tool_call:       │   │ Done! Return      │
│  - Execute local function │   │ final text to TUI │
│  - Format tool_result     │   │ and wait for user │
│  - Append to history      │   └───────────────────┘
└─────────────┬─────────────┘
              │
              └──────► (Loop back to step 2!)
```

### Key Principles

1. **The LLM never executes code directly.**
   It only emits structured JSON requesting a tool call (e.g., `read_file` with `{"path": "mix.exs"}`).
2. **The Harness is in control.**
   The Elixir harness validates the arguments, enforces a wall-clock timeout on shell commands, executes the function locally, captures stdout/stderr or return values, appends a `role: "tool"` result message to the conversation history, and calls the LLM again.
3. **Self-correction comes for free.**
   If a tool fails (e.g. `{:error, "Failed to read missing.txt: no such file or directory"}`), the harness turns it into an `"Error: …"` tool result. On the next iteration of the loop, the LLM reads the error and adjusts its approach.

## 2. Message History Shape

During a single user request, the conversation history grows across turns of the loop. In Athanor the
history is a plain list of maps threaded through `Athanor.Agent` (`lib/athanor/agent.ex`) and
serialised by `Athanor.LLM.format_messages/1` (`lib/athanor/llm.ex`):

1. `%{role: "system", content: "…"}` — instructions and environment context (always `messages[0]`).
2. `%{role: "user", content: "Read mix.exs and tell me the Elixir version."}`
3. `%{role: "assistant", content: "", tool_calls: [%{id: "call_1", type: "function", function: %{name: "read_file", arguments: "{\"path\":\"mix.exs\"}"}}]}`
   — note that `arguments` is a **JSON-encoded string**, not a map, and the name is nested under
   `function`.
4. `%{role: "tool", tool_call_id: "call_1", content: "defmodule Athanor.MixProject do ... elixir: \"~> 1.19\" ..."}`
5. `%{role: "assistant", content: "The project uses Elixir ~> 1.19.", tool_calls: []}` → **Loop terminates** (no `tool_calls`).

## 3. Athanor Specifics

- **The loop lives in `Athanor.Agent`.** `start_llm_turn/1` runs the completion inside a
  `spawn_monitor`ed process (so the GenServer is never blocked) and forwards `{:llm_delta, chunk}`
  messages as `{:text_delta, chunk}` events. `start_tool_execution/2` then executes the requested
  tools **sequentially** (a plain `Enum.map`, not `Task.async_stream`) and loops back.
- **Loop bound.** `max_turns` (default 100) caps how many tool-execution rounds a single user prompt
  may take; exceeding it moves the session to `:error`.
- **Completion sentinel (worker convention).** The worker system prompt instructs the model to end
  its final message with `===ATHANOR_DONE=== status=ok|fail summary=<one line>`
  (`Athanor.Agent.parse_done_sentinel/1` also accepts the legacy `===AGENTDECK_DONE===` spelling).
  The sentinel does not end the loop — the loop ends when the model returns no `tool_calls`. It is
  how a sub-agent tells its Conductor that it is finished, and the Conductor sees it as a
  `[DONE] Sub-agent '…' (…) finished: status=… summary=…` message.
