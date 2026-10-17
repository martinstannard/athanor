defmodule Athanor.ProjectContext do
  @moduledoc """
  Reads the nearest `AGENTS.md` above a session's working directory and hands it to
  `Athanor.Agent` for injection into the system prompt.

  `AGENTS.md` is the cross-harness convention for a repository's instructions (opencode and
  Claude Code read it natively), and it is what humans already write down. Without this module
  Athanor's own Conductors and Sub-Agents cannot see those conventions, so a workaround
  documented in `AGENTS.md` (the chainlink session collision, #32) stays invisible to the
  agents it is meant to constrain.

  ## Walk-up and the `.git` boundary

  `load/2` walks **up** from `cwd`, returning the first `AGENTS.md` it finds, and stops at the
  nearest directory containing a `.git` entry — a directory in a normal clone, a *file* in a
  linked worktree. Stopping there matters for two reasons: it keeps a stray `AGENTS.md` above a
  checkout (for example in a user's home directory) from leaking into a session, and it makes
  the answer "the repo's instructions" rather than "whatever happens to be above the worktree".

  Only the **nearest** file is used. opencode and Claude Code also merge every `AGENTS.md` from
  the repo root down to `cwd`; that nested-merge behaviour is deliberately out of scope here
  and can be added later without reshaping this module — `load/2` would return a list of
  `{dir, body}` pairs and the caller would join them root-first. See issue #33.

  ## Safety

  The file is written into the **system** message only. It cannot introduce tool definitions and
  it cannot forge `===ATHANOR_DONE===`/`===AGENTDECK_DONE===`, because those are parsed from
  *assistant* messages (`Athanor.Agent.parse_done_sentinel/1`) and never from the system prompt.

  An empty or whitespace-only file is treated as absent (`:none`), so the caller adds no sentinel
  and no trailing separators; an oversized file is truncated at `max_bytes` with a visible
  marker rather than silently dropped or silently cut (see `Config.project_context_max_bytes/0`).
  """

  alias Athanor.Config

  @sentinel "<!-- athanor:project-instructions -->"

  @doc """
  The delimiter `Athanor.Agent` wraps around injected project instructions, so the injected text
  is identifiable in the transcript and cannot be mistaken for the role prompt.
  """
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @doc """
  Walks up from `cwd` and returns the nearest `AGENTS.md` as `{:ok, content}`, or `:none` when
  no non-empty file exists before the `.git` boundary (see the moduledoc).

  ## Options

    * `:max_bytes` — truncate the body at this many bytes, appending a visible marker. Defaults
      to `Config.project_context_max_bytes/0`.
  """
  @spec load(String.t(), keyword()) :: {:ok, String.t()} | :none
  def load(cwd, opts \\ []) when is_binary(cwd) do
    max_bytes = Keyword.get(opts, :max_bytes, Config.project_context_max_bytes())

    cwd
    |> Path.expand()
    |> walk_up(max_bytes)
  end

  # Nearest wins: test AGENTS.md *before* the `.git` boundary so a nested file is preferred over
  # the repo-root one, and stop at the boundary even when the directory has no AGENTS.md.
  #
  # The root is also a boundary. Without it, a `cwd` with no `.git` anywhere above it walks
  # `"/"` → `Path.dirname("/") == "/"` → `"/"` … forever: `load/1` never returns, so an agent
  # whose `cd` is not inside a repository hangs at init while hammering the file server.
  defp walk_up(dir, max_bytes) do
    cond do
      body = read_agents_md(dir) -> {:ok, truncate(body, max_bytes)}
      git_boundary?(dir) -> :none
      Path.dirname(dir) == dir -> :none
      true -> walk_up(Path.dirname(dir), max_bytes)
    end
  end

  # `nil` (not `""`) for absent or blank, so the `cond` above treats it as "keep walking" and an
  # empty file stays a silent no-op for the caller.
  defp read_agents_md(dir) do
    case File.read(Path.join(dir, "AGENTS.md")) do
      {:ok, body} -> if String.trim(body) == "", do: nil, else: body
      {:error, _reason} -> nil
    end
  end

  # `File.exists?/1`, not `File.dir?/1`: a linked worktree's `.git` is a file, not a directory.
  defp git_boundary?(dir), do: File.exists?(Path.join(dir, ".git"))

  defp truncate(body, max_bytes) when byte_size(body) <= max_bytes, do: body

  defp truncate(body, max_bytes) do
    safe_prefix(body, max_bytes) <> "\n\n[athanor: AGENTS.md truncated at #{max_bytes} bytes]\n"
  end

  # Split on a UTF-8 boundary: a naive `binary_part/3` can slice a multi-byte codepoint in half
  # and put invalid bytes in the prompt. Dropping up to three trailing bytes is enough to reach a
  # boundary for any codepoint (UTF-8 is at most four bytes); `""` is valid, so this terminates.
  defp safe_prefix(body, max_bytes), do: drop_partial_codepoint(binary_part(body, 0, max_bytes))

  defp drop_partial_codepoint(head) do
    if String.valid?(head) do
      head
    else
      drop_partial_codepoint(binary_part(head, 0, byte_size(head) - 1))
    end
  end
end
