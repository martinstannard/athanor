defmodule Athanor.ProjectContextEnvTest do
  # `async: false` on purpose: this module mutates process-global environment, and ExUnit runs
  # every async module before any sync module, so the mutation cannot leak into a concurrent test.
  use ExUnit.Case, async: false

  alias Athanor.Agent

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    File.write!(Path.join(tmp_dir, "AGENTS.md"), "SECRET CONVENTION")

    previous = System.get_env("ATHANOR_PROJECT_CONTEXT")
    on_exit(fn -> restore_env("ATHANOR_PROJECT_CONTEXT", previous) end)
    :ok
  end

  test "ATHANOR_PROJECT_CONTEXT=0 suppresses injection", %{tmp_dir: tmp_dir} do
    System.put_env("ATHANOR_PROJECT_CONTEXT", "0")

    {:ok, agent} = Agent.start_link(cd: tmp_dir)
    [%{content: content}] = Agent.get_state(agent).messages

    refute content =~ "SECRET CONVENTION"
    refute content =~ Athanor.ProjectContext.sentinel()
  end

  test "an explicit project_context: true wins over the env var", %{tmp_dir: tmp_dir} do
    System.put_env("ATHANOR_PROJECT_CONTEXT", "0")

    {:ok, agent} = Agent.start_link(cd: tmp_dir, project_context: true)
    [%{content: content}] = Agent.get_state(agent).messages

    assert content =~ "SECRET CONVENTION"
    assert content =~ Athanor.ProjectContext.sentinel()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
