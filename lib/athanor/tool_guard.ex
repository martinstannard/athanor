defmodule Athanor.ToolGuard do
  @moduledoc """
  Per-session "read before write" enforcement (design §7.6, plan §4).

  `write_file` overwrites unconditionally and `edit_file` only checks that `old_string` is
  present, so a model that guesses a path can replace a file it never opened with a
  hallucination. The guard makes "this file was seen in this session" a precondition for
  modifying it:

  > A session may only `edit_file`/`write_file` a path that already exists on disk if it has
  > successfully `read_file`-ed that same resolved path earlier in the session.

  Creating a new file is always allowed; so is any write after a successful read, and a write
  itself marks the path as known (post-write content is the model's own).

  The read-set lives in a **public ETS table**, not in the `Athanor.Agent` struct, because tool
  calls run in a `spawn_monitor`ed helper process (`Athanor.Agent.start_tool_execution/2`) that
  cannot mutate agent state. Keys are `{session_id, resolved_absolute_path}` — path
  canonicalization is mandatory (`Tools.resolve_path/2`), so `./lib/x.ex`, `lib/x.ex` and
  `lib/../lib/x.ex` are one entry. Symlinks are deliberately **not** resolved: the model reasons
  in path strings, and following links would make the read-set disagree with the text it saw.

  This is a **no-op** when the table is absent, when there is no `session_id`, or when
  `Config.tool_guard_enabled?/0` is false, so it can never be the reason a bare
  `Tools.execute/3` call fails — the same posture as `Athanor.Bus.subscribe/1`.
  """

  use GenServer

  alias Athanor.Config

  @table :athanor_tool_guard

  @doc "Starts the guard's ETS owner. Started by `Athanor.Application`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records that `session_id` has read `path` (an already-resolved absolute path)."
  @spec mark_read(String.t() | nil, String.t()) :: :ok
  def mark_read(session_id, path) do
    if table?() and is_binary(session_id) do
      :ets.insert(@table, {{session_id, path}, true})
    end

    :ok
  end

  @doc "Whether `session_id` has read `path`."
  @spec read?(String.t() | nil, String.t()) :: boolean()
  def read?(session_id, path) do
    table?() and is_binary(session_id) and :ets.member(@table, {session_id, path})
  end

  @doc "The set of paths `session_id` has read (diagnostics and tests)."
  @spec snapshot(String.t() | nil) :: MapSet.t(String.t())
  def snapshot(session_id) do
    if table?() and is_binary(session_id) do
      @table
      |> :ets.match({{session_id, :"$1"}, :_})
      |> List.flatten()
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  @doc "Forgets everything `session_id` has read. Called when a session starts."
  @spec reset(String.t() | nil) :: :ok
  def reset(session_id) do
    if table?() and is_binary(session_id) do
      :ets.match_delete(@table, {{session_id, :_}, :_})
    end

    :ok
  end

  @doc """
  Whether a modify of the resolved `path` must be refused for `session_id`.

  True only when the guard is enabled, a session is known, the path **already exists**, and it has
  not been read this session. A non-existent path is a creation, which is never refused.
  """
  @spec refuse?(String.t() | nil, String.t()) :: boolean()
  def refuse?(session_id, path) do
    Config.tool_guard_enabled?() and Config.prelude_read_required?() and is_binary(session_id) and
      table?() and File.exists?(path) and not read?(session_id, path)
  end

  @doc "The refusal message shown to the model (deliberately actionable)."
  @spec refusal_message(String.t()) :: String.t()
  def refusal_message(path) do
    "Refusing to overwrite #{path}: it exists and has not been read in this session. " <>
      "Call read_file first."
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
