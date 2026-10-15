# Athanor

**Athanor** (named after the self-feeding alchemical furnace used for long-running digestions) is an Elixir-based AI agent harness and multi-agent orchestrator built on the BEAM.

## Vision

1. **Phase 1: Core Agent Loop & TUI**
   - A responsive, pure-Elixir terminal UI built with `Termite`.
   - Streaming LLM completions and tool execution loop powered by OpenCode Go.
   - Clean, fault-tolerant process architecture.

2. **Phase 2: Background Multi-Agent Orchestrator**
   - OTP supervision trees managing concurrent, isolated agent processes.
   - PubSub/message-passing coordination between parent and child agents.
   - Live TUI inspection and steering of background agent workstreams.

## Getting Started

```bash
mix deps.get
mix test
mix athanor
```

To select a specific OpenCode Go model:

```bash
mix athanor --model gemini-4-argon-contributor
```

## Architecture

- **`Athanor.Agent`** — GenServer holding conversation state, streaming responses, and executing tool calls.
- **`Athanor.LLM`** — Client for OpenCode Go chat completions and tool-calling streaming.
- **`Athanor.Tools`** — Tool definitions and execution sandbox.
- **`Athanor.TUI`** — Terminal user interface powered by `Termite`.
