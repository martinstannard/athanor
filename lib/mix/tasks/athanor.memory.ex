defmodule Mix.Tasks.Athanor.Memory do
  @shortdoc "Memory housekeeping: compact the append-only learnings log"

  @moduledoc """
  Housekeeping for §7.5 memory.

      mix athanor.memory compact

  `learnings.jsonl` is append-only, so `forget` writes a tombstone rather than removing a line
  and the file only grows (plan §8.3). `compact` rewrites it without forgotten or deprecated
  entries. It runs on the project tier for the current directory, when there is one, and on the
  global tier; both are reported.

  This is deliberately the *only* housekeeping verb: nothing else about memory is destructive,
  and compaction never happens behind a running session's back (OQ7).
  """

  use Mix.Task

  alias Athanor.Config
  alias Athanor.Memory
  alias Athanor.Memory.Store

  @impl Mix.Task
  def run(args) do
    case args do
      ["compact"] -> compact()
      _other -> Mix.raise("usage: mix athanor.memory compact")
    end
  end

  defp compact do
    [
      {"project", Memory.resolve(cd: File.cwd!()).project_dir},
      {"global", Config.memory_global_dir()}
    ]
    |> Enum.reject(fn {_label, dir} -> is_nil(dir) end)
    |> Enum.each(fn {label, dir} ->
      {:ok, removed} = Store.compact(dir)
      Mix.shell().info("#{label}: #{dir} — dropped #{removed} line(s)")
    end)
  end
end
