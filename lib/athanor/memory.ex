defmodule Athanor.Memory do
  @moduledoc """
  Hierarchical memory for conductors and sub-agents (design §7.5, plan
  `docs/plans/7.5-hierarchical-memory.md`).

  Three tiers, more specific wins:

  | Tier | Location | Auto-injected |
  |---|---|---|
  | `:global` | `~/.athanor/memory/` | header/pointer only (plan D8) |
  | `:project` | `<workspace>/.athanor/` | `MEMORY.md` yes; `learnings.jsonl` via `recall` |
  | `:session` | in-memory, this session only | that session only |

  Phase 1 is pure functions over local files — no supervised process. This module is the
  facade: it resolves which tiers a session's `cd` reaches and builds the prompt section. The
  write/read tools (`remember`/`recall`/`forget`) and distillation arrive in later milestones.
  """

  alias Athanor.Config
  alias Athanor.Memory.Injector
  alias Athanor.Memory.Store

  @typedoc "The tiers a session's working directory reaches."
  @type resolved :: %{
          workspace_root: String.t() | nil,
          project_dir: String.t() | nil,
          global_dir: String.t() | nil
        }

  @doc """
  Resolves the memory tiers for a session.

  Options:

    * `:cd` — the session's working directory (defaults to the current directory). A §7.1
      worktree resolves to the repository it was branched from, so memory is shared, not forked.
    * `:global_dir` — overrides the global tier root (tests and §7.7 daemon deployments).

  Never touches the filesystem beyond reading directory entries, and never creates `.athanor/`
  — discovery is read-only by design (plan risk 9).
  """
  @spec resolve(keyword()) :: resolved()
  def resolve(opts \\ []) do
    cd = opts |> Keyword.get(:cd, File.cwd!()) |> Path.expand()

    %{
      workspace_root: Store.workspace_root(cd),
      project_dir: Store.project_dir(cd),
      global_dir: Keyword.get(opts, :global_dir, Config.memory_global_dir())
    }
  end

  @doc """
  The memory block to append to a session's system prompt, or `nil` when there is nothing to add.

  `nil` when memory is disabled (`ATHANOR_MEMORY=0`) or when neither tier has a `MEMORY.md`.
  """
  @spec system_prompt_section(keyword()) :: String.t() | nil
  def system_prompt_section(opts \\ []) do
    if Config.memory_enabled?() do
      opts |> resolve() |> Injector.build(opts)
    end
  end
end
