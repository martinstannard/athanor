defmodule Athanor.GoalTest do
  use ExUnit.Case, async: true

  alias Athanor.{Bus, Goal, Orchestrator, Tools, Verifier}
  alias Athanor.Goal.Receipt
  alias Athanor.Verifier.Result

  @moduletag :tmp_dir

  describe "Goal.new/1" do
    test "fills in an id, timestamps and per-goal defaults" do
      goal = Goal.new(objective: "ship it", worker_id: "w-1", verifier: {:shell, "mix test"})

      assert String.starts_with?(goal.id, "goal-")
      assert goal.objective == "ship it"
      assert goal.worker_id == "w-1"
      assert goal.verifier == {:shell, "mix test"}
      assert goal.status == :pending
      assert goal.receipts == []
      assert %DateTime{} = goal.created_at

      # Defaults come from Config, so an operator can move them for the whole node.
      assert goal.max_nudges == Athanor.Config.goal_max_nudges()
      assert goal.stall_after_ms == Athanor.Config.goal_stall_after_ms()
      assert goal.verify_interval_ms == Athanor.Config.goal_verify_interval_ms()
    end

    test "an explicit verifier, nudges and timing win over the defaults" do
      goal =
        Goal.new(
          id: "goal-fixed",
          objective: "ship it",
          worker_id: "w-1",
          verifier: [{:shell, "true"}, {:peer, "is it done?"}],
          max_nudges: 0,
          stall_after_ms: 5,
          verify_interval_ms: 7
        )

      assert goal.id == "goal-fixed"
      assert goal.verifier == [{:shell, "true"}, {:peer, "is it done?"}]
      assert goal.max_nudges == 0
      assert goal.stall_after_ms == 5
      assert goal.verify_interval_ms == 7
    end

    test "refuses a goal with no verifier rather than defaulting one in (C3)" do
      # A silent `{:shell, "mix test"}` default would be run in whatever directory happens to be
      # current, pass against unrelated code, and close a goal that was never achieved.
      for attrs <- [
            [objective: "x", worker_id: "w-1"],
            [objective: "x", worker_id: "w-1", verifier: nil],
            [objective: "x", worker_id: "w-1", verifier: ""]
          ] do
        assert_raise ArgumentError, ~r/needs a verifier/, fn -> Goal.new(attrs) end
      end
    end

    test "refuses a verifier that could never verify, or never be understood" do
      base = [objective: "x", worker_id: "w-1"]

      # An empty AND-list is "verified by everything", i.e. a goal that cannot fail.
      assert_raise ArgumentError, ~r/cannot be empty/, fn ->
        Goal.new(Keyword.put(base, :verifier, []))
      end

      assert_raise ArgumentError, ~r/unrecognised verifier/, fn ->
        Goal.new(Keyword.put(base, :verifier, {:http, "https://example.test"}))
      end

      assert_raise ArgumentError, ~r/non-empty string/, fn ->
        Goal.new(Keyword.put(base, :verifier, {:shell, ""}))
      end
    end

    test "an explicit ATHANOR_GOAL_VERIFY_COMMAND is the only way to get a default" do
      previous = System.get_env("ATHANOR_GOAL_VERIFY_COMMAND")

      try do
        System.put_env("ATHANOR_GOAL_VERIFY_COMMAND", "mix check")

        goal = Goal.new(objective: "x", worker_id: "w-1")
        assert goal.verifier == {:shell, "mix check"}

        # ...and it is read at build time, so it cannot change underneath a running goal.
        System.put_env("ATHANOR_GOAL_VERIFY_COMMAND", "")
        assert_raise ArgumentError, fn -> Goal.new(objective: "x", worker_id: "w-1") end
      after
        restore("ATHANOR_GOAL_VERIFY_COMMAND", previous)
      end
    end
  end

  describe "terminal?/1" do
    test "is true only once the goal can no longer move on its own" do
      goal = Goal.new(objective: "x", worker_id: "w-1", verifier: {:shell, "true"})

      refute Goal.terminal?(goal)

      for status <- [:active, :verifying, :pending] do
        refute Goal.terminal?(%{goal | status: status})
      end

      for status <- [:closed, :escalated, :failed, :cancelled] do
        assert Goal.terminal?(%{goal | status: status})
      end
    end
  end

  describe "with_receipt/2" do
    test "sequences receipts monotonically and stamps the progress clock" do
      goal = Goal.new(objective: "x", worker_id: "w-1", verifier: {:shell, "true"})

      goal =
        goal
        |> Goal.with_receipt(Receipt.new(goal_id: goal.id, worker_id: "w-1", summary: "first"))
        |> Goal.with_receipt(Receipt.new(goal_id: goal.id, worker_id: "w-1", summary: "second"))
        |> Goal.with_receipt(Receipt.new(goal_id: goal.id, worker_id: "w-1", summary: "third"))

      assert Enum.map(goal.receipts, & &1.seq) == [1, 2, 3]
      assert Enum.map(goal.receipts, & &1.summary) == ["first", "second", "third"]
      assert Enum.all?(goal.receipts, &match?(%DateTime{}, &1.at))
      assert is_integer(goal.last_progress_at)
    end

    test "a receipt's own timestamp and sequence are respected when supplied" do
      goal = Goal.new(objective: "x", worker_id: "w-1", verifier: {:shell, "true"})
      at = ~U[2026-01-01 00:00:00Z]

      goal = Goal.with_receipt(goal, Receipt.new(goal_id: goal.id, worker_id: "w-1", summary: "s", at: at))

      assert hd(goal.receipts).at == at
      # Sequence is the goal's to assign, not the author's: it is what makes receipts orderable.
      assert hd(goal.receipts).seq == 1
    end

    test "Receipt.new/1 refuses a receipt with nothing to say" do
      assert_raise ArgumentError, fn -> Receipt.new(goal_id: "g", worker_id: "w") end
    end
  end

  describe "Tools.run_command/2 (C9)" do
    test "reports a completed command as data, including its non-zero exit", %{tmp_dir: dir} do
      assert {:ok, %{output: output, exit_code: 0}} = Tools.run_command("echo hello", cd: dir)
      assert output =~ "hello"

      # A non-zero exit is a *fact about the work*, not a failure of the runner: the whole reason
      # this function exists is that `Athanor.Verifier` has to tell it from a timeout.
      assert {:ok, %{exit_code: 7, output: output}} = Tools.run_command("exit 7", cd: dir)
      assert is_binary(output)
    end

    test "reports a timeout as a timeout, separately from an exit", %{tmp_dir: dir} do
      assert {:timeout, message} = Tools.run_command("sleep 5", cd: dir, timeout: 50)
      assert message =~ "timed out after 50ms"
    end

    test "runs in the directory it was given", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "here.txt"), "x\n")

      assert {:ok, %{output: output, exit_code: 0}} = Tools.run_command("ls", cd: dir)
      assert output =~ "here.txt"
    end

    test "the bash tool's model-facing strings are unchanged by the refactor (C9)" do
      assert {:ok, "hello\n"} = Tools.execute("bash", %{"command" => "echo hello"})
      assert {:error, message} = Tools.execute("bash", %{"command" => "exit 3"})
      assert message =~ "Command exited with status 3"

      assert {:error, message} = Tools.execute("bash", %{"command" => "sleep 5"}, timeout: 50)
      assert message == "Command timed out after 50ms"
    end
  end

  describe "Verifier.verify_shell/2" do
    test "a command that succeeds verifies the goal", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "marker.txt"), "done\n")

      assert {:ok, %Result{mode: :shell, verdict: :verified, command: "test -f marker.txt"}} =
               Verifier.verify_shell("test -f marker.txt", cd: dir)
    end

    test "a non-zero exit is a contradiction, not a failure of the check", %{tmp_dir: dir} do
      assert {:ok, %Result{verdict: :contradicted, evidence: evidence}} =
               Verifier.verify_shell("test -f missing.txt", cd: dir)

      assert evidence =~ "exit 1"
    end

    test "a timeout is inconclusive, never a contradiction", %{tmp_dir: dir} do
      # "We could not tell" and "the work is wrong" call for opposite responses, so a check that did
      # not finish must not be reported as evidence against the worker.
      assert {:ok, %Result{verdict: :inconclusive}} =
               Verifier.verify_shell("sleep 5", cd: dir, timeout: 50)
    end
  end

  describe "Verifier.verify/2" do
    test "a shell spec runs in the goal's cd", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "marker.txt"), "done\n")

      goal = Goal.new(objective: "mark", worker_id: "w-1", cd: dir, verifier: {:shell, "test -f marker.txt"})

      assert {:ok, %Result{verdict: :verified}} = Verifier.verify(goal)
      assert {:ok, %Result{verdict: :contradicted}} = Verifier.verify(%{goal | verifier: {:shell, "false"}})
    end

    test "an AND-list short-circuits on the first contradiction and never invokes later checks (C14)", %{
      tmp_dir: dir
    } do
      test_pid = self()

      peer_llm_fn = fn _messages, _tools, _pid ->
        send(test_pid, :peer_invoked)
        {:ok, %{role: "assistant", content: "===ATHANOR_DONE=== status=ok summary=passed", tool_calls: []}}
      end

      goal =
        Goal.new(
          objective: "x",
          worker_id: "w-1",
          cd: dir,
          verifier: [{:shell, "exit 7"}, {:peer, "is it done?"}]
        )

      assert {:ok, %Result{mode: :shell, verdict: :contradicted}} =
               Verifier.verify(goal, llm_fn: peer_llm_fn)

      refute_received :peer_invoked
    end

    test "an AND-list runs every check when none contradicts", %{tmp_dir: dir} do
      goal =
        Goal.new(
          objective: "x",
          worker_id: "w-1",
          cd: dir,
          verifier: [{:shell, "true"}, {:shell, "test -d ."}]
        )

      assert {:ok, %Result{verdict: :verified}} = Verifier.verify(goal)
    end

    test "peer mode spawns an independent unregistered session (C13) and maps status=ok|fail|none", %{
      tmp_dir: dir
    } do
      test_pid = self()
      goal = Goal.new(objective: "verify README", worker_id: "w-1", cd: dir, verifier: {:peer, "is README good?"})

      ok_llm = fn _messages, _tools, _pid ->
        # C13: while the peer is mid-turn, it must NOT appear in Orchestrator.list_sessions/0!
        send(test_pid, {:sessions_during_peer, Orchestrator.list_sessions()})

        {:ok,
         %{
           role: "assistant",
           content: "Looks great.\n===ATHANOR_DONE=== status=ok summary=README verified",
           tool_calls: []
         }}
      end

      assert {:ok, %Result{mode: :peer, verdict: :verified, evidence: "README verified", peer_id: peer_id}} =
               Verifier.verify(goal, llm_fn: ok_llm)

      assert is_binary(peer_id) and String.starts_with?(peer_id, "verifier-")
      assert_receive {:sessions_during_peer, sessions}
      refute Enum.any?(sessions, &(&1.id == peer_id))

      fail_llm = fn _messages, _tools, _pid ->
        {:ok,
         %{
           role: "assistant",
           content: "Missing section.\n===ATHANOR_DONE=== status=fail summary=missing section",
           tool_calls: []
         }}
      end

      assert {:ok, %Result{mode: :peer, verdict: :contradicted, evidence: "missing section"}} =
               Verifier.verify(goal, llm_fn: fail_llm)

      no_sentinel_llm = fn _messages, _tools, _pid ->
        {:ok, %{role: "assistant", content: "I am unsure.", tool_calls: []}}
      end

      assert {:ok, %Result{mode: :peer, verdict: :inconclusive, evidence: evidence}} =
               Verifier.verify(goal, llm_fn: no_sentinel_llm)

      assert evidence =~ "without ===ATHANOR_DONE=== sentinel"
    end
  end

  describe "Bus.publish_goal_event/3" do
    test "fans out to goal:<id>:events, deck:events, and conductor:<cid>:goals" do
      goal_id = "goal-bus-#{System.unique_integer([:positive])}"
      parent_id = "cond-bus-#{System.unique_integer([:positive])}"

      Bus.subscribe("goal:#{goal_id}:events")
      Bus.subscribe("deck:events")
      Bus.subscribe("conductor:#{parent_id}:goals")

      assert :ok = Bus.publish_goal_event(goal_id, parent_id, {:goal_ping, :ok})

      assert_receive {:goal_event, ^goal_id, {:goal_ping, :ok}}
      assert_receive {:goal_event, ^goal_id, {:goal_ping, :ok}}
      assert_receive {:goal_event, ^goal_id, {:goal_ping, :ok}}
    end
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
