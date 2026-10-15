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
│ 2. Send (system_prompt + history + tool_schemas)  │──► LLM API (Streaming)
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
   The Elixir harness validates the arguments, enforces permissions or timeouts, executes the function locally, captures stdout/stderr or return values, appends a `role: "tool"` result message to the conversation history, and calls the LLM again.
3. **Self-correction comes for free.**
   If a tool fails (e.g., `{:error, :enoent}`), the harness returns the error string as the tool result. On the next iteration of the loop, the LLM reads the error and adjusts its approach.

## 2. Message History Shape

During a single user request, the conversation history grows across turns of the loop:

1. `system`: Instructions and environment context.
2. `user`: `"Read mix.exs and tell me the Elixir version."`
3. `assistant`: `content: ""`, `tool_calls: [%{id: "call_1", name: "read_file", arguments: %{"path" => "mix.exs"}}]`
4. `tool` (`tool_call_id: "call_1"`): `"defmodule Athanor.MixProject do ... elixir: \"~> 1.19\" ..."`
5. `assistant`: `content: "The project uses Elixir ~> 1.19."`, `tool_calls: []` -> **Loop terminates.**
