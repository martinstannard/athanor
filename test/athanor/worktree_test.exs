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

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
