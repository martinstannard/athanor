# Athanor

**Athanor** (named after the self-feeding alchemical furnace used for long-running digestions) is an Elixir-based AI agent harness and multi-agent orchestrator built on the BEAM.

## Status

Phases 1 (core agent loop & TUI), 2 (Conductors, Sub-Agents and the PubSub bus) and 3 (persistent
daemon, remote attach and Markdown rendering) are **implemented**. See `docs/architecture.md` for the
realised module structure and `docs/design.md` §7 for what is still planned.

- A responsive, pure-Elixir terminal UI built with `Termite`.
- Streaming LLM completions and a tool execution loop powered by OpenCode Go.
- OTP supervision trees managing concurrent, isolated agent processes.
- PubSub/message-passing coordination between parent Conductors and child Sub-Agents.
- A persistent daemon node you can attach to and detach from local or SSH terminals.

## Getting Started

```bash
mix deps.get
mix test
mix athanor
```

`mix athanor` attaches to the background daemon (`athanor_daemon@127.0.0.1`), auto-starting it if it
is not already running. Manage it with `mix athanor.daemon --status` / `--stop` / `--restart`, or run
fully in-process with `mix athanor --local`.

### Distribution cookie

The daemon and its clients authenticate to each other with an Erlang distribution cookie. Athanor
**generates** one on first use and persists it at `<ATHANOR_HOME>/cookie` (`~/.athanor/cookie` by
default) with mode `0600` — there is deliberately no hardcoded default, because a default shipped in
a public source tree is a publicly-known shared secret.

Override it with `ATHANOR_COOKIE` (or `config :athanor, cookie: ...`); move the file with
`ATHANOR_HOME`. The value is shared state between a daemon and any client that connects to it, so
**changing it requires restarting the daemon** — a client and daemon with different cookies simply
cannot see each other, and the failure looks like "no daemon is running".

To select a specific OpenCode Go model:

```bash
mix athanor --model gemini-4-argon-contributor
```

## Agent Skills

Athanor discovers local **Agent Skills** — a directory with a `SKILL.md` carrying
`--- name: … description: … ---` frontmatter, plus optional assets — from an ordered list of roots:

| Order | Root |
|---|---|
| 1 | `~/.agents/skills` (global, per-user) |
| 2 | `~/work/skills/.agents/skills` (workspace) |

Override the list with a colon-separated `ATHANOR_SKILL_PATHS` (a root may also name the repository
that holds a `.agents/skills` tree), and turn the whole layer off with `ATHANOR_SKILLS=0`.

Skills are exposed in two halves so a large library never bloats a prompt:

- a **conductor's** system prompt carries a one-line catalogue of skill names and descriptions;
- the **`skill(name)` tool** returns one skill's full instructions on demand, so only the chosen
  skill's text enters the conversation.

Names collide in the wild (a symlink and its target, or a stale backup copy), so discovery resolves
symlinks, de-duplicates by name, and resolves collisions **later root wins** — workspace overrides
global — recording the losing copy. `disable-model-invocation: true` in a `SKILL.md` keeps that skill
out of the catalogue while leaving it loadable by name.

Skills are a distinct layer from memory (`remember`/`recall`) and MCP: they are local *instruction
bundles*, read from disk, never written, never learned. See `docs/architecture.md` §13.

## Themes

Athanor ships with 13 colour themes: `default` (the original palette, unchanged) plus 12 popular
ones — `dracula`, `nord`, `gruvbox_dark`, `gruvbox_light`, `tokyo_night`, `catppuccin_mocha`,
`one_dark`, `solarized_dark`, `solarized_light`, `monokai`, `everforest_dark`, `kanagawa`, and
`github_light`.

Pick one at launch, or switch live inside the TUI:

```bash
mix athanor --theme dracula
ATHANOR_THEME="gruvbox dark" mix athanor
```

```text
/theme            # list the available themes
/theme nord       # restyle the whole deck, status bar, output and Markdown
```

Themes are declared as `#RRGGBB` palettes and rendered in 24-bit colour by default; set
`config :athanor, theme_mode: :ansi256` (or `ATHANOR_THEME_MODE=ansi256`) to quantise to the
xterm-256 palette for older terminals. Names are matched forgivingly, so `"gruvbox"`,
`"Solarized Light"` and `"tokyo-night"` all resolve. Themes are a client-side concern, so an SSH
client can pick a different theme from a local one while both watch the same daemon.

## Architecture

- **`Athanor.Agent`** — GenServer holding conversation state, streaming responses, and executing tool calls (for both Conductors and Sub-Agents).
- **`Athanor.Orchestrator`** — Spawns, looks up, and steers supervised sessions.
- **`Athanor.Bus`** — PubSub backbone over `Athanor.PubSub` (`"agent:<id>:inbox"`, `"agent:<id>:events"`, `"conductor:<id>:children"`, `"deck:events"`).
- **`Athanor.LLM`** — Client for OpenCode Go chat completions and tool-calling streaming.
- **`Athanor.Tools`** — Tool definitions and execution sandbox.
- **`Athanor.TUI`** — Terminal user interface powered by `Termite`.
- **`Athanor.Theme`** — Semantic colour roles and the built-in theme palettes.
- **`Athanor.Markdown`** — Terminal Markdown renderer used by the TUI (theme-aware).
- **`Athanor.Worktree`** / **`Athanor.Worktree.Server`** — Git worktree isolation: `launch_subagent(…, worktree: true)` gives a sub-agent its own checkout and `cd`, and the Server serialises every mutation. See §7.1 of `docs/design.md` for the location, branch and clean-tree rules.
- **`Athanor.Skills`** / **`Athanor.Tools.Skill`** — Local Agent Skill discovery (ordered roots, symlink resolution, later-root-wins de-duplication) and the on-demand `skill(name)` tool; conductors also get a name+description catalogue in their system prompt.
- **`Athanor.Daemon`** — Persistent BEAM node plus attach/detach bridge for remote clients.

See `docs/architecture.md` for the full supervision tree and message flow.
