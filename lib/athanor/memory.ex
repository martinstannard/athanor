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

  Phase 1 is pure functions over local files — no supervised process. This module is the facade:
  it resolves which tiers a session's `cd` reaches, builds the prompt section, and backs the
  `remember`/`recall`/`forget` tools.

  `remember`/`recall`/`forget` return `{:ok, text} | {:error, text}` — the tool-shaped result, so
  `Athanor.Tools` can return them directly.

  **Session scope is not persisted in phase 1.** The tool schema offers `project` and `global`
  only; an in-memory session tier is a later milestone (plan OQ11). Secrets are scrubbed on write
  and again on injection (`Athanor.Memory.Redact`).
  """

  alias Athanor.Config
  alias Athanor.Memory.Entry
  alias Athanor.Memory.Injector
  alias Athanor.Memory.Redact
  alias Athanor.Memory.Retrieval
  alias Athanor.Memory.Store
  alias Athanor.Memory.Transcripts

  @typedoc "The tiers a session's working directory reaches."
  @type resolved :: %{
          workspace_root: String.t() | nil,
          project_dir: String.t() | nil,
          global_dir: String.t() | nil
        }

  # `remember` projects these categories into the curated `MEMORY.md` (plan §9.2); the rest stay
  # in the append-only log, retrieved via `recall` only.
  @curated_sections %{
    architecture: "Architecture",
    convention: "Conventions",
    gotcha: "Gotchas",
    preference: "Preferences"
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

  `nil` when memory is disabled or when neither tier has a `MEMORY.md`. The `:enabled` option
  overrides `Config.memory_enabled?/0` for a single session (how `Athanor.Agent` honours its
  `:memory` init opt).
  """
  @spec system_prompt_section(keyword()) :: String.t() | nil
  def system_prompt_section(opts \\ []) do
    if Keyword.get(opts, :enabled, Config.memory_enabled?()) do
      opts |> resolve() |> Injector.build(opts)
    end
  end

  @doc """
  Records a durable learning ("`remember`").

  `args` is the tool argument map: `category` and `fact` are required; `scope` (`project`, the
  default, or `global`) and `tags` are optional.

  Deduplicates on `(scope, category, hash)` — a case/whitespace variant of a known fact returns
  `"Already known"` and writes nothing (plan §8.1). Curated categories also get a bullet in the
  tier's `MEMORY.md`.
  """
  @spec remember(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def remember(args, opts \\ []) do
    with {:ok, category} <- validate_category(args["category"]),
         {:ok, scope} <- validate_scope(args["scope"] || "project"),
         {:ok, dir} <- tier_dir(scope, opts) do
      fact = args |> Map.fetch!("fact") |> sanitize()
      entry = build_entry(scope, category, fact, args["tags"], opts)

      case find_live(dir, entry) do
        %Entry{} = existing ->
          {:ok, "Already known (#{existing.id}); nothing new recorded."}

        nil ->
          :ok = Store.append_learning(dir, entry)
          project_bullet(dir, category, fact)
          {:ok, "Remembered (#{entry.id}) in #{scope} scope."}
      end
    end
  end

  @doc """
  Records a batch of learnings ("distillation", design §7.5 #4).

  The conductor drives this after a `[DONE]`: it has the synthesis view, so it decides what is
  policy rather than noise. Each candidate goes through the same dedup, redaction and projection
  path as `remember/2` — distillation is not a second write path with its own rules, and it never
  runs unattended (plan D9).

  `entries` is a list of `%{"category" => …, "fact" => …}` maps (optionally `"scope"`/`"tags"`).
  Returns a one-line summary.
  """
  @spec distill([map()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def distill(entries, opts \\ []) when is_list(entries) do
    results = Enum.map(entries, &remember(&1, opts))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] ->
        {remembered, known} = Enum.split_with(results, fn {:ok, text} -> text =~ "Remembered" end)
        {:ok, "Distilled #{length(remembered)} learning(s); #{length(known)} already known."}

      [{:error, reason} | _rest] ->
        {:error, reason}
    end
  end

  @doc """
  Searches durable learnings ("`recall`").

  `args`: `query` is required; `scope` is `project` (default), `global`, or `all`; `limit`
  defaults to `Config.memory_recall_limit/0`. Returns a JSON array of matches with ids so the
  model can cite provenance and call `forget`.
  """
  @spec recall(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def recall(args, opts \\ []) do
    query = args["query"] || ""
    limit = args["limit"] || Config.memory_recall_limit()

    with {:ok, scopes} <- validate_recall_scope(args["scope"] || "project"),
         :ok <- transcript_recall_available(scopes) do
      results =
        scopes
        |> Enum.flat_map(&corpus(&1, opts))
        |> Retrieval.search(query, limit: limit)

      {:ok, format_results(results)}
    end
  end

  # A disabled corpus must say so: silently returning "no matches" would look like "you have
  # never discussed this", which is a different (and misleading) statement.
  defp transcript_recall_available(scopes) do
    if :transcripts in scopes and not Config.memory_transcript_recall?() do
      {:error, "Transcript recall is disabled (ATHANOR_MEMORY_TRANSCRIPTS=0)."}
    else
      :ok
    end
  end

  @doc """
  Removes a learning by id ("`forget`") — the escape hatch for a wrong, obsolete, or sensitive
  entry.

  A `learnings.jsonl` entry becomes a tombstone; a `MEMORY.md` bullet is removed from the file.
  **Global entries may only be forgotten by the user** (`allow_global: true`, never set by a
  tool): a machine-wide fact is not an agent's to delete (plan OQ5).
  """
  @spec forget(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def forget(args, opts \\ []) do
    id = args["id"]

    case find_by_id(id, opts) do
      {:ok, scope, dir, %Entry{} = entry} ->
        if scope == :global and opts[:allow_global] != true do
          {:error, "Global learnings can only be forgotten by the user (id #{id})."}
        else
          :ok = Store.append_tombstone(dir, id)
          remove_projected_bullet(dir, entry)
          {:ok, "Forgot #{id}."}
        end

      :not_found ->
        forget_bullet(id, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The stable id a `MEMORY.md` bullet would carry if it were a `learnings.jsonl` entry.

  Bullets are not entries, but `recall` and `forget` must be able to name them, so a bullet's id
  is derived from its text — deterministic, and stable across reads.
  """
  @spec bullet_id(String.t()) :: String.t()
  def bullet_id(text), do: "mem_" <> binary_part(Entry.hash(text), 0, 12)

  # -- remember helpers ------------------------------------------------------

  defp build_entry(scope, category, fact, tags, opts) do
    Entry.new(%{
      scope: scope,
      category: category,
      text: fact,
      tags: tags || [],
      source: %{"session_id" => opts[:session_id] || "unknown", "kind" => "tool"}
    })
  end

  defp find_live(dir, %Entry{} = entry) do
    Enum.find(Store.read_learnings(dir), fn existing ->
      existing.scope == entry.scope and existing.category == entry.category and
        existing.hash == entry.hash
    end)
  end

  defp project_bullet(dir, category, fact) do
    case Map.get(@curated_sections, category) do
      nil -> :ok
      section -> Store.upsert_bullet(dir, section, fact)
    end
  end

  defp remove_projected_bullet(dir, entry) do
    if Map.has_key?(@curated_sections, entry.category), do: Store.remove_bullet(dir, entry.text)
    :ok
  end

  # -- recall helpers --------------------------------------------------------

  defp corpus(:project, opts), do: learnings_for(tier_dir(:project, opts))
  defp corpus(:global, opts), do: learnings_for(tier_dir(:global, opts))
  # Not part of `:all` on purpose: transcripts are the largest corpus and the rawest text, so they
  # are opt-in by name (§7.3, OQ3).
  defp corpus(:transcripts, opts), do: Transcripts.corpus(opts)

  # A missing project tier is not an error for recall: it just contributes nothing.
  defp learnings_for({:ok, dir}), do: Store.read_learnings(dir)
  defp learnings_for({:error, _reason}), do: []

  defp format_results([]), do: "No matching learnings."

  defp format_results(results) do
    JSON.encode!(
      Enum.map(results, fn entry ->
        %{
          "id" => entry.id,
          "scope" => Atom.to_string(entry.scope),
          "category" => Atom.to_string(entry.category),
          "text" => entry.text,
          "updated_at" => entry.updated_at,
          "source" => entry.source
        }
      end)
    )
  end

  # -- forget helpers --------------------------------------------------------

  defp find_by_id(id, opts) when is_binary(id) do
    [:project, :global]
    |> Enum.map(fn scope -> {scope, tier_dir(scope, opts)} end)
    |> Enum.find_value(:not_found, fn {scope, result} ->
      with {:ok, dir} <- result,
           %Entry{} = entry <- Enum.find(Store.read_learnings(dir), &(&1.id == id)) do
        {:ok, scope, dir, entry}
      else
        _other -> nil
      end
    end)
  end

  defp find_by_id(_id, _opts), do: {:error, "A forget needs an id."}

  defp forget_bullet(id, opts) when is_binary(id) do
    case find_bullet(id, opts) do
      {:ok, dir, text} ->
        :ok = Store.remove_bullet(dir, text)
        {:ok, "Forgot #{id}."}

      :not_found ->
        {:error, "No learning with id #{id}."}
    end
  end

  defp forget_bullet(_id, _opts), do: {:error, "A forget needs an id."}

  defp find_bullet(id, opts) do
    opts |> tier_dirs() |> Enum.find_value(:not_found, &bullet_in(&1, id))
  end

  defp bullet_in(dir, id) do
    case Enum.find(Store.read_bullets(dir), fn {_section, text} -> bullet_id(text) == id end) do
      nil -> nil
      {_section, text} -> {:ok, dir, text}
    end
  end

  # The tier directories that exist, ignoring a project tier outside a workspace.
  defp tier_dirs(opts) do
    [:project, :global]
    |> Enum.map(&tier_dir(&1, opts))
    |> Enum.flat_map(fn
      {:ok, dir} -> [dir]
      {:error, _reason} -> []
    end)
  end

  # -- shared helpers --------------------------------------------------------

  defp tier_dir(:project, opts) do
    case Store.workspace_root(Keyword.get(opts, :cd, File.cwd!())) do
      nil -> {:error, "Not inside a workspace (no .git or .athanor above this directory)."}
      root -> {:ok, Path.join(root, ".athanor")}
    end
  end

  defp tier_dir(:global, opts), do: {:ok, Keyword.get(opts, :global_dir, Config.memory_global_dir())}

  defp sanitize(fact) do
    limit = Config.memory_fact_max_chars()

    fact
    |> Redact.scrub()
    |> to_string()
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp validate_category(category) do
    case coerce(category, Entry.categories()) do
      nil -> {:error, "Unsupported category #{inspect(category)}."}
      value -> {:ok, value}
    end
  end

  defp validate_scope(scope) do
    case coerce(scope, [:project, :global]) do
      nil -> {:error, "Unsupported scope #{inspect(scope)} (phase 1: project or global)."}
      value -> {:ok, value}
    end
  end

  defp validate_recall_scope(scope) do
    case coerce(scope, [:project, :global, :all, :transcripts]) do
      nil -> {:error, "Unsupported recall scope #{inspect(scope)}."}
      :all -> {:ok, [:project, :global]}
      value -> {:ok, [value]}
    end
  end

  defp coerce(nil, _allowed), do: nil
  defp coerce(value, allowed) when is_atom(value), do: if(value in allowed, do: value)
  defp coerce(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == to_string(value)))
end
