defmodule Athanor.Skills do
  @moduledoc """
  Local Agent Skills discovery and loading (issue #23).

  A **skill** is a directory containing a `SKILL.md` whose YAML frontmatter carries a `name` and a
  `description`, plus optional assets (scripts, `agents/openai.yaml`, reference docs). It is the
  open convention shared by Claude Code, opencode and agent-deck — a *prompt/instruction bundle*
  the model can read, not code Athanor executes.

  ## Where skills live

  Discovery walks an ordered, configurable list of **roots** (`Config.skill_paths/0`, overridable
  with the colon-separated `ATHANOR_SKILL_PATHS`). The defaults are:

  | Order | Root | Meaning |
  |---|---|---|
  | 1 | `~/.agents/skills` | the global, per-user root |
  | 2 | `~/work/skills/.agents/skills` | a workspace skills repository |

  A root may also be given as the *repository* that contains a skills tree
  (`~/work/skills` → `~/work/skills/.agents/skills`); `normalise_root/1` resolves that, so a user
  can name either the repo or its `.agents/skills` directory and get the same answer.

  ## Symlinks, duplicates and precedence

  Entries in a root are frequently **symlinks** into another root (in the verified layout
  `~/.agents/skills/pr-diagram` → `~/work/skills/.agents/skills/pr-diagram`). Discovery therefore
  stats each entry through the link (`File.dir?/1`) and resolves the final path component, so a
  symlinked skill is discovered — and reported — as the directory it points at.

  Two collisions are possible and are resolved by the same rule — **the later root wins**:

    1. the same skill reachable from two roots (a symlink and its target);
    2. two *different* directories declaring the same frontmatter `name` (a stale backup copy, say).

  The winner keeps `source_root` = the root it was found under, so a listing can always say where a
  skill came from, and `:shadowed` records the resolved directory of every copy that lost. Because
  the default list is ordered global-first, "later wins" is exactly "**workspace overrides
  global**": a workspace can replace a machine-wide skill by name.

  ## Boundaries: not Memory (§7.5), not MCP (§7.6)

  The three are distinct capability layers and stay that way here:

    * **Skills** — *static local instruction bundles*, discovered from disk, injected as a
      catalogue and read on demand. Nothing is learned, written or ranked; there is no store, no
      tier and no scoring. This module is a pure reader.
    * **Memory** (`Athanor.Memory`, §7.5) — *learned facts* written by an agent (`remember`) and
      recalled by relevance, with budgets, redaction and tier precedence. Skills are never
      distilled into memory and memory is never a skill.
    * **MCP** (`Athanor.MCP`, §7.6, not implemented) — *external capability servers*: tools that
      Athanor calls over stdio/SSE. A skill's `allowed-tools`/`mcpServers` frontmatter is
      deliberately **not** interpreted; wiring MCP servers is §7.6's job, not a skill's.

  A skill cannot grant a tool and cannot forge a completion sentinel: its body is only ever text
  placed in the system prompt or returned as a tool result, exactly like `AGENTS.md`.

  ## Token budget

  `catalogue/1` injects **names + descriptions only**, never bodies — the same anti-pollution
  rule §7.5 applies to memory. A body enters the context only when the model asks for it with the
  `skill` tool (`load/2`), so a machine with 45 installed skills does not pay for 45 `SKILL.md`
  documents on every request.

  Descriptions are **not** truncated. They are the text the model uses to decide whether to load a
  skill, so cutting them would trade a bounded, one-off cost for a worse decision — the
  Claude-Code/opencode convention injects them whole too. The cost is bounded by how many skills
  are installed (the verified layout measures ~14 KB / ~4 K tokens for 45), and it is paid once per
  session, in the cached prefix of the first request. `ATHANOR_SKILLS=0` or a narrower
  `ATHANOR_SKILL_PATHS` is the escape hatch for an operator who disagrees.

  ## Injection scope

  The catalogue is injected for **conductors only** (`Athanor.Agent.compose_system_prompt/3`): a
  conductor is the session that decides which skill a workstream needs and can put it in a
  worker's prompt, so a worker does not need a second copy. The `skill` tool, by contrast, is
  offered to **both** roles — a worker told to "follow the tdd-elixir skill" must be able to read
  it. See `Athanor.Agent`'s moduledoc.
  """

  alias Athanor.Config
  alias Athanor.Skills.Frontmatter

  @filename "SKILL.md"

  # The marker names the block and tells the model how to act on it — the one imperative sentence
  # in the whole injection, and it is about the *tool*, not the skills.
  @sentinel """
  ## Skills (local instruction bundles)
  Skills available on this machine. Read one with the `skill` tool (`skill(name)`) when its
  description matches the task; only the chosen skill's text then enters the conversation.
  """

  @marker ".agents/skills"

  @typedoc """
  A discovered skill.

    * `:name` — the frontmatter `name`, falling back to the directory name.
    * `:description` — the frontmatter description, or `nil` when the file omits it.
    * `:dir` — the resolved directory holding `SKILL.md`.
    * `:path` — the resolved `SKILL.md` path.
    * `:source_root` — the root (from `roots/1`) this copy was found under, after precedence.
    * `:shadowed` — the resolved directories of every copy of this name that lost, oldest first.
      A losing copy may live in the same root (a stale `…bak-…` sibling), which is why this records
      the *directory* rather than the root: the root alone could not express that collision.
    * `:model_invocable?` — `false` when `SKILL.md` sets `disable-model-invocation: true`; such a
      skill is hidden from the injected catalogue but still loadable by name.
  """
  @type skill :: %{
          name: String.t(),
          description: String.t() | nil,
          dir: String.t(),
          path: String.t(),
          source_root: String.t(),
          shadowed: [String.t()],
          model_invocable?: boolean()
        }

  @doc """
  The ordered, configured skill roots, with `~` expanded.

  `ATHANOR_SKILL_PATHS` (colon-separated, `PATH`-style) wins over `:athanor, :skill_paths`, which
  wins over `Config.default_skill_paths/0`. Blank entries are dropped, so a trailing colon is
  harmless; an explicitly empty value falls back to the defaults rather than disabling discovery,
  which is `Config.skills_enabled?/0`'s job.
  """
  @spec roots(keyword()) :: [String.t()]
  def roots(opts \\ []) do
    opts
    |> Keyword.get(:paths, Config.skill_paths())
    |> Enum.map(&normalise_root/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Enumerates every skill under `opts[:paths]` (default `roots/1`), in name order.

  Reads the filesystem only — nothing is written, created or cached. Returns `[]` when skills are
  disabled (`Config.skills_enabled?/0`), when there are no roots, or when no root exists; a
  missing root is not an error, because the default second root is a personal repository that
  most machines will not have.

  Directories without a readable, frontmatter-bearing `SKILL.md` are skipped, as are duplicate
  names (see the moduledoc for the precedence rule).

  ## Options

    * `:paths` — the ordered roots to scan (default `Config.skill_paths/0`).
    * `:enabled` — overrides `Config.skills_enabled?/0` for one call (tests, per-session opt-out).
  """
  @spec discover(keyword()) :: [skill()]
  def discover(opts \\ []) do
    if Keyword.get(opts, :enabled, Config.skills_enabled?()) do
      opts
      |> roots()
      |> Enum.flat_map(&scan_root/1)
      |> resolve_precedence()
    else
      []
    end
  end

  @doc """
  Finds one skill by name, returning `nil` when no enabled root offers it.

  The lookup goes through `discover/1`, so it sees exactly the names the catalogue advertises —
  precedence, symlink resolution and shadowing included. Accepts the same options.
  """
  @spec find(String.t(), keyword()) :: skill() | nil
  def find(name, opts \\ []) when is_binary(name) do
    Enum.find(discover(opts), &(&1.name == name))
  end

  @doc """
  Reads a skill's `SKILL.md` and returns its body (frontmatter stripped), or an error string.

  The result shape is the `skill` tool's, because that is its only caller: an unknown name answers
  with what *is* available, and a `SKILL.md` that turns out not to be one is named as such — a short
  message the model can act on, not a bare reason atom.

  ## Options

    * `:paths`, `:enabled` — as `discover/1`.
    * `:max_bytes` — truncate the body at this many bytes with a visible marker (default
      `Config.skill_max_bytes/0`). A skill body is prose and can be long, but it is still bounded
      so a pathological file cannot blow the context window before compaction runs.
  """
  @spec load(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def load(name, opts \\ []) when is_binary(name) do
    case find(name, opts) do
      nil -> {:error, not_found_message(name, opts)}
      skill -> read(skill, opts)
    end
  end

  @doc """
  Reads an already-discovered `skill`'s `SKILL.md` and returns its body (frontmatter stripped).

  The seam the `skill` tool uses: it needs the struct's `dir` for provenance *and* the body, so
  discovering once and reading here avoids scanning the roots twice. Same options and same
  truncated-at-`max_bytes` behaviour as `load/2`.
  """
  @spec read(skill(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def read(skill, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, Config.skill_max_bytes())

    case File.read(skill.path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, _meta, body} -> {:ok, truncate(String.trim(body), max_bytes)}
          :error -> {:error, no_frontmatter_message(skill)}
        end

      {:error, reason} ->
        {:error, "Failed to read #{skill.path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Renders the injected catalogue: one `- name: description` line per model-invocable skill, or
  `nil` when there is nothing to inject.

  The block is **data, not instruction** (the same framing `Athanor.Memory.Injector` uses): it
  lists what exists and how to read it, and carries no imperative text. A `disable-model-invocation`
  skill is omitted — that frontmatter flag exists precisely to keep a skill out of the model's
  view — but it remains loadable by name, and the *absence* of any catalogue line is what tells
  the model not to look for it.

  `nil` (rather than `""`) when disabled, when no root has any skill, or when every discovered
  skill is non-invocable, so the caller appends no sentinel and no trailing blank lines.
  """
  @spec catalogue(keyword()) :: String.t() | nil
  def catalogue(opts \\ []) do
    case opts |> discover() |> Enum.filter(& &1.model_invocable?) do
      [] ->
        nil

      skills ->
        lines = Enum.map(skills, &catalogue_line/1)
        Enum.join([sentinel() | lines], "\n")
    end
  end

  @doc """
  The delimiter `Athanor.Agent` wraps around the injected catalogue, so the block is identifiable
  in the transcript and cannot be mistaken for the role prompt.
  """
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @doc """
  The directory-name fallback for a skill that omits `name:` in its frontmatter.
  """
  @spec name_from_dir(String.t()) :: String.t()
  def name_from_dir(dir), do: dir |> Path.basename() |> String.trim()

  # -- roots -------------------------------------------------------------------------------

  # A root named as a repository that holds a `.agents/skills` tree is redirected to that tree, so
  # `~/work/skills` and `~/work/skills/.agents/skills` are interchangeable. The test is
  # "does `<root>/.agents/skills` exist", not "is `<root>` a directory": a root that already *is*
  # a skills tree (`~/.agents/skills`) must stay itself, and it has no nested `.agents/skills`.
  defp normalise_root(path) when is_binary(path) do
    case String.trim(path) do
      "" ->
        nil

      trimmed ->
        expanded = Path.expand(trimmed)
        nested = Path.join(expanded, @marker)
        if File.dir?(nested), do: nested, else: expanded
    end
  end

  defp normalise_root(_other), do: nil

  defp scan_root(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&scan_entry(root, &1))

      {:error, _reason} ->
        []
    end
  end

  defp scan_entry(root, entry) do
    dir = Path.join(root, entry)

    # `File.dir?/1` is stat-backed and follows symlinks, so a linked skill is scanned as its
    # target; a broken link, a file, or an unreadable directory is simply not a skill.
    with true <- File.dir?(dir),
         path = Path.join(dir, @filename),
         {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      resolved = realpath(dir)

      [
        %{
          name: meta.name || name_from_dir(dir),
          description: meta.description,
          dir: resolved,
          path: Path.join(resolved, @filename),
          source_root: root,
          shadowed: [],
          model_invocable?: meta.model_invocable?
        }
      ]
    else
      _other -> []
    end
  end

  # Entries are visited root by root and, inside a root, in sorted directory order, so the last
  # entry for a name is the winner: later root overrides earlier (workspace over global), and a
  # same-root duplicate is resolved by directory order. The winner accumulates the losers'
  # directories in `:shadowed`, oldest first, and `Enum.sort_by/2` restores a readable name order.
  defp resolve_precedence(skills) do
    skills
    |> Enum.reduce(%{}, fn skill, acc -> Map.update(acc, skill.name, skill, &promote(&1, skill)) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp promote(winner, challenger) do
    %{challenger | shadowed: Enum.uniq([winner.dir | winner.shadowed]) |> Enum.reverse()}
  end

  # Resolves a symlink at the final path component (the case that matters: a root's entries are
  # links into another root). `Path.expand/1` alone would leave `…/.agents/skills/pr-diagram`
  # pointing at the link rather than the target, so two roots holding the same skill would look
  # like two different directories.
  defp realpath(path) do
    expanded = Path.expand(path)

    case File.read_link(expanded) do
      {:ok, target} -> realpath(Path.expand(target, Path.dirname(expanded)))
      {:error, _reason} -> expanded
    end
  end

  # -- loading -----------------------------------------------------------------------------

  defp truncate(body, max_bytes) when byte_size(body) <= max_bytes, do: body

  defp truncate(body, max_bytes) do
    marker = "\n\n[athanor: skill truncated at #{max_bytes} bytes]"
    safe_prefix(body, max(0, max_bytes - byte_size(marker))) <> marker
  end

  # Split on a UTF-8 boundary (the same care `Athanor.ProjectContext` takes): `binary_part/3` can
  # otherwise slice a multi-byte codepoint in half and put invalid bytes in the prompt.
  defp safe_prefix(body, max_bytes), do: drop_partial_codepoint(binary_part(body, 0, max_bytes))

  defp drop_partial_codepoint(head) do
    if String.valid?(head) or head == "" do
      head
    else
      drop_partial_codepoint(binary_part(head, 0, byte_size(head) - 1))
    end
  end

  # The failure is worth naming, because the fix is on disk: either the name is wrong or the file
  # is not a skill. Listing the available names is the shortest route to both.
  defp not_found_message(name, opts) do
    case opts |> discover() |> Enum.map(& &1.name) do
      [] -> "No skills are available (no configured root holds a SKILL.md)."
      names -> "No skill named #{inspect(name)}. Available: #{Enum.join(names, ", ")}."
    end
  end

  defp no_frontmatter_message(skill) do
    "#{skill.path} has no YAML frontmatter (`--- name: … description: … ---`), so it is not a skill."
  end

  # `- name: description`, one line each: the name is what the model passes to `skill(name)`, and
  # the description is what tells it whether to. Newlines inside a description (the `>` block
  # scalar) are folded so a skill stays on one line.
  defp catalogue_line(%{name: name, description: description}) when is_binary(description) do
    "- #{name}: #{fold(description)}"
  end

  defp catalogue_line(%{name: name}), do: "- #{name}: (no description)"

  defp fold(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
