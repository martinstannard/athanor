defmodule Athanor.GitRepo do
  @moduledoc """
  A real git repository fixture for the worktree tests.

  The worktree feature is *defined* by git's behaviour — worktrees branch from committed `HEAD`,
  `git worktree add` refuses a branch that already exists, and `git worktree remove` refuses a dirty
  tree — so these tests drive git itself rather than a fake. A fake would only assert our beliefs
  about git, which is exactly what goes wrong.

  Requires `git` on `PATH`; `available?/0` lets a test skip when it is absent.
  """

  @doc "True when a usable `git` is on `PATH`."
  @spec available?() :: boolean()
  def available?, do: System.find_executable("git") != nil

  @doc """
  Creates a repository at `dir` with `main` checked out and one commit, and returns `dir`.

  Committer identity is configured per-repository so the fixture never depends on (or touches) the
  machine's global git config.
  """
  @spec init!(String.t()) :: String.t()
  def init!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])

    # Guard, and it matters: a `git commit` in a directory that is *not* its own repository walks up
    # and commits into the enclosing one. A fixture commit was observed landing on the athanor
    # branch that way, and it looked like a stray commit with an empty tree. Assert the repository
    # is the one at `dir`, so if that ever happens again it is a loud failure here instead of a
    # silent commit somewhere else.
    toplevel = git!(dir, ["rev-parse", "--show-toplevel"]) |> String.trim()

    unless Path.expand(toplevel) == Path.expand(dir) do
      raise "#{dir} is not its own git repository (resolved to #{toplevel}); " <>
              "a commit here would land in the enclosing repository"
    end

    git!(dir, ["config", "user.email", "athanor-test@example.com"])
    git!(dir, ["config", "user.name", "Athanor Test"])
    commit!(dir, "README.md", "hello\n", "initial commit")
    dir
  end

  @doc "Writes `content` to `path` under `dir` and commits it."
  @spec commit!(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def commit!(dir, path, content, message) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-qm", message])
    dir
  end

  @doc "Runs git in `dir`, raising on a non-zero exit so a fixture failure is never silent."
  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(dir, args) do
    # The same isolation production uses (`Athanor.Git.env/0`): if a redirection variable were set
    # in the environment, every fixture command would operate on that repository instead of the
    # fixture's — which is how a stray commit escaped into the parent repo.
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: Athanor.Git.env()) do
      {output, 0} ->
        output

      {output, code} ->
        raise "git #{Enum.join(args, " ")} failed (#{code}) in #{dir}:\n#{output}"
    end
  end
end
