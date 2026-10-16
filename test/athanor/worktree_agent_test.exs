defmodule Athanor.Worktree.AgentTest do
  # async: false — the worktree root is configured through an environment variable (global) and
  # these tests drive real agents through the shared Bus.
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, Git, GitRepo, Orchestrator, Worktree}
  alias Athanor.Worktree.Server, as: WorktreeServer

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Never write to the default `~/.athanor/worktrees` from a test.
    root = Path.join(dir, "worktree-root")
    previous = System.get_env("ATHANOR_WORKTREE_ROOT")
    System.put_env("ATHANOR_WORKTREE_ROOT", root)
    on_exit(fn -> restore("ATHANOR_WORKTREE_ROOT", previous) end)

    repo = GitRepo.init!(Path.join(dir, "repo"))

    # Sessions spawned through the Orchestrator have no direct subscriber, so their events arrive on
    # the shared topic (3-tuples carrying the session id) rather than at a pid.
    Bus.subscribe("deck:events")

    {:ok, repo: repo, root: root}
  end

  test "a worker spawned with worktree: true writes inside its worktree, not the parent repo", %{
    repo: repo,
    root: root
  } do
    parent = start_conductor!(repo)
    worker_llm = write_file_llm_fn("worker-output.txt", "written by the worker\n")

    assert {:ok, worker_id, worker_pid} =
             Orchestrator.launch_subagent(parent, "isolated worker", "write the file",
               worktree: true,
               llm_fn: worker_llm,
               # Keep the conductor's history to a single clean turn.
               notify_parent_on_done: false
             )

    assert_receive {:agent_event, ^worker_id, {:turn_complete, _answer}}, 10_000

    worktree_cd = Agent.get_state(worker_pid).cd

    # The worker's `cd` is its own checkout, under the configured root, not the parent's repo...
    assert worktree_cd != Path.expand(repo)
    assert String.starts_with?(worktree_cd, root)

    # ...and it is registered, so anything that only knows the session id can find it (§7.2).
    assert {:ok, worktree_cd} = WorktreeServer.path_for(worker_id)

    # The write landed in the worktree...
    assert File.read!(Path.join(worktree_cd, "worker-output.txt")) == "written by the worker\n"

    # ...and *not* in the repository the parent is working in, which is still clean: that is the
    # isolation this whole feature exists for (plan §14.1).
    refute File.exists?(Path.join(repo, "worker-output.txt"))
    assert Worktree.clean?(repo)

    cleanup([parent, worker_id])
  end

  test "two isolated workers get their own worktrees and cannot see each other's files", %{
    repo: repo
  } do
    parent = start_conductor!(repo)

    spawn_isolated_worker = fn id, filename ->
      Orchestrator.launch_subagent(parent, "worker #{id}", "write #{filename}",
        id: id,
        worktree: true,
        llm_fn: write_file_llm_fn(filename, "from #{id}\n"),
        notify_parent_on_done: false
      )
    end

    assert {:ok, _id_a, pid_a} = spawn_isolated_worker.("wt-a", "a.txt")
    assert {:ok, _id_b, pid_b} = spawn_isolated_worker.("wt-b", "b.txt")

    assert_receive {:agent_event, "wt-a", {:turn_complete, _}}, 10_000
    assert_receive {:agent_event, "wt-b", {:turn_complete, _}}, 10_000

    cd_a = Agent.get_state(pid_a).cd
    cd_b = Agent.get_state(pid_b).cd

    assert cd_a != cd_b
    assert File.exists?(Path.join(cd_a, "a.txt"))
    refute File.exists?(Path.join(cd_a, "b.txt"))
    assert File.exists?(Path.join(cd_b, "b.txt"))
    refute File.exists?(Path.join(cd_b, "a.txt"))

    # Neither worker touched the parent's working tree.
    refute File.exists?(Path.join(repo, "a.txt"))
    refute File.exists?(Path.join(repo, "b.txt"))
    assert Worktree.clean?(repo)

    cleanup([parent, "wt-a", "wt-b"])
  end

  test "a dirty source repo refuses the spawn instead of hiding the user's work", %{repo: repo} do
    parent = start_conductor!(repo)
    File.write!(Path.join(repo, "user-wip.txt"), "not committed yet\n")

    assert {:error, {:dirty_worktree_source, summary}} =
             Orchestrator.launch_subagent(parent, "blocked worker", "do something",
               id: "wt-blocked",
               worktree: true,
               llm_fn: write_file_llm_fn("never.txt", "should not happen\n"),
               notify_parent_on_done: false
             )

    assert summary =~ "user-wip.txt"

    # No worker, no worktree, and the user's uncommitted file is untouched.
    assert :error = WorktreeServer.path_for("wt-blocked")
    assert File.exists?(Path.join(repo, "user-wip.txt"))

    cleanup([parent])
  end

  test "worktree: false leaves the worker in the parent's working tree", %{repo: repo} do
    parent = start_conductor!(repo)

    assert {:ok, worker_id, worker_pid} =
             Orchestrator.launch_subagent(parent, "plain worker", "write the file",
               worktree: false,
               llm_fn: write_file_llm_fn("plain-output.txt", "no isolation\n"),
               notify_parent_on_done: false
             )

    assert_receive {:agent_event, ^worker_id, {:turn_complete, _}}, 10_000

    # This is the one test whose worker writes into the *parent's* tree, so it cleans up after
    # itself unconditionally: a stray file in the real repository is worse than a failed assertion.
    written = Path.join(repo, "plain-output.txt")
    on_exit(fn -> File.rm(written) end)

    assert Agent.get_state(worker_pid).cd == Path.expand(repo)
    assert File.exists?(written)

    cleanup([parent, worker_id])
  end

  test "the worktree's own history branches from the parent's committed HEAD", %{repo: repo} do
    parent = start_conductor!(repo)

    assert {:ok, worker_id, worker_pid} =
             Orchestrator.launch_subagent(parent, "branched worker", "write the file",
               id: "wt-branch",
               worktree: true,
               llm_fn: write_file_llm_fn("f.txt", "x\n"),
               notify_parent_on_done: false
             )

    assert_receive {:agent_event, ^worker_id, {:turn_complete, _}}, 10_000

    cd = Agent.get_state(worker_pid).cd
    head = repo |> then(&Git.run(["rev-parse", "HEAD"], cd: &1)) |> elem(1) |> Map.get(:output)
    worktree_head = cd |> then(&Git.run(["rev-parse", "HEAD"], cd: &1)) |> elem(1) |> Map.get(:output)

    assert String.trim(worktree_head) == String.trim(head)

    assert cd |> then(&Git.run(["branch", "--show-current"], cd: &1)) |> elem(1) |> Map.get(:output) ==
             "athanor/wt-branch\n"

    cleanup([parent, worker_id])
  end

  # -- helpers --------------------------------------------------------------------------------

  defp start_conductor!(repo) do
    # Unique per test: the session Registry is global and these tests are `async: false`, so a
    # leftover registration from a previous test would collide.
    id = "wt-conductor-#{System.unique_integer([:positive])}"

    {:ok, id, _pid} =
      Orchestrator.spawn_session(
        id: id,
        role: :conductor,
        title: "Worktree Conductor",
        cd: repo,
        llm_fn: fn _messages, _tools, _pid ->
          {:ok, %{role: "assistant", content: "ready", tool_calls: []}}
        end
      )

    id
  end

  # A fake provider that asks for exactly one `write_file` and then answers: what matters is that
  # the *tool* resolves the relative path against the worker's `cd`.
  defp write_file_llm_fn(path, content) do
    fn messages, _tools, _pid ->
      if Enum.any?(messages, &(role(&1) == "tool")) do
        {:ok, %{role: "assistant", content: "written", tool_calls: []}}
      else
        {:ok,
         %{
           role: "assistant",
           content: "",
           tool_calls: [
             %{
               id: "call_write",
               type: "function",
               function: %{
                 name: "write_file",
                 arguments: JSON.encode!(%{"path" => path, "content" => content})
               }
             }
           ]
         }}
      end
    end
  end

  defp role(message), do: Map.get(message, :role) || Map.get(message, "role")

  defp cleanup(ids) do
    for id <- ids do
      case Orchestrator.lookup(id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)
        :error -> :ok
      end
    end
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
