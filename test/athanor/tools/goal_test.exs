defmodule Athanor.Tools.GoalTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Athanor.{Agent, GoalManager, Orchestrator, Tools}
  alias Athanor.Tools.Goal, as: GoalTools

  describe "schemas/1 gating" do
    test "goal tools are advertised to a conductor and not to a worker" do
      conductor_names =
        Tools.schemas(role: :conductor)
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      for tool <- ["set_goal", "verify_goal", "goal_status", "list_goals"] do
        assert tool in conductor_names
      end

      worker_names =
        Tools.schemas(role: :worker)
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      for tool <- ["set_goal", "verify_goal", "goal_status", "list_goals"] do
        refute tool in worker_names
      end
    end
  end

  describe "parse_verifier/2" do
    test "a string is a shell command, peer mode makes it a question" do
      assert {:ok, {:shell, "mix test"}} = GoalTools.parse_verifier("mix test", nil)
      assert {:ok, {:shell, "mix test"}} = GoalTools.parse_verifier("mix test", "shell")
      assert {:ok, {:peer, "is it done?"}} = GoalTools.parse_verifier("is it done?", "peer")
    end

    test "map and list forms" do
      assert {:ok, {:shell, "mix test"}} = GoalTools.parse_verifier(%{"shell" => "mix test"})
      assert {:ok, {:peer, "done?"}} = GoalTools.parse_verifier(%{"peer" => "done?"})

      assert {:ok, [{:shell, "mix test"}, {:peer, "done?"}]} =
               GoalTools.parse_verifier(["mix test", %{"peer" => "done?"}], nil)
    end

    test "empty and missing specs are rejected" do
      assert {:error, _} = GoalTools.parse_verifier("", nil)
      assert {:error, _} = GoalTools.parse_verifier("  ", "peer")
      assert {:error, _} = GoalTools.parse_verifier(nil)
      assert {:error, _} = GoalTools.parse_verifier([])
    end
  end

  describe "conductor-only dispatch" do
    test "a worker is refused by name" do
      for {tool, args} <- [
            {"set_goal", %{"objective" => "x", "verify" => "true"}},
            {"verify_goal", %{"goal_id" => "g"}},
            {"goal_status", %{"goal_id" => "g"}},
            {"list_goals", %{}}
          ] do
        assert {:error, "Unknown tool: " <> ^tool} = Tools.execute(tool, args, role: :worker)
      end
    end

    test "missing arguments are reported, not raised" do
      assert {:error, _} = Tools.execute("set_goal", %{}, role: :conductor)
      assert {:error, _} = Tools.execute("verify_goal", %{}, role: :conductor)
      assert {:error, _} = Tools.execute("goal_status", %{}, role: :conductor)

      assert {:error, "Goal not found: goal-nobody"} =
               Tools.execute("verify_goal", %{"goal_id" => "goal-nobody"}, role: :conductor)

      assert {:error, "Goal not found: goal-nobody"} =
               Tools.execute("goal_status", %{"goal_id" => "goal-nobody"}, role: :conductor)
    end
  end

  describe "set_goal/2" do
    test "explicit form attaches a goal to an existing worker", %{tmp_dir: dir} do
      conductor = unique_id("gc-parent")
      worker = unique_id("gc-worker")
      spawn_conductor!(conductor, dir)

      {:ok, ^worker, worker_pid} =
        Orchestrator.launch_subagent(conductor, "w", "work", id: worker, cd: dir, llm_fn: idle_llm())

      on_exit(fn -> cleanup([conductor, worker]) end)

      assert {:ok, msg} =
               Tools.execute(
                 "set_goal",
                 %{"objective" => "make it so", "verify" => "true", "worker_id" => worker},
                 role: :conductor,
                 session_id: conductor,
                 cd: dir
               )

      assert msg =~ worker
      assert {:ok, goal_id} = GoalManager.for_worker(worker)
      assert msg =~ goal_id
      assert Agent.get_state(worker_pid).goal_id == goal_id

      GoalManager.cancel(goal_id)
    end

    test "explicit form reports an unknown worker", %{tmp_dir: dir} do
      conductor = unique_id("gu-parent")
      spawn_conductor!(conductor, dir)
      on_exit(fn -> cleanup([conductor]) end)

      assert {:error, reason} =
               GoalTools.set_goal(
                 %{"objective" => "x", "verify" => "true", "worker_id" => "worker-nobody"},
                 session_id: conductor,
                 cd: dir
               )

      assert reason =~ ":worker_not_found"
    end

    test "combined form spawns a worker and a goal atomically", %{tmp_dir: dir} do
      conductor = unique_id("gs-parent")
      spawn_conductor!(conductor, dir)
      on_exit(fn -> cleanup([conductor] ++ spawned_workers()) end)

      assert {:ok, msg} =
               Tools.execute(
                 "set_goal",
                 %{"objective" => "make it so", "verify" => "true"},
                 role: :conductor,
                 session_id: conductor,
                 cd: dir
               )

      assert [_, worker_id, goal_id] = Regex.run(~r/Spawned worker (\S+) with goal (\S+)/, msg)
      assert {:ok, _pid} = Orchestrator.lookup(worker_id)
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)

      GoalManager.cancel(goal_id)
    end
  end

  describe "verify_goal/goal_status/list_goals" do
    test "verify, status, and list round-trip through Tools.execute", %{tmp_dir: dir} do
      conductor = unique_id("gv-parent")
      worker = unique_id("gv-worker")
      spawn_conductor!(conductor, dir)

      {:ok, ^worker, _pid} =
        Orchestrator.launch_subagent(conductor, "w", "work", id: worker, cd: dir, llm_fn: idle_llm())

      on_exit(fn -> cleanup([conductor, worker]) end)

      {:ok, goal_id, manager_pid} =
        GoalManager.start_goal(
          objective: "the objective",
          worker_id: worker,
          parent_id: conductor,
          cd: dir,
          verifier: {:shell, "true"},
          verify_interval_ms: 10_000
        )

      on_exit(fn ->
        GoalManager.cancel(goal_id)
        if Process.alive?(manager_pid), do: DynamicSupervisor.terminate_child(Athanor.GoalSupervisor, manager_pid)
      end)

      assert {:ok, msg} = Tools.execute("verify_goal", %{"goal_id" => goal_id}, role: :conductor)
      assert msg =~ goal_id

      assert {:ok, status} = Tools.execute("goal_status", %{"goal_id" => goal_id}, role: :conductor)
      assert status =~ goal_id
      assert status =~ "the objective"

      assert {:ok, list} = Tools.execute("list_goals", %{}, role: :conductor)
      assert list =~ goal_id
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp idle_llm do
    fn _messages, _tools, _pid ->
      {:ok, %{role: "assistant", content: "working", tool_calls: []}}
    end
  end

  defp spawn_conductor!(id, cd) do
    {:ok, ^id, _pid} =
      Orchestrator.spawn_session(id: id, role: :conductor, title: id, cd: cd, llm_fn: idle_llm())

    id
  end

  defp spawned_workers do
    for s <- Orchestrator.list_sessions(), s.role == :worker, do: s.id
  end

  defp cleanup(ids) do
    for id <- ids do
      case Orchestrator.lookup(id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)
        :error -> :ok
      end
    end
  end
end
