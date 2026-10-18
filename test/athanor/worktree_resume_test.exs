defmodule Athanor.Worktree.ResumeTest do
  @moduledoc """
  Issue #58: a resumed worktree worker must come back in **its own** checkout.

  The breach: `--restart --resume` rebuilt every session's `cd` from `meta.json`, which held the
  repository root (the worktree path was only ever computed on the create path and never recorded).
  A resumed worker then resolved *relative* paths into the main checkout — one landed 51 lines in
  `main`'s `lib/athanor/daemon.ex` while its own worktree stayed clean.

  So these tests are about the location a resume picks, and they set up the worktree mapping
  explicitly instead of depending on the ambient repository: `worktree: true` needs a clean repo to
  create a worktree, which makes it a poor probe for anything else.
  """
  # async: false — the worktree root is configured through an environment variable (global), and
  # these tests drive real agents through the shared Bus.
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, GitRepo, Orchestrator, Store, Tools, Worktree}
  alias Athanor.Store.Recorder
  alias Athanor.Worktree.Server, as: WorktreeServer

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Never write to the default `~/.athanor/worktrees` from a test.
    root = Path.join(dir, "worktree-root")
    previous = System.get_env("ATHANOR_WORKTREE_ROOT")
    System.put_env("ATHANOR_WORKTREE_ROOT", root)
    on_exit(fn -> restore("ATHANOR_WORKTREE_ROOT", previous) end)

    repo = GitRepo.init!(Path.join(dir, "repo"))
    store = Path.join(dir, "store")

    # An instance the test owns: the mapping must not come from whatever the shared Server happens
    # to track for the real checkout.
    server = start_supervised!({WorktreeServer, [repo: repo, name: nil]})

    {:ok, repo: repo, store: store, server: server}
  end

  test "a resumed worker whose worktree is still mapped comes back in the worktree, not the repo root",
       %{repo: repo, store: store, server: server} do
    id = "wt-resume-mapped"

    assert {:ok, %Worktree{path: worktree_path}} =
             WorktreeServer.create_for_session(id, server: server)

    # Exactly the record the old code left behind: `cd` is the repository the worktree was branched
    # from, and nothing on the record mentions a worktree at all.
    assert :ok = save_session(id, repo, store)

    assert {:ok, ^id, pid} =
             Orchestrator.resume_session(id, root: store, worktree_server: server)

    state = Agent.get_state(pid)

    # The assertion this whole issue is about. Before the fix this was `repo` — and every relative
    # `edit_file` therefore wrote into the main checkout.
    assert state.cd == worktree_path
    assert state.cd != Path.expand(repo)

    # ...and the resumed session still knows it is worktree-bound, so the write guard below stays
    # armed across the restart rather than only for the life of the original process.
    assert state.worktree_path == worktree_path

    cleanup([id])
  end

  test "a worktree worker's session record carries the path, so a later resume needs no mapping", %{
    repo: repo,
    store: store
  } do
    # The write half of #58: the path has to reach `meta.json` through the one writer (the
    # Recorder), or a resume has only in-memory state to go on — and after a restart there is none.
    start_supervised!({Recorder, [root: store, name: nil]})
    Bus.subscribe("deck:events")

    {:ok, parent, _parent_pid} =
      Orchestrator.spawn_session(
        id: "wtres-parent",
        role: :conductor,
        title: "Worktree Conductor",
        cd: repo,
        llm_fn: fn _messages, _tools, _pid ->
          {:ok, %{role: "assistant", content: "ready", tool_calls: []}}
        end
      )

    assert {:ok, id, worker_pid} =
             Orchestrator.launch_subagent(parent, "isolated worker", "look around",
               id: "wtres-worker",
               worktree: true,
               llm_fn: fn _messages, _tools, _pid ->
                 {:ok, %{role: "assistant", content: "done", tool_calls: []}}
               end,
               notify_parent_on_done: false
             )

    assert_receive {:agent_event, ^id, {:turn_complete, _answer}}, 10_000

    worktree_path = Agent.get_state(worker_pid).cd
    assert worktree_path != Path.expand(repo)

    session = await_session(id, store, &(&1.worktree_path == worktree_path))

    # Both halves are recorded: where the session works, and that it works in a worktree at all.
    assert session.cd == worktree_path
    assert session.worktree_path == worktree_path

    cleanup([parent, id])

    # A restart has no Server state to consult (`worktree_server: nil`), so this is the record
    # alone — the "resume after the daemon forgot everything" case.
    assert {:ok, ^id, resumed_pid} =
             Orchestrator.resume_session(id, root: store, worktree_server: nil)

    assert Agent.get_state(resumed_pid).cd == worktree_path

    cleanup([id])
  end

  test "a recorded worktree path survives a resume that cannot ask the Server", %{
    repo: repo,
    store: store
  } do
    id = "wt-resume-recorded"
    worktree_path = Path.join(Path.dirname(repo), "recorded-worktree")
    File.mkdir_p!(worktree_path)

    # New records carry the path themselves (`Athanor.Agent` reports it at start, the Recorder
    # persists it), which is what makes a resume independent of in-memory state.
    assert :ok = save_session(id, repo, store, worktree_path: worktree_path)

    # `worktree_server: nil` is a deliberate "no mapping available": only the record can answer.
    assert {:ok, ^id, pid} =
             Orchestrator.resume_session(id, root: store, worktree_server: nil)

    assert Agent.get_state(pid).cd == Path.expand(worktree_path)

    cleanup([id])
  end

  test "a recorded worktree that no longer exists is skipped, not resumed in the repo root", %{
    repo: repo,
    store: store
  } do
    id = "wt-resume-pruned"
    pruned = Path.join(Path.dirname(repo), "pruned-worktree")

    # Recorded, then removed from disk — what a `git worktree prune` or a hand-deleted directory
    # leaves behind. The path is the only evidence the session ever had a worktree.
    assert :ok = save_session(id, repo, store, worktree_path: pruned)

    assert {:ok, ids, skipped} = Orchestrator.resume_all(root: store)

    refute id in ids

    assert %{id: ^id, reason: {:worktree_missing, ^pruned}} =
             Enum.find(skipped, &(&1.id == id))

    # The failure mode this replaces: the worker coming back in the main checkout, editing it.
    assert :error = Orchestrator.lookup(id)
  end

  test "a session that never had a worktree still resumes in its recorded cd", %{
    repo: repo,
    store: store
  } do
    id = "wt-resume-plain"
    assert :ok = save_session(id, repo, store)

    assert {:ok, ^id, pid} = Orchestrator.resume_session(id, root: store)

    assert Agent.get_state(pid).cd == Path.expand(repo)
    assert Agent.get_state(pid).worktree_path == nil

    cleanup([id])
  end

  # -- belt and braces: a worktree session cannot write into another checkout ----------------

  test "a worktree session's write into another checkout is refused, inside its own is not", %{
    server: server,
    repo: repo
  } do
    id = "wt-guard"
    assert {:ok, %Worktree{path: worktree_path}} = WorktreeServer.create_for_session(id, server: server)
    opts = [cd: worktree_path, session_id: id, role: :worker, worktree: worktree_path]

    # The breach's shape: an absolute path that names the main checkout. `cd` cannot protect this,
    # because the path does not go through `cd` at all.
    target = Path.join(repo, "lib/athanor/daemon.ex")
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, "main\n")

    # Reading the other checkout is never restricted: comparing against main is legitimate work.
    # It also satisfies §7.6's read-before-write guard, so what refuses the write below can only be
    # the worktree rule.
    assert {:ok, "main\n"} = Tools.execute("read_file", %{"path" => target}, opts)

    assert {:error, message} =
             Tools.execute("write_file", %{"path" => target, "content" => "contaminated\n"}, opts)

    assert message =~ "Refusing to write"
    assert message =~ worktree_path
    assert File.read!(target) == "main\n"

    # The same path, relative, lands where it should and is allowed.
    assert {:ok, _written} =
             Tools.execute(
               "write_file",
               %{"path" => "lib/athanor/daemon.ex", "content" => "mine\n"},
               opts
             )

    assert File.read!(Path.join(worktree_path, "lib/athanor/daemon.ex")) == "mine\n"
    assert File.read!(target) == "main\n"

    cleanup([id])
  end

  test "a session without a worktree is not restricted by the guard", %{repo: repo} do
    target = Path.join(repo, "lib/scratch.ex")
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, "old\n")

    # No `:worktree` in the options — the plain case must behave exactly as it did before #58.
    opts = [cd: repo, session_id: "no-worktree-session", role: :worker]
    assert {:ok, "old\n"} = Tools.execute("read_file", %{"path" => target}, opts)

    assert {:ok, _written} =
             Tools.execute("write_file", %{"path" => target, "content" => "new\n"}, opts)

    assert File.read!(target) == "new\n"
  end

  # -- helpers ------------------------------------------------------------------------------

  # The minimum a resumable session needs on disk. `cd` is the repository root because that is what
  # the pre-_#58_ Recorder wrote (`Session.new/1` defaulted to the Recorder's own directory), and
  # reproducing it is the point: that record plus a live mapping is the reported bug.
  defp save_session(id, cd, root, extra \\ []) do
    Store.ensure_session(
      [id: id, role: :worker, parent_id: nil, title: "Resumed", cd: cd] ++ extra,
      root: root
    )
  end

  # The Recorder is asynchronous, so `meta.json` appears behind the event that caused it. Bounded
  # polling keeps the assertion about the field rather than about timing.
  defp await_session(id, root, predicate, attempts \\ 200)

  defp await_session(id, _root, predicate, 0) do
    flunk("session #{id} never satisfied #{inspect(predicate)}")
  end

  defp await_session(id, root, predicate, attempts) do
    case Store.load(id, root: root) do
      {:ok, session} ->
        if predicate.(session) do
          session
        else
          Process.sleep(10) && await_session(id, root, predicate, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(10) && await_session(id, root, predicate, attempts - 1)
    end
  end

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
