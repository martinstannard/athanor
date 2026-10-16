defmodule Athanor.Worktree.ServerTest do
  # async: false — the worktree root is configured through an environment variable (global), and
  # these tests assert on the shared "deck:events" topic.
  use ExUnit.Case, async: false

  alias Athanor.{Bus, Git, GitRepo, Worktree}
  alias Athanor.Worktree.Server

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Never write to the default `~/.athanor/worktrees` from a test.
    root = Path.join(dir, "worktree-root")
    previous = System.get_env("ATHANOR_WORKTREE_ROOT")
    System.put_env("ATHANOR_WORKTREE_ROOT", root)
    on_exit(fn -> restore("ATHANOR_WORKTREE_ROOT", previous) end)

    repo = GitRepo.init!(Path.join(dir, "repo"))

    {:ok, repo: repo, server: start_supervised!({Server, [repo: repo, name: nil]})}
  end

  test "creates worktrees for many sessions concurrently without racing git", %{server: server} do
    # The case a naive implementation fails: `git worktree add` mutates shared state, so parallel
    # adds can die on a lock file. The Server serialises them.
    sessions = Enum.map(1..8, &"srv-#{&1}")

    results =
      sessions
      |> Enum.map(fn id -> Task.async(fn -> Server.create(id, server: server) end) end)
      |> Task.await_many(60_000)

    assert Enum.all?(results, &match?({:ok, %Worktree{}}, &1))
    assert results |> Enum.map(fn {:ok, wt} -> wt.session_id end) |> Enum.sort() == Enum.sort(sessions)

    paths = Enum.map(results, fn {:ok, wt} -> wt.path end)
    assert length(Enum.uniq(paths)) == length(sessions)
    assert Enum.all?(paths, &File.regular?(Path.join(&1, ".git")))

    assert length(Server.list_sessions(server: server)) == length(sessions)
  end

  test "path_for/1 answers for a tracked session and :error for an unknown one", %{server: server} do
    assert {:ok, wt} = Server.create("srv-known", server: server)

    assert_path("srv-known", server, wt.path)
    assert :error = Server.path_for("srv-nobody", server: server)
  end

  test "create_for_session/2 is the create-or-reuse seam the Agent uses", %{server: server} do
    assert {:ok, first} = Server.create_for_session("srv-spawn", server: server)
    assert {:ok, second} = Server.create_for_session("srv-spawn", server: server)

    assert second.path == first.path
    assert_path("srv-spawn", server, first.path)
  end

  test "list_sessions/0 returns the tracked worktrees", %{server: server} do
    assert {:ok, one} = Server.create("srv-one", server: server)
    assert {:ok, two} = Server.create("srv-two", server: server)

    listed = Server.list_sessions(server: server)

    assert listed |> Enum.map(& &1.session_id) |> Enum.sort() == ["srv-one", "srv-two"]
    assert listed |> Enum.map(& &1.path) |> Enum.sort() == Enum.sort([one.path, two.path])
  end

  test "a creation is published once, and re-use publishes nothing", %{server: server} do
    Bus.subscribe("deck:events")

    assert {:ok, wt} = Server.create("srv-event", server: server)
    assert_receive {:agent_event, "srv-event", {:worktree_created, %Worktree{path: path}}}, 2_000
    assert path == wt.path

    # The event marks a new worktree, not a lookup: a second create for the same session is a
    # re-use and must not re-announce it.
    assert {:ok, _again} = Server.create("srv-event", server: server)
    refute_receive {:agent_event, "srv-event", {:worktree_created, _}}, 200
  end

  test "destroy/2 removes the worktree, untracks it and publishes the removal", %{
    server: server,
    repo: repo
  } do
    Bus.subscribe("deck:events")

    assert {:ok, wt} = Server.create("srv-destroy", server: server)
    assert :ok = Server.destroy("srv-destroy", server: server)

    refute File.exists?(wt.path)
    assert :error = Server.path_for("srv-destroy", server: server)

    assert_receive {:agent_event, "srv-destroy", {:worktree_removed, "srv-destroy", path}}, 2_000
    assert path == wt.path

    # The default branch policy is :keep.
    assert match?({:ok, _}, Git.run(["rev-parse", "--verify", "refs/heads/athanor/srv-destroy"], cd: repo))
  end

  test "a refused removal leaves the session tracked", %{server: server} do
    assert {:ok, wt} = Server.create("srv-dirty", server: server)
    File.write!(Path.join(wt.path, "wip.txt"), "wip\n")

    assert {:error, {:dirty_worktree, ["wip.txt"]}} = Server.destroy("srv-dirty", server: server)

    # Still tracked, because the worktree is still there — dropping it from the map would hide work.
    assert_path("srv-dirty", server, wt.path)

    assert :ok = Server.destroy("srv-dirty", server: server, force: true)
    assert :error = Server.path_for("srv-dirty", server: server)
  end

  test "destroy/2 reports an untracked session", %{server: server} do
    assert {:error, :unknown_session} = Server.destroy("srv-unknown", server: server)
  end

  test "create/2 passes a refusal through and tracks nothing", %{server: server, repo: repo} do
    File.write!(Path.join(repo, "scratch.txt"), "notes\n")

    assert {:error, {:dirty_worktree_source, summary}} = Server.create("srv-blocked", server: server)
    assert summary =~ "scratch.txt"
    assert :error = Server.path_for("srv-blocked", server: server)
  end

  # -- rebuild (plan §2.5) -------------------------------------------------------------------

  test "init/1 rebuilds the map from git and the sidecar after a restart", %{
    server: server,
    repo: repo
  } do
    assert {:ok, one} = Server.create("srv-rb-one", server: server)
    assert {:ok, two} = Server.create("srv-rb-two", server: server)

    stop_supervised!(Server)
    restarted = start_supervised!({Server, [repo: repo, name: nil]})

    assert restarted
           |> then(&Server.list_sessions(server: &1))
           |> Enum.map(& &1.session_id)
           |> Enum.sort() == ["srv-rb-one", "srv-rb-two"]

    assert_path("srv-rb-one", restarted, one.path)
    assert_path("srv-rb-two", restarted, two.path)

    # Creation times are what the sidecar carries that git does not.
    assert Enum.all?(Server.list_sessions(server: restarted), &(&1.created_at != nil))
    assert Enum.all?(Server.list_sessions(server: restarted), &(&1.branch =~ "athanor/"))
  end

  test "a sidecar entry whose worktree is gone is dropped on rebuild", %{server: server, repo: repo} do
    assert {:ok, wt} = Server.create("srv-stale", server: server)

    # The directory vanishes out from under git, as if a user deleted it by hand.
    File.rm_rf!(wt.path)

    stop_supervised!(Server)
    restarted = start_supervised!({Server, [repo: repo, name: nil]})

    assert :error = Server.path_for("srv-stale", server: restarted)
    assert Server.list_sessions(server: restarted) == []
  end

  test "a worktree git knows about is attributed by its branch when the sidecar is missing", %{
    server: server,
    repo: repo
  } do
    assert {:ok, wt} = Server.create("srv-orphan", server: server)

    # Lose the sidecar: the worktree is still real, git still lists it, and the branch names its
    # owner — `branch_for/1` is "<prefix><session_id>", which is exactly why that is enough.
    File.rm!(Server.sidecar_path(repo))

    stop_supervised!(Server)
    restarted = start_supervised!({Server, [repo: repo, name: nil]})

    assert_path("srv-orphan", restarted, wt.path)
    assert [%Worktree{branch: "athanor/srv-orphan"}] = Server.list_sessions(server: restarted)
  end

  # -- prune (plan §4.4) ---------------------------------------------------------------------

  test "prune/1 clears metadata for a directory that is gone, and never a directory", %{
    server: server
  } do
    assert {:ok, live} = Server.create("srv-live", server: server)

    # Nothing stale: prune is a no-op and touches nothing.
    assert {:ok, []} = Server.prune(server: server)
    assert File.exists?(live.path)

    assert {:ok, vanished} = Server.create("srv-vanished", server: server)
    File.rm_rf!(vanished.path)

    assert {:ok, [name]} = Server.prune(server: server)
    assert is_binary(name)

    # The vanished session is gone from the map; the live one is untouched.
    assert :error = Server.path_for("srv-vanished", server: server)
    assert_path("srv-live", server, live.path)
    assert File.exists?(live.path)
  end

  # -- events on "deck:events" ---------------------------------------------------------------

  test "prune publishes on deck:events when it actually pruned something", %{server: server} do
    Bus.subscribe("deck:events")

    assert {:ok, vanished} = Server.create("srv-prune-event", server: server)
    File.rm_rf!(vanished.path)

    # The session id is only knowable while the metadata exists.
    assert {:ok, [name]} = Server.prune(server: server)
    assert name == "srv-prune-event"

    assert_receive {:agent_event, "worktree", {:worktree_pruned, ["srv-prune-event"]}}, 2_000
  end

  defp assert_path(session_id, server, expected) do
    assert {:ok, path} = Server.path_for(session_id, server: server)
    assert path == expected
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
