# AGENTS.md

## Project Overview

**Athanor** is an AI agent harness and background multi-agent orchestrator written in Elixir.
- **TUI Layer**: Built with [`termite`](https://hex.pm/packages/termite) (pure Elixir terminal control).
- **LLM Provider**: OpenCode Go API (`opencode-go`).
- **Runtime**: Elixir `~> 1.19` / OTP with supervision trees (`Athanor.Application`).

## Development Commands

- **Install dependencies**: `mix deps.get`
- **Compile**: `mix compile --warnings-as-errors`
- **Run tests**: `mix test`
- **Format code**: `mix format`
- **Check formatting**: `mix format --check-formatted`

## Architecture & Conventions

- **OTP / Process Design**:
  - Keep the TUI rendering/input loop decoupled from the LLM/agent execution loop.
  - Each agent session should run in its own supervised process (`GenServer`), communicating events (deltas, tool calls, status transitions) via message passing or `Registry`/`PubSub`.
  - Never block the TUI process on HTTP requests or tool execution.
- **Dependencies**:
  - Prefer lightweight, pure-Elixir libraries (`req` for HTTP/SSE streaming, `jason` for JSON if needed—note Elixir 1.18+ has built-in `JSON`, `termite` for TUI).
- **Code Style**:
  - Use Elixir 1.18+ built-in `JSON` module instead of adding external JSON libraries unless required by a dependency.
  - Use pattern matching and tagged tuples (`{:ok, result}` / `{:error, reason}`).
  - Add `@moduledoc` and `@doc` to public modules and functions, plus typespecs (`@spec`) on core boundaries.

## Quality & regular checks

The "three gates" (`mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix test`) are wrapped by aliases defined in `mix.exs`:

- **`mix check`** — the full gate, in order:
  `format --check-formatted` → `compile --warnings-as-errors` → `credo --strict` → `test`.
- **`mix check.fast`** — the same minus `test`, for quick iteration while coding.

`credo --strict` is part of the gate: it fails on any issue (exit status 30). Config lives in
`.credo.exs`; checks disabled there each carry a written justification.

**Pre-commit hook** (created at `.githooks/pre-commit`, **not enabled by default**): it runs
`mix check` and aborts the commit on failure. Enable it for your clone with:

```sh
git config core.hooksPath .githooks
```

Bypass a single commit with `git commit --no-verify`.
