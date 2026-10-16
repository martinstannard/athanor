defmodule Athanor.GitTest do
  # async: false — one test empties PATH to prove the missing-binary degradation, which is global.
  use ExUnit.Case, async: false

  alias Athanor.{Git, GitRepo}

  @moduletag :tmp_dir

  describe "run/2" do
    test "returns the output and exit code 0 on success", %{tmp_dir: dir} do
      GitRepo.init!(dir)

      assert {:ok, %{output: output, exit_code: 0}} = Git.run(["rev-parse", "--is-inside-work-tree"], cd: dir)
      assert String.trim(output) == "true"
    end

    test "reports a non-zero exit with its output rather than raising", %{tmp_dir: dir} do
      GitRepo.init!(dir)

      # `rev-parse` on an unknown revision exits non-zero; git's own message is captured because
      # stderr is folded into stdout.
      assert {:error, %{exit_code: code, output: output}} = Git.run(["rev-parse", "no-such-ref"], cd: dir)
      refute code == 0
      assert output =~ "no-such-ref"
    end

    test "bounds a command that would otherwise hang", %{tmp_dir: dir} do
      GitRepo.init!(dir)

      # `git hash-object --stdin` blocks on stdin forever in this context: a stand-in for a wedged
      # git. The timeout is what keeps an agent from hanging on it.
      assert {:timeout, message} = Git.run(["hash-object", "--stdin"], cd: dir, timeout: 150)
      assert message =~ "timed out after 150ms"
    end

    test "degrades instead of raising when git is not installed" do
      previous = System.get_env("PATH")

      try do
        System.put_env("PATH", "")

        assert {:error, :git_not_available} = Git.run(["status"])
      after
        restore("PATH", previous)
      end
    end

    test "ignores an inherited GIT_DIR and operates on the directory it was given", %{tmp_dir: dir} do
      repo = GitRepo.init!(Path.join(dir, "repo"))
      decoy = GitRepo.init!(Path.join(dir, "decoy"))

      previous_dir = System.get_env("GIT_DIR")
      previous_index = System.get_env("GIT_INDEX_FILE")

      try do
        # A parent process can redirect git this way — git itself exports both variables to its own
        # hooks. Regression: `cd:` used to be ignored, so a commit meant for one repository landed
        # on another.
        System.put_env("GIT_DIR", Path.join(decoy, ".git"))
        System.put_env("GIT_INDEX_FILE", Path.join(decoy, ".git/index"))

        assert {:ok, %{output: output}} = Git.run(["rev-parse", "--show-toplevel"], cd: repo)
        assert String.trim(output) == Path.expand(repo)
      after
        restore("GIT_DIR", previous_dir)
        restore("GIT_INDEX_FILE", previous_index)
      end
    end
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
