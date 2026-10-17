defmodule Athanor.MemoryConfigTest do
  @moduledoc """
  `Athanor.Config` memory accessors (plan §10, §14).

  `async: false` because these mutate process-wide environment variables — the same constraint
  `ThemeTest` has.
  """
  use ExUnit.Case, async: false

  alias Athanor.Config

  @moduletag :tmp_dir

  setup do
    vars = [
      "ATHANOR_MEMORY",
      "ATHANOR_MEMORY_PROJECT_BUDGET",
      "ATHANOR_MEMORY_GLOBAL_BUDGET",
      "ATHANOR_MEMORY_GLOBAL_INJECT",
      "ATHANOR_MEMORY_RECALL_LIMIT",
      "ATHANOR_MEMORY_FACT_MAX_CHARS",
      "ATHANOR_HOME",
      "ATHANOR_MEMORY_GRAPH"
    ]

    saved = Map.new(vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(vars, &System.delete_env/1)
    on_exit(fn -> Enum.each(saved, fn {var, value} -> restore(var, value) end) end)
    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  test "defaults" do
    assert Config.memory_enabled?()
    assert Config.memory_project_budget() == 2_000
    assert Config.memory_global_budget() == 1_000
    refute Config.memory_global_inject?()
    assert Config.memory_recall_limit() == 5
    assert Config.memory_fact_max_chars() == 2_000
    assert Config.memory_graph_path() == nil
  end

  test "ATHANOR_MEMORY=0 disables injection" do
    System.put_env("ATHANOR_MEMORY", "0")
    refute Config.memory_enabled?()
  end

  test "budget and limit env overrides" do
    System.put_env("ATHANOR_MEMORY_PROJECT_BUDGET", "500")
    System.put_env("ATHANOR_MEMORY_RECALL_LIMIT", "9")
    System.put_env("ATHANOR_MEMORY_GLOBAL_INJECT", "true")

    assert Config.memory_project_budget() == 500
    assert Config.memory_recall_limit() == 9
    assert Config.memory_global_inject?()
  end

  test "an unparseable budget falls back to the default" do
    System.put_env("ATHANOR_MEMORY_PROJECT_BUDGET", "not-a-number")
    assert Config.memory_project_budget() == 2_000
  end

  test "the global tier hangs off ATHANOR_HOME", %{tmp_dir: dir} do
    System.put_env("ATHANOR_HOME", dir)
    assert Config.memory_global_dir() == Path.join(dir, "memory")
  end

  test "an empty graph path counts as unset" do
    System.put_env("ATHANOR_MEMORY_GRAPH", "   ")
    assert Config.memory_graph_path() == nil
  end
end
