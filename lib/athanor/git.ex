defmodule Athanor.Git do
  @moduledoc """
  The one place Athanor shells out to `git`.

  Everything in `Athanor.Worktree` goes through here, for four reasons:

    * **No shell.** `args` are handed to `System.cmd/3` directly, so a branch name containing
      `; rm -rf /` is an *argument*, not a command. (Contrast `Athanor.Tools`' `bash` tool.)
    * **Bounded.** Every call is capped by `Athanor.Config.worktree_git_timeout_ms/0`, so a wedged
      git cannot hang an agent — the same class of bug as the unbounded `:erpc` timeout in
      `docs/wedge-findings.md`.
    * **Structured.** Callers get an exit code rather than a string to parse, so "the command
      failed" and "the command ran and said no" are distinguishable without message sniffing.
    * **Isolated.** `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` are unset for every call (see
      `env/0`), so `opts[:cd]` decides the repository and nothing else can.

  A missing `git` binary is reported as `{:error, :git_not_available}` rather than raising, so a
  machine without git degrades instead of crashing.
  """

  alias Athanor.Config

  @type result :: %{output: String.t(), exit_code: non_neg_integer()}

  @doc """
  The environment overrides applied to every `git` invocation.

  These three variables *redirect* git at another repository: when any of them is inherited from
  the parent process, `git` ignores the working directory it is started in. This is not
  hypothetical — git exports `GIT_DIR` and `GIT_INDEX_FILE` to its own hooks, so an Athanor test
  suite (or agent tool) started from a pre-commit hook had its `git add`/`git commit` land on the
  hook's repository instead of the one it named. Unsetting them is what makes `opts[:cd]`
  authoritative. Exposed so test fixtures can apply the same isolation.

  Values are `nil`, which `System.cmd/3` treats as "unset".
  """
  @spec env() :: [{String.t(), nil}]
  def env do
    [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}, {"GIT_INDEX_FILE", nil}]
  end

  @doc """
  Runs `git` with `args` in `opts[:cd]` (default the current directory).

  Returns:

    * `{:ok, %{output: out, exit_code: 0}}` — succeeded
    * `{:error, %{output: out, exit_code: n}}` — ran, exited non-zero
    * `{:timeout, message}` — did not finish within `opts[:timeout]`
    * `{:error, :git_not_available}` — no `git` on `PATH`
  """
  @spec run([String.t()], keyword()) ::
          {:ok, result()} | {:error, result()} | {:timeout, String.t()} | {:error, term()}
  def run(args, opts \\ []) when is_list(args) do
    case System.find_executable("git") do
      nil -> {:error, :git_not_available}
      _path -> execute(args, opts)
    end
  end

  defp execute(args, opts) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, Config.worktree_git_timeout_ms())

    task = Task.async(fn -> System.cmd("git", args, cd: cd, stderr_to_stdout: true, env: env()) end)

    case Task.yield(task, timeout) do
      {:ok, {output, 0}} ->
        {:ok, %{output: output, exit_code: 0}}

      {:ok, {output, code}} ->
        {:error, %{output: output, exit_code: code}}

      {:exit, reason} ->
        {:error, {:git_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:timeout, timeout_message(args, timeout)}
    end
  end

  defp timeout_message(args, timeout) do
    "git #{Enum.join(args, " ")} timed out after #{timeout}ms"
  end
end
