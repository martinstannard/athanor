# Athanor Architecture

Athanor separates HTTP streaming, state management, tool execution, and terminal rendering into independent BEAM processes that communicate via message passing.

## Module Breakdown

### 1. `Athanor.Tools` (Capabilities)

Defines the tools available to the agent and executes them safely.

- **Foundational Tools**:
  - `read_file` — Read file contents from disk.
  - `write_file` — Create or overwrite a file.
  - `edit_file` — Replace exact text in an existing file.
  - `bash` — Execute a shell command with a timeout.
- **Contract**:
  - `schemas/0` — Returns JSON Schema definitions passed to the LLM API.
  - `execute/2` — Takes `(tool_name, args_map)` and returns `{:ok, output}` or `{:error, reason}`.

### 2. `Athanor.LLM` (OpenCode Go Client)

Stateless HTTP/SSE client built on `Req` targeting the OpenCode Go API (`opencode-go`).

- Sends `(messages, tool_schemas)` with `stream: true`.
- Parses Server-Sent Events (SSE) chunks as they arrive.
- Emits streaming messages to the caller process:
  - `{:llm_delta, text_chunk}`
  - `{:llm_tool_call_delta, tool_call_chunk}`
  - `{:llm_done, assistant_message}`
  - `{:llm_error, reason}`

### 3. `Athanor.Agent` (State Machine / `GenServer`)

Holds the session state and drives the recursive agent loop:

- **State**:
  - `messages`: Ordered list of conversation messages (`system`, `user`, `assistant`, `tool`).
  - `status`: `:idle | :streaming | :executing_tools`.
  - `subscriber`: PID of the consumer (e.g., `Athanor.TUI` or a parent orchestrator).
  - `current_task`: Reference to any in-flight LLM stream or tool execution task (enabling clean cancellation).
- **Lifecycle of `Athanor.Agent.prompt(pid, user_text)`**:
  1. Appends `%{role: "user", content: user_text}` to `messages`.
  2. Sets `status: :streaming` and spawns a monitored `Task` running `Athanor.LLM.stream/3`.
  3. Forwards `{:agent_event, {:text_delta, chunk}}` to `subscriber` in real time.
  4. On `{:llm_done, assistant_msg}`:
     - **No `tool_calls`**: Appends `assistant_msg`, sets `status: :idle`, sends `{:agent_event, :turn_complete}`.
     - **Has `tool_calls`**: Appends `assistant_msg`, sets `status: :executing_tools`, executes requested tools (concurrently via `Task.async_stream` when applicable), appends `role: "tool"` results to `messages`, and loops back to step 2.

### 4. `Athanor.TUI` (`Termite` Terminal UI)

A non-blocking terminal UI built with `Termite`:

- **Main Viewport**: Displays conversation history, live-streaming assistant tokens, and compact tool-call status lines (`⚙ read_file("mix.exs") -> ok`).
- **Status Bar**: Shows active model, agent state (`idle`, `streaming`, `executing_tools`), and keybinding hints.
- **Input Bar**: Raw-mode line editor at the bottom of the screen; `Enter` submits a prompt to `Athanor.Agent`, `Esc` / `Ctrl+C` cancels an in-flight turn or exits.

## Path to Phase 2: Multi-Agent Orchestrator

Because `Athanor.Agent` is a standard `GenServer` that accepts prompts and emits `{:agent_event, event}` messages to a subscriber PID:

- In **Phase 1**, a single `Athanor.Agent` reports directly to `Athanor.TUI`.
- In **Phase 2**, a `DynamicSupervisor` manages multiple `Athanor.Agent` workers. A parent orchestrator (or the TUI) can spawn background agents, subscribe to their event streams, and switch the active viewport between running agents.
