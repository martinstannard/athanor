defmodule Athanor.WorktreeTest do
  # async: false — the inside-repo test mutates ATHANOR_WORKTREE_INSIDE globally.
  use ExUnit.Case, async: false

  alias Athanor.{Config, Git, GitRepo, Worktree}

  @moduletag :tmp_dir

  describe "repository?/1 and clean?/1" do
    test "detects a repository and reports a clean tree", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert Worktree.repository?(repo)
      assert Worktree.clean?(repo)
      assert Worktree.summary(repo) == "clean"
    end

    test "reports a directory outside any repository as neither a repo nor clean" do
      # Deliberately NOT under `:tmp_dir`: that lives inside the athanor repository, so a "plain"
      # subdirectory there is still inside a work tree (git reports the enclosing repository).
      plain = outside_repo_dir!("plain")

      refute Worktree.repository?(plain)
      # A git command that cannot run is not evidence of a clean tree.
      refute Worktree.clean?(plain)
    end

    test "counts an untracked file as dirty and names it", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      File.write!(Path.join(repo, "scratch.txt"), "notes\n")

      refute Worktree.clean?(repo)
      assert Worktree.summary(repo) =~ "1 changed path"
      assert Worktree.summary(repo) =~ "scratch.txt"
    end
  end

  describe "list/1" do
    test "marks the main working tree and reads branch names", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert [main_entry] = Worktree.list(repo)
      assert main_entry.main?
      assert main_entry.branch == "main"
      assert main_entry.path == Path.expand(repo)
      refute main_entry.detached?
      assert is_binary(main_entry.head)
    end

    test "reports a linked worktree, including a detached one", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      on_branch = Path.join(dir, "wt-branch")
      detached = Path.join(dir, "wt-detached")

      GitRepo.git!(repo, ["worktree", "add", "-q", "-b", "athanor/w1", on_branch])
      GitRepo.git!(repo, ["worktree", "add", "-q", "--detach", detached])

      entries = Worktree.list(repo)
      assert length(entries) == 3

      branchless = Enum.find(entries, &(&1.path == Path.expand(on_branch)))
      assert branchless.branch == "athanor/w1"
      refute branchless.detached?

      det = Enum.find(entries, &(&1.path == Path.expand(detached)))
      assert det.branch == nil
      assert det.detached?
      refute det.main?
    end

    test "returns an empty list for a directory outside any repository" do
      assert Worktree.list(outside_repo_dir!("plain-list")) == []
    end
  end

  describe "branch_for/1 and root_for/2" do
    test "branch names are unique per session and prefixed", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert Worktree.branch_for("worker-1q-9c1d") == "athanor/worker-1q-9c1d"
      refute Worktree.branch_for("a") == Worktree.branch_for("b")
      assert Worktree.branch_for("x") == "#{Config.worktree_branch_prefix()}x"
      _ = repo
    end

    test "places a worktree outside the repository by default", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      root = Worktree.root_for(repo, "worker-1")

      assert String.starts_with?(root, Config.worktree_root())
      assert String.ends_with?(root, "/worker-1")
      # The repository's own path appears only as the stable `<slug>-<hash>` key, never as a parent.
      refute String.starts_with?(root, Path.expand(repo))
      assert Path.basename(Path.dirname(root)) == Worktree.repo_key(repo)
    end

    test "the repo key is stable across commits and differs between repositories", %{tmp_dir: dir} do
      repo_a = GitRepo.init!(Path.join(dir, "a"))
      repo_b = GitRepo.init!(Path.join(dir, "b"))

      key_a = Worktree.repo_key(repo_a)
      assert key_a == Worktree.repo_key(repo_a)

      # A commit must not move existing worktrees, so the key cannot be derived from a commit.
      GitRepo.commit!(repo_a, "more.txt", "x\n", "second commit")
      assert Worktree.repo_key(repo_a) == key_a

      refute key_a == Worktree.repo_key(repo_b)
    end

    test "places a worktree inside the repository when configured to", %{tmp_dir: dir} do
      previous = System.get_env("ATHANOR_WORKTREE_INSIDE")

      try do
        System.put_env("ATHANOR_WORKTREE_INSIDE", "1")
        repo = GitRepo.init!(Path.join(dir, "repo"))

        assert Config.worktree_inside_repo?()

        assert Worktree.root_for(repo, "worker-1") ==
                 Path.join([Path.expand(repo), ".athanor", "worktrees", "worker-1"])
      after
        restore("ATHANOR_WORKTREE_INSIDE", previous)
      end
    end
  end

  describe "config" do
    test "worktree_root/0 is always an absolute path" do
      root = Config.worktree_root()
      assert Path.type(root) == :absolute
      refute root =~ "~"
    end

    test "worktree_git_timeout_ms/0 cannot be disabled by a bad value" do
      previous = System.get_env("ATHANOR_WORKTREE_GIT_TIMEOUT_MS")

      try do
        System.put_env("ATHANOR_WORKTREE_GIT_TIMEOUT_MS", "0")
        assert Config.worktree_git_timeout_ms() > 0
      after
        restore("ATHANOR_WORKTREE_GIT_TIMEOUT_MS", previous)
      end
    end

    test "boolean accessors parse the documented spellings" do
      previous = System.get_env("ATHANOR_WORKTREE_ALLOW_DIRTY")

      try do
        for {value, expected} <- [{"1", true}, {"true", true}, {"YES", true}, {"0", false}, {"no", false}] do
          System.put_env("ATHANOR_WORKTREE_ALLOW_DIRTY", value)
          assert Config.worktree_allow_dirty?() == expected, "expected #{value} -> #{expected}"
        end
      after
        restore("ATHANOR_WORKTREE_ALLOW_DIRTY", previous)
      end

      # Default when unset.
      System.delete_env("ATHANOR_WORKTREE_ALLOW_DIRTY")
      refute Config.worktree_allow_dirty?()
    end
  end

  # -- add/2 and remove/2 (plan §M2) ----------------------------------------------

  # Every assertion here is one of the git behaviours verified against git 2.56.0 in the plan
  # (§0.2). They are the reason the module is shaped the way it is, so they are pinned against
  # real repositories rather than a fake.
  describe "add/2 and remove/2 (§M2)" do
    # `~/.athanor/worktrees` is the default root, and a test must never write to the user's home:
    # pin it for every test in this block (this module is `async: false`).
    setup %{tmp_dir: dir} do
      root = Path.join(dir, "worktree-root")
      previous = System.get_env("ATHANOR_WORKTREE_ROOT")
      System.put_env("ATHANOR_WORKTREE_ROOT", root)
      on_exit(fn -> restore("ATHANOR_WORKTREE_ROOT", previous) end)

      {:ok, worktree_root: root}
    end

    test "creates a real worktree on its own branch", %{tmp_dir: dir, worktree_root: root} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, wt} = Worktree.add("m2-worker", repo: repo)

      assert wt.session_id == "m2-worker"
      assert wt.path == Path.join([root, Worktree.repo_key(repo), "m2-worker"])
      assert wt.branch == "athanor/m2-worker"
      assert wt.repo == Path.expand(repo)
      assert byte_size(wt.base_sha) == 40

      # A worktree's `.git` is a *file* pointing into the main repository: worktrees share the
      # object database, they are not clones (§0.2).
      assert File.regular?(Path.join(wt.path, ".git"))
      assert File.read!(Path.join(wt.path, ".git")) =~ "gitdir:"

      # It is a usable checkout of the committed tree.
      assert File.exists?(Path.join(wt.path, "README.md"))

      # git agrees, and the main working tree is still the main one.
      assert Enum.any?(
               Worktree.list(repo),
               &(&1.path == wt.path and &1.branch == "athanor/m2-worker" and not &1.main?)
             )

      assert Enum.any?(Worktree.list(repo), & &1.main?)
    end

    test "refuses a dirty source repo and names the offending paths", %{tmp_dir: dir} do
      # The rule that matters (§2.4): a worktree branches from committed HEAD, so a worker
      # created from a dirty repo silently cannot see the user's in-flight edits.
      repo = GitRepo.init!(Path.join(dir, "repo"))
      File.write!(Path.join(repo, "scratch.txt"), "notes\n")

      assert {:error, {:dirty_worktree_source, summary}} = Worktree.add("m2-dirty", repo: repo)
      assert summary =~ "scratch.txt"

      # Nothing was created, and the source tree is untouched.
      refute File.exists?(Worktree.root_for(repo, "m2-dirty"))
      assert File.exists?(Path.join(repo, "scratch.txt"))
    end

    test "allow_dirty: true proceeds, reports the base commit, and the edit stays invisible", %{
      tmp_dir: dir
    } do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      base = repo |> then(&GitRepo.git!(&1, ["rev-parse", "HEAD"])) |> String.trim()
      File.write!(Path.join(repo, "scratch.txt"), "notes\n")

      assert {:ok, wt} = Worktree.add("m2-allowed", repo: repo, allow_dirty: true)

      # The commit it branched from, so a caller knows what the worker can actually see.
      assert wt.base_sha == base

      # ...and the uncommitted edit is genuinely not there (§0.2's decisive constraint).
      refute File.exists?(Path.join(wt.path, "scratch.txt"))
    end

    test "a second add for the same session hands back the same worktree", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, first} = Worktree.add("m2-again", repo: repo)
      assert {:ok, second} = Worktree.add("m2-again", repo: repo)

      assert second.path == first.path
      assert second.branch == first.branch
      assert length(Enum.filter(Worktree.list(repo), &(&1.path == first.path))) == 1
    end

    test "re-attaches the branch when a removed worktree's branch was kept", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      {:ok, wt} = Worktree.add("m2-reattach", repo: repo)
      GitRepo.commit!(wt.path, "worker.txt", "work\n", "worker commit")

      # The default policy keeps the branch (§4.2)...
      assert :ok = Worktree.remove(wt, repo: repo)
      assert branch_exists?(repo, "athanor/m2-reattach")

      # ...so re-spawning the session attaches that branch instead of failing with "a branch named
      # … already exists", and the worker's own commit comes back with it.
      assert {:ok, again} = Worktree.add("m2-reattach", repo: repo)
      assert again.branch == "athanor/m2-reattach"
      assert File.exists?(Path.join(again.path, "worker.txt"))
    end

    test "detached mode leaves the worktree on no branch", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, wt} = Worktree.add("m2-detached", repo: repo, branch: false)

      assert wt.branch == nil
      assert Enum.find(Worktree.list(repo), &(&1.path == wt.path)).detached?
      refute branch_exists?(repo, "athanor/m2-detached")
    end

    # -- #47: the worktree-private `_build` ---------------------------------------------------

    test "seeds a worktree-local _build so `mix` compiles privately with no flag", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, wt} = Worktree.add("m2-build", repo: repo)

      build = Worktree.build_dir(wt.path)
      assert build == Path.join(wt.path, "_build")
      # A real directory, not a symlink into another checkout: that distinction is the whole of #47.
      assert File.dir?(build)
      refute symlink?(build)
      # And it is the directory plain `mix` uses, because Athanor deliberately never sets
      # MIX_BUILD_PATH — the private build must be mix's *default* inside the worktree, not something
      # a prompt has to remember to ask for.
      assert System.get_env("MIX_BUILD_PATH") in [nil, ""]
    end

    test "the seeded _build cannot make the worktree look dirty", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, wt} = Worktree.add("m2-clean", repo: repo)

      # The seed carries its own `.gitignore` (`*`), so it stays invisible to git whether or not the
      # repository ignores `_build/`. Leaning on the repository's own ignore would leave a repo
      # without one looking dirty (`clean?/1` false, `remove/2` refusing a perfectly good worktree).
      assert File.read!(Path.join(Worktree.build_dir(wt.path), ".gitignore")) =~ "*"
      assert Worktree.clean?(wt.path)

      # Real artefacts in it change nothing either, and removal still works without `force`.
      File.mkdir_p!(Path.join([wt.path, "_build", "dev", "lib", "app", "ebin"]))
      File.write!(Path.join([wt.path, "_build", "dev", "lib", "app", "ebin", "app.beam"]), "beam")

      assert Worktree.clean?(wt.path)
      assert Worktree.summary(wt.path) == "clean"
      assert :ok = Worktree.remove(wt, repo: repo)
      refute File.exists?(wt.path)
    end

    test "two worktrees get two distinct _build directories", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, one} = Worktree.add("m2-build-a", repo: repo)
      assert {:ok, two} = Worktree.add("m2-build-b", repo: repo)

      # The collision that motivated #47, in one assertion: siblings must never share a build
      # directory, so a `mix check` in one cannot read a half-written `.beam` from the other.
      refute Worktree.build_dir(one.path) == Worktree.build_dir(two.path)
      assert File.dir?(Worktree.build_dir(one.path))
      assert File.dir?(Worktree.build_dir(two.path))
    end

    test "an existing _build is never clobbered", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:ok, wt} = Worktree.add("m2-build-existing", repo: repo)
      marker = Path.join([wt.path, "_build", "worker-marker"])
      File.write!(marker, "built by the worker\n")

      # A re-add (a resume, a re-spawn) hands the same worktree back, and seeding is idempotent:
      # overwriting a worker's build directory would be a silent waste at best.
      assert {:ok, again} = Worktree.add("m2-build-existing", repo: repo)
      assert again.path == wt.path
      assert File.read!(marker) == "built by the worker\n"
    end

    @tag :capture_log
    test "a _build symlink is reported, never written through", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      other = GitRepo.init!(Path.join(dir, "other"))

      # Build the exact state #47 exists to prevent, the way it actually happens: the worker gets its
      # private `_build`, then replaces it with a link into a *different* checkout. A later `add/2`
      # (a re-spawn, a resume) must not quietly replace the worker's own choice with a directory, and
      # must never write through the link into the sibling's build directory.
      assert {:ok, wt} = Worktree.add("m2-build-symlink", repo: repo)
      assert {:ok, shared_wt} = Worktree.add("m2-build-shared-src", repo: other)

      shared_build = Worktree.build_dir(shared_wt.path)
      File.write!(Path.join(shared_build, "sibling-marker"), "the sibling's own build\n")
      before_entries = shared_build |> File.ls!() |> Enum.sort()

      File.rm_rf!(Worktree.build_dir(wt.path))
      assert :ok = File.ln_s(shared_build, Path.join(wt.path, "_build"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, again} = Worktree.add("m2-build-symlink", repo: repo)
          assert again.path == wt.path
        end)

      assert symlink?(Path.join(wt.path, "_build"))

      # Nothing was written *through* the link into the sibling's build directory: had the seed written
      # through the symlink it would have added/refreshed entries there, which is how a convenience
      # link silently becomes cross-checkout pollution.
      assert shared_build |> File.ls!() |> Enum.sort() == before_entries
      assert File.read!(Path.join(shared_build, "sibling-marker")) == "the sibling's own build\n"
      refute File.exists?(Path.join(shared_build, "dev"))
      # The warning names the one case where the isolation is genuinely not there, and the create still
      # succeeds: refusing a re-attach over a build directory would be worse than saying so.
      assert log =~ "no private _build"
      assert log =~ "_build"
    end

    @tag timeout: 120_000
    test "two workers building at the same time compile into separate _build directories (§#47)", %{
      tmp_dir: dir
    } do
      # The end-to-end case, run against real `mix`: two worktrees of one repository, compiled
      # *concurrently*, must not see each other's artefacts. This is the behaviour the whole issue is
      # about, and nothing short of actually building proves it — a shared `_build` is silent, so a
      # green suite in each directory would otherwise be indistinguishable from a corrupt one.
      repo = mix_project!(dir)

      assert {:ok, one} = Worktree.add("m2-build-par-a", repo: repo)
      assert {:ok, two} = Worktree.add("m2-build-par-b", repo: repo)

      # Both start from an empty tree: `git worktree add` carries no artefacts, which is exactly the
      # gap the seed closes.
      refute File.exists?(Path.join(one.path, "deps"))

      [a, b] =
        [
          Task.async(fn -> mix_compile!(one.path) end),
          Task.async(fn -> mix_compile!(two.path) end)
        ]
        |> Task.await_many(90_000)

      assert a == :ok
      assert b == :ok

      beam_a = Path.join([one.path, "_build", "dev", "lib", "build_probe", "ebin", "Elixir.BuildProbe.beam"])
      beam_b = Path.join([two.path, "_build", "dev", "lib", "build_probe", "ebin", "Elixir.BuildProbe.beam"])

      assert File.exists?(beam_a)
      assert File.exists?(beam_b)
      # Separate paths, and *not* hard links to one file: each worktree owns its own artefact.
      refute Path.expand(Path.dirname(beam_a)) == Path.expand(Path.dirname(beam_b))
      assert inode(beam_a) != inode(beam_b)

      # Neither build wrote into the source repository's tree — the property a shared
      # `MIX_BUILD_PATH` (or a `_build` symlink) breaks, since only one directory would exist at all.
      refute File.exists?(Path.join(repo, "_build"))

      # A real build leaves the worktrees clean (the seeded `.gitignore`), so `mix check` in one
      # worktree can never be tripped by the other's build, and removal needs no `--force`.
      assert Worktree.clean?(one.path)
      assert Worktree.clean?(two.path)

      assert :ok = Worktree.remove(one, repo: repo)
      assert :ok = Worktree.remove(two, repo: repo)
    end

    test "remove/2 refuses a dirty worktree, names the paths, and only --force discards them", %{
      tmp_dir: dir
    } do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      {:ok, wt} = Worktree.add("m2-remove", repo: repo)
      File.write!(Path.join(wt.path, "uncommitted.txt"), "wip\n")

      assert {:error, {:dirty_worktree, paths}} = Worktree.remove(wt, repo: repo)
      assert "uncommitted.txt" in paths

      # Nothing was destroyed: git refuses, and so does Athanor before it even asks git.
      assert File.exists?(Path.join(wt.path, "uncommitted.txt"))

      assert :ok = Worktree.remove(wt, repo: repo, force: true)
      refute File.exists?(wt.path)
    end

    test "remove/2 never targets the main working tree", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:error, :main_worktree} = Worktree.remove(repo, repo: repo)
      assert File.exists?(Path.join(repo, "README.md"))
    end

    test "remove/2 reports a path that is not a worktree of this repository", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      File.mkdir_p!(Path.join(dir, "elsewhere"))

      assert {:error, {:not_a_worktree, _path}} = Worktree.remove(Path.join(dir, "elsewhere"), repo: repo)
    end

    test "the branch policy is :keep by default and a *merged-only* delete on request", %{
      tmp_dir: dir
    } do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      # Default: the branch outlives the worktree.
      {:ok, kept} = Worktree.add("m2-keep", repo: repo)
      assert :ok = Worktree.remove(kept, repo: repo)
      assert branch_exists?(repo, "athanor/m2-keep")

      # :delete removes a branch whose work is already in HEAD...
      {:ok, merged} = Worktree.add("m2-del-merged", repo: repo)
      assert :ok = Worktree.remove(merged, repo: repo, branch: :delete)
      refute branch_exists?(repo, "athanor/m2-del-merged")

      # ...and refuses to remove one that carries unmerged work, because `-d` (never `-D`) is what
      # git is asked to do: unmerged work is never destroyed silently.
      {:ok, unmerged} = Worktree.add("m2-del-unmerged", repo: repo)
      GitRepo.commit!(unmerged.path, "wip.txt", "x\n", "unmerged worker work")

      assert {:error, {:branch_not_deleted, message}} =
               Worktree.remove(unmerged, repo: repo, branch: :delete)

      assert message =~ "not fully merged"
      assert branch_exists?(repo, "athanor/m2-del-unmerged")
      refute File.exists?(unmerged.path)
    end

    test "an unsafe session id is refused before anything is created", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))

      assert {:error, {:invalid_session_id, "../escape"}} = Worktree.add("../escape", repo: repo)
      refute File.exists?(Path.expand(Path.join(dir, "../escape")))
    end

    test "add/2 refuses a directory that is not a repository" do
      plain = outside_repo_dir!("not-a-repo")

      assert {:error, :not_a_git_repository} = Worktree.add("m2-norepo", repo: plain)
    end

    test "inside-repo placement is refused until the path is gitignored", %{tmp_dir: dir} do
      previous = System.get_env("ATHANOR_WORKTREE_INSIDE")

      try do
        System.put_env("ATHANOR_WORKTREE_INSIDE", "1")
        repo = GitRepo.init!(Path.join(dir, "repo"))

        # Nesting is permitted by git but not by Athanor: it would show as untracked in every
        # `git status` the parent runs (§0.2).
        assert {:error, :path_not_ignored} = Worktree.add("m2-inside", repo: repo)

        GitRepo.commit!(repo, ".gitignore", ".athanor/\n", "ignore athanor worktrees")

        assert {:ok, wt} = Worktree.add("m2-inside", repo: repo)
        assert wt.path == Path.join([Path.expand(repo), ".athanor", "worktrees", "m2-inside"])

        # And that is the point of the gate: the parent's status is still clean.
        assert Worktree.clean?(repo)
      after
        restore("ATHANOR_WORKTREE_INSIDE", previous)
      end
    end
  end

  # A git command is only meaningful where git can run at all.
  test "git is available for these tests" do
    assert GitRepo.available?(), "these tests require git on PATH"
    assert match?({:ok, _}, Git.run(["version"]))
  end

  # A directory that is genuinely outside any git repository. `:tmp_dir` cannot be used for the
  # "not a repository" cases because it is created inside the athanor checkout.
  defp outside_repo_dir!(label) do
    dir = Path.join(System.tmp_dir!(), "athanor-wt-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp branch_exists?(repo, branch) do
    match?({:ok, _}, Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"], cd: repo))
  end

  # A repository holding a minimal, dependency-free Mix project, so the concurrent-build test can
  # really compile without a network fetch or the athanor umbrella's own deps.
  defp mix_project!(dir) do
    repo = GitRepo.init!(Path.join(dir, "mix-repo"))

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule BuildProbe.MixProject do
      use Mix.Project

      def project, do: [app: :build_probe, version: "0.1.0", elixir: "~> 1.18"]
      def application, do: []
    end
    """)

    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(Path.join([repo, "lib", "build_probe.ex"]), """
    defmodule BuildProbe do
      @moduledoc "A tiny app the build-isolation tests compile."
      def ok, do: :ok
    end
    """)

    GitRepo.git!(repo, ["add", "."])
    GitRepo.git!(repo, ["commit", "-qm", "add mix project"])
    repo
  end

  # Runs a real `mix compile` in `dir` and returns `:ok` on a zero exit. Uses the same environment
  # isolation the fixtures use, so an outer MIX_BUILD_PATH/MIX_ENV cannot make the assertion vacuous
  # by pointing both worktrees at one directory — which is precisely the bug being tested for.
  defp mix_compile!(dir) do
    env = [
      {"MIX_ENV", "dev"},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil}
    ]

    case System.cmd("mix", ["compile"], cd: dir, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      {output, code} -> flunk("mix compile in #{dir} failed (#{code}):\n#{output}")
    end
  end

  # Inode identity, so "two separate artefacts" is a fact about the filesystem rather than about a
  # path string (a hard link or a bind mount would fool the path comparison).
  defp inode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{inode: inode}} -> inode
      {:error, reason} -> flunk("could not stat #{path}: #{inspect(reason)}")
    end
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
