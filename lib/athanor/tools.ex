defmodule Athanor.Tools do
  @moduledoc """
  Tool definitions (JSON Schemas) and local execution engine for Athanor Conductors
  and Sub-Agents.

  Includes:
  - Workspace tools (`read_file`, `write_file`, `edit_file`, `bash`) available to all sessions.
  - Orchestration tools (`launch_subagent`, `list_sessions`, `session_output`, `send_session`)
    available to `:conductor` sessions.
  """

  alias Athanor.{Bus, GoalManager, Orchestrator, SessionId}
  alias Athanor.Tools.{Glob, Grep}
  alias Athanor.Tools.Worktree, as: WorktreeTools

  @default_bash_timeout_ms 30_000
  @default_subagent_wait_timeout_ms 120_000

  @doc """
  Returns the OpenAI-compatible tool definitions sent to the LLM.
  Options:
  - `:role` — `:conductor` (includes orchestration tools) or `:worker` (workspace tools only).
    Defaults to `:worker` for backwards compatibility when called with no args.
  """
  @spec schemas(keyword()) :: [map()]
  def schemas(opts \\ []) do
    role = Keyword.get(opts, :role, :worker)

    case role do
      :conductor -> workspace_schemas() ++ conductor_schemas()
      # `report_progress` is worker-only: a conductor has no goal of its own to report against, so
      # offering it there is pure token cost (§7.2, plan §7).
      _worker -> workspace_schemas() ++ worker_schemas()
    end
  end

  defp workspace_schemas do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" => "Read the contents of a file at the given path.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative or absolute path to the file to read."
              }
            },
            "required" => ["path"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "write_file",
          "description" =>
            "Write content to a file at the given path, creating parent directories if needed and overwriting existing content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative or absolute path to the file to write."
              },
              "content" => %{
                "type" => "string",
                "description" => "Full content to write to the file."
              }
            },
            "required" => ["path", "content"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "edit_file",
          "description" =>
            "Replace an exact occurrence of old_string with new_string in a file. Fails if old_string is not found or occurs multiple times.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Relative or absolute path to the file to edit."
              },
              "old_string" => %{
                "type" => "string",
                "description" => "Exact text to find in the file."
              },
              "new_string" => %{
                "type" => "string",
                "description" => "Replacement text."
              }
            },
            "required" => ["path", "old_string", "new_string"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "bash",
          "description" => "Execute a bash command and return its combined stdout/stderr output.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "command" => %{
                "type" => "string",
                "description" => "The shell command to execute."
              }
            },
            "required" => ["command"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "glob",
          "description" =>
            "Find files by glob pattern (e.g. \"lib/**/*.ex\") under the session's working directory. " <>
              "Returns matching paths relative to the search root, one per line. Never spawns a shell and " <>
              "respects .gitignore and built-in ignores (.git, _build, deps, node_modules).",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "pattern" => %{
                "type" => "string",
                "description" => "Glob pattern (`*`, `?`, `**`, `{a,b}`), relative to `path`."
              },
              "path" => %{
                "type" => "string",
                "description" => "Directory to search, relative to the session cd. Defaults to the session cd."
              },
              "max_results" => %{
                "type" => "integer",
                "description" => "Maximum number of paths to return. Defaults to 200."
              }
            },
            "required" => ["pattern"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "grep",
          "description" =>
            "Search file contents with a regular expression and return matches as `path:line:content`. " <>
              "Never spawns a shell and respects .gitignore and built-in ignores.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "pattern" => %{
                "type" => "string",
                "description" => "Elixir-compatible (PCRE) regular expression."
              },
              "path" => %{
                "type" => "string",
                "description" => "File or directory to search, relative to the session cd. Defaults to the session cd."
              },
              "glob" => %{
                "type" => "string",
                "description" => "Optional glob restricting which files are searched (e.g. \"**/*.ex\")."
              },
              "ignore" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Additional glob patterns to skip."
              },
              "max_results" => %{
                "type" => "integer",
                "description" => "Maximum number of matching lines to return. Defaults to 200."
              }
            },
            "required" => ["pattern"]
          }
        }
      }
    ]
  end

  # Tools only a `role: :worker` session is told about. The goal tools (`set_goal`, `verify_goal`,
  # `goal_status`, `list_goals`) are conductor-only and live in their own group.
  defp worker_schemas do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "report_progress",
          "description" =>
            "Record progress on the verified goal this session is working to. Call it as you complete each bounded step so the goal's stall clock is reset; it does not close the goal — only independent verification can do that.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "One line describing what you just completed."
              },
              "step" => %{
                "type" => "string",
                "description" => "Optional short label for the step (e.g. \"3/7 tests\")."
              },
              "evidence" => %{
                "type" => "string",
                "description" => "Optional raw evidence: command output, a file path, a diff summary."
              }
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  defp conductor_schemas do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "launch_subagent",
          "description" =>
            "Spawn a supervised child sub-agent worker to execute a task in the background (or wait for its result if wait=true).",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{
                "type" => "string",
                "description" => "Short descriptive title for the sub-agent (e.g. 'Audit tests')."
              },
              "prompt" => %{
                "type" => "string",
                "description" => "Detailed task instructions for the sub-agent."
              },
              "wait" => %{
                "type" => "boolean",
                "description" =>
                  "If true, block until the sub-agent completes its turn and return its output. Defaults to false (fire-and-forget; parent is notified via PubSub when done)."
              },
              "worktree" => %{
                "type" => "boolean",
                "description" =>
                  "If true, the worker gets its own git worktree (its own checkout and branch) and works there, so parallel workers cannot fight over the same working directory. A string value means \"branch from that ref\". Refused when the repository has uncommitted changes: a worktree branches from committed HEAD, so the worker would not see them."
              },
              "base" => %{
                "type" => "string",
                "description" => "With worktree=true, the ref the worker's worktree branches from (default HEAD)."
              }
            },
            "required" => ["title", "prompt"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "list_sessions",
          "description" =>
            "List all active Conductors and Sub-Agents with their IDs, titles, roles, parent IDs, and status.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{}
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "session_output",
          "description" => "Get the current status and latest output from a session by ID.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "session_id" => %{
                "type" => "string",
                "description" => "ID of the sub-agent or conductor session."
              }
            },
            "required" => ["session_id"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "send_session",
          "description" => "Send a follow-up message or prompt to an existing sub-agent or conductor over PubSub.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "session_id" => %{
                "type" => "string",
                "description" => "Target session ID."
              },
              "message" => %{
                "type" => "string",
                "description" => "Message to enqueue/send to the session."
              }
            },
            "required" => ["session_id", "message"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_worktree",
          "description" =>
            "Create an isolated git worktree (its own checkout and branch) and return its path. Use this to pin a session to a stable base, or to prepare a checkout you will hand to a sub-agent. Refuses to run when the repository has uncommitted changes, because a worktree branches from committed HEAD and a worker would not see them; pass allow_dirty=true to proceed anyway.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "session_id" => %{
                "type" => "string",
                "description" => "Session to assign the worktree to. Defaults to the calling session."
              },
              "branch" => %{
                "type" => "boolean",
                "description" =>
                  "true (default) puts the worktree on its own branch; false gives it a detached HEAD, for throwaway verification work."
              },
              "base" => %{
                "type" => "string",
                "description" => "Ref to branch from (default HEAD). Use it to pin a worker to a known-good commit."
              },
              "allow_dirty" => %{
                "type" => "boolean",
                "description" =>
                  "Proceed even though the source repository has uncommitted changes. The result names the commit it branched from."
              }
            },
            "required" => []
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "list_worktrees",
          "description" =>
            "List every git worktree of the current repository: path, branch (or detached), and the owning session when one is known.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{}
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "remove_worktree",
          "description" =>
            "Remove a worktree, by session_id or path. Refuses to destroy a worktree with uncommitted files unless force=true; the branch is kept unless branch=\"delete\", which uses git's safe delete and so also refuses unmerged work.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "session_id" => %{
                "type" => "string",
                "description" => "Session whose worktree should be removed."
              },
              "path" => %{
                "type" => "string",
                "description" => "Path of the worktree to remove, for one no session owns."
              },
              "force" => %{
                "type" => "boolean",
                "description" => "Discard modified and untracked files inside the worktree. Defaults to false."
              },
              "branch" => %{
                "type" => "string",
                "enum" => ["keep", "delete"],
                "description" =>
                  "\"keep\" (default) leaves the branch; \"delete\" removes it with git branch -d, which refuses unmerged work."
              }
            },
            "required" => []
          }
        }
      }
    ]
  end

  @doc """
  Executes a named tool with a map of string-keyed arguments (or a JSON-encoded string).
  """
  @spec execute(String.t(), map() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(tool_name, raw_args, opts \\ [])

  def execute(tool_name, raw_args, opts) when is_binary(raw_args) do
    case JSON.decode(raw_args) do
      {:ok, decoded} when is_map(decoded) ->
        execute(tool_name, decoded, opts)

      {:ok, _other} ->
        {:error, "Invalid tool arguments: expected a JSON object"}

      {:error, reason} ->
        {:error, "Failed to decode tool JSON arguments: #{inspect(reason)}"}
    end
  end

  def execute("read_file", %{"path" => path}, opts) when is_binary(path) do
    full_path = resolve_path(path, opts)

    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def execute("write_file", %{"path" => path, "content" => content}, opts)
      when is_binary(path) and is_binary(content) do
    full_path = resolve_path(path, opts)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} -> {:error, "Failed to write #{path}: #{:file.format_error(reason)}"}
    end
  end

  def execute(
        "edit_file",
        %{"path" => path, "old_string" => old_str, "new_string" => new_str},
        opts
      )
      when is_binary(path) and is_binary(old_str) and is_binary(new_str) do
    full_path = resolve_path(path, opts)

    case File.read(full_path) do
      {:ok, content} ->
        edit_content(content, path, full_path, old_str, new_str)

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def execute("bash", %{"command" => command}, opts) when is_binary(command) do
    # A thin adapter over `run_command/2` (plan C9). The two error strings below are part of the
    # model-facing contract — a model reads them to decide what to do next — so they stay exactly as
    # they were; the structured runner exists for callers that must tell a timeout from a non-zero
    # exit, which sniffing these strings could not do safely.
    case run_command(command, opts) do
      {:ok, %{output: output, exit_code: 0}} ->
        {:ok, output}

      {:ok, %{output: output, exit_code: exit_code}} ->
        {:error, "Command exited with status #{exit_code}:\n#{output}"}

      {:timeout, message} ->
        {:error, message}

      {:error, _reason} ->
        {:error, "Command execution crashed"}
    end
  end

  def execute("glob", args, opts) when is_map(args), do: Glob.run(args, opts)
  def execute("grep", args, opts) when is_map(args), do: Grep.run(args, opts)

  def execute("launch_subagent", %{"title" => title, "prompt" => prompt} = args, opts)
      when is_binary(title) and is_binary(prompt) do
    parent_id = Keyword.get(opts, :session_id, "conductor-main")
    cd = Keyword.get(opts, :cd, File.cwd!())
    wait? = Map.get(args, "wait", false) == true
    wait_timeout = Keyword.get(opts, :wait_timeout, @default_subagent_wait_timeout_ms)

    # Generated here (rather than left to the Orchestrator) so a `wait: true` caller can
    # subscribe to the child's events *before* it starts. Uses the shared generator so the
    # id is unique by construction and safe as a future path/branch component.
    child_id = SessionId.generate("worker")

    if wait? do
      Bus.subscribe("agent:#{child_id}:events")
    end

    spawn_opts =
      [id: child_id, notify_parent_on_done: not wait?] |> cd_or_worktree(args, cd)

    case Orchestrator.launch_subagent(parent_id, title, prompt, spawn_opts) do
      {:ok, ^child_id, _pid} ->
        if wait? do
          result = await_subagent(child_id, wait_timeout)
          Bus.unsubscribe("agent:#{child_id}:events")
          result
        else
          {:ok,
           "Spawned sub-agent '#{title}' with session_id=#{child_id} (running in background; you will receive a [DONE] notification when it finishes)."}
        end

      {:error, reason} ->
        if wait?, do: Bus.unsubscribe("agent:#{child_id}:events")
        {:error, "Failed to launch sub-agent: #{describe_launch_error(reason)}"}
    end
  end

  def execute("report_progress", %{"summary" => summary} = args, opts)
      when is_binary(summary) and summary != "" do
    # The goal is found from the *calling session*, not from an argument: a worker cannot file
    # progress against somebody else's goal, and the session id is what the tool opts already carry.
    case Keyword.get(opts, :session_id) do
      worker_id when is_binary(worker_id) ->
        report_progress(worker_id, summary, args)

      _no_session ->
        {:error, "report_progress needs the calling session id"}
    end
  end

  def execute("create_worktree", args, opts) when is_map(args) do
    with :ok <- conductor_only(opts, "create_worktree"), do: WorktreeTools.create(args, opts)
  end

  def execute("list_worktrees", args, opts) when is_map(args) do
    with :ok <- conductor_only(opts, "list_worktrees"), do: WorktreeTools.list(args, opts)
  end

  def execute("remove_worktree", args, opts) when is_map(args) do
    with :ok <- conductor_only(opts, "remove_worktree"), do: WorktreeTools.remove(args, opts)
  end

  def execute("list_sessions", _args, _opts) do
    sessions =
      Orchestrator.list_sessions()
      |> Enum.map(fn s ->
        %{
          id: s.id,
          title: s.title,
          role: s.role,
          parent_id: s.parent_id,
          status: s.status,
          last_assistant: String.slice(s.last_assistant, 0, 120)
        }
      end)

    {:ok, JSON.encode!(sessions)}
  end

  def execute("session_output", %{"session_id" => session_id}, _opts)
      when is_binary(session_id) do
    case Orchestrator.session_output(session_id) do
      {:ok, info} ->
        payload = %{
          id: info.id,
          title: info.title,
          role: info.role,
          parent_id: info.parent_id,
          status: info.status,
          last_assistant: info.last_assistant
        }

        {:ok, JSON.encode!(payload)}

      {:error, :not_found} ->
        {:error, "Session not found: #{session_id}"}
    end
  end

  def execute("send_session", %{"session_id" => session_id, "message" => message}, _opts)
      when is_binary(session_id) and is_binary(message) do
    case Orchestrator.send_session(session_id, message) do
      :ok -> {:ok, "Sent message to session #{session_id} via PubSub"}
      {:error, :not_found} -> {:error, "Session not found: #{session_id}"}
    end
  end

  def execute(tool_name, _args, _opts)
      when tool_name in [
             "read_file",
             "write_file",
             "edit_file",
             "bash",
             "glob",
             "grep",
             "launch_subagent",
             "list_sessions",
             "session_output",
             "send_session",
             "create_worktree",
             "list_worktrees",
             "remove_worktree",
             "report_progress"
           ] do
    {:error, "Missing or invalid required arguments for tool #{tool_name}"}
  end

  def execute(unknown_tool, _args, _opts) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  # Worktree management is a conductor's job: a worker has no business making more worktrees. It is
  # not told these tools exist (the schemas are role-gated), and it is refused by name if it asks
  # anyway — the wording matches the catch-all below, so schema gating and dispatch agree.
  @doc """
  Runs a shell command and reports **what happened**, structurally.

  Returns `{:ok, %{output: output, exit_code: code}}` when the command ran to completion — *including*
  a non-zero exit, which is a fact about the work rather than a failure of this function — plus
  `{:timeout, message}` when it did not finish within `opts[:timeout]`, and `{:error, reason}` when
  the runner itself failed.

  That distinction is the point: `Athanor.Verifier` must be able to separate "the check ran and said
  no" (`:contradicted`) from "we could not tell" (`:inconclusive`), and the model-facing `bash`
  tool's error strings cannot carry it (plan C9, OQ9).

  Bounding and reaping are the `bash` tool's, unchanged: `opts[:timeout]` (default
  `#{@default_bash_timeout_ms}` ms) covers the whole call, and a timeout kills the child's whole
  process group, not just its port.
  """
  @spec run_command(String.t(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: integer()}}
          | {:timeout, String.t()}
          | {:error, term()}
  def run_command(command, opts \\ []) when is_binary(command) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, @default_bash_timeout_ms)
    caller = self()

    task = Task.async(fn -> run_bash(command, cd, caller) end)

    # The task reports its port's `os_pid` as soon as the process is up, so a timeout can reap
    # the child's whole process group rather than just closing the port. `setsid --wait` makes
    # the port's `os_pid` the group leader, so `kill -TERM -<os_pid>` reaches grandchildren too.
    os_pid =
      receive do
        {:athanor_bash_os_pid, task_pid, pid} when task_pid == task.pid -> pid
      after
        2_000 -> nil
      end

    case Task.yield(task, timeout) do
      {:ok, {output, exit_code}} ->
        {:ok, %{output: output, exit_code: exit_code}}

      nil ->
        # Timed out: kill the subtree, then the task, so nothing outlives the call. Ordering
        # matters — reap the tree first (while `os_pid` is still valid), then shut the task.
        kill_tree(os_pid)
        _ = Task.shutdown(task, :brutal_kill)
        {:timeout, "Command timed out after #{timeout}ms"}

      {:exit, reason} ->
        {:error, {:bash_crashed, reason}}
    end
  end

  defp report_progress(worker_id, summary, args) do
    case GoalManager.report_progress(
           worker_id,
           summary: summary,
           step: args["step"],
           evidence: args["evidence"]
         ) do
      :ok ->
        {:ok, "Progress recorded. It does not close the goal — independent verification decides that."}

      {:error, :not_found} ->
        {:error, "this session has no goal attached, so there is no progress to report"}
    end
  end

  defp conductor_only(opts, tool_name) do
    case Keyword.get(opts, :role, :conductor) do
      :conductor -> :ok
      _other -> {:error, "Unknown tool: #{tool_name}"}
    end
  end

  # An isolated worker's directory is decided by its worktree, so `:cd` must *not* travel with
  # `:worktree` — `Orchestrator.launch_subagent/4` refuses that contradictory pair rather than
  # silently preferring one. `worktree: "ref"` means "branch from that ref".
  defp cd_or_worktree(spawn_opts, %{"worktree" => worktree} = args, _cd)
       when is_binary(worktree) or worktree == true do
    Keyword.put(spawn_opts, :worktree, worktree_settings(args, worktree))
  end

  defp cd_or_worktree(spawn_opts, _args, cd), do: Keyword.put(spawn_opts, :cd, cd)

  defp worktree_settings(_args, ref) when is_binary(ref), do: [base: ref]
  defp worktree_settings(args, _true), do: [base: args["base"] || "HEAD"]

  # The dirty-source refusal is the one a model is most likely to hit, and "inspect(reason)" would
  # not tell it what to do about it.
  defp describe_launch_error({:dirty_worktree_source, summary}) do
    "the repository has uncommitted changes (#{summary}), so an isolated worker would not see " <>
      "them. Commit or stash first, then spawn the worker again."
  end

  defp describe_launch_error(reason), do: inspect(reason)

  defp edit_content(content, path, full_path, old_str, new_str) do
    parts = String.split(content, old_str)

    case length(parts) - 1 do
      0 ->
        {:error, "old_string not found in #{path}"}

      1 ->
        write_edit(full_path, Enum.join(parts, new_str), path)

      count ->
        {:error, "old_string matched #{count} locations in #{path}; include more context to make it unique"}
    end
  end

  defp write_edit(full_path, updated, path) do
    case File.write(full_path, updated) do
      :ok -> {:ok, "Edited #{path} successfully"}
      {:error, reason} -> {:error, "Failed to write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Runs `bash -c command` in a port that reports its OS pid to `caller` immediately, so a
  # timeout can reap the child *and everything it spawned*. Output is collected with a plain
  # port receive and `:exit_status` is requested so the caller sees the exit code.
  #
  # Why a plain `bash`, not `setsid`: a wrapper (`setsid`, with or without `--wait`) forks, so
  # the port's `os_pid` is the wrapper rather than the new process-group leader, and a group
  # kill against `-os_pid` misses (verified: `kill: sending signal to -<pid> failed`). The
  # robust primitive is instead to walk the process *tree* from the reported pid and kill the
  # descendants bottom-up (`kill_tree/1`), which reaps a `bash -c` that backgrounded children
  # just as well as one that `exec`'d a single process (the confirmed leak).
  defp run_bash(command, cd, caller) do
    bash = System.find_executable("bash") || "bash"

    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-c", command],
        cd: cd
      ])

    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      send(caller, {:athanor_bash_os_pid, self(), os_pid})
    end

    collect_bash_output(port, [])
  end

  defp collect_bash_output(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_bash_output(port, [acc, data])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    end
  end

  # Best-effort subtree reap on timeout: TERM the whole subtree (polite), then KILL whatever
  # survived, so neither a backgrounded child nor a TERM-ignoring process outlives the call.
  # Nothing here may raise — the caller is already on the timeout path, and a reaping failure
  # must never turn into a tool crash.
  defp kill_tree(nil), do: :ok

  defp kill_tree(os_pid) when is_integer(os_pid) do
    descendants = descendants(os_pid)
    targets = [os_pid | descendants]

    signal_tree(targets, "TERM")
    Process.sleep(50)
    signal_tree(targets, "KILL")
    Athanor.Log.wedge(:bash_kill, os_pid: os_pid, descendants: length(descendants))
    :ok
  rescue
    _error -> :ok
  end

  # Depth-first descendant pids of `pid`, collected *before* any signal is sent: once the parent
  # dies its children reparent to init and the link is lost, so the walk must come first.
  defp descendants(pid) do
    Enum.flat_map(child_pids(pid), fn child -> [child | descendants(child)] end)
  end

  defp child_pids(pid) do
    case System.cmd("pgrep", ["-P", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> Enum.reject(&(&1 == ""))
      _other -> []
    end
  rescue
    _error -> []
  end

  defp signal_tree(pids, signal) do
    Enum.each(pids, fn pid ->
      _ = System.cmd("kill", ["-#{signal}", to_string(pid)], stderr_to_stdout: true)
    end)

    :ok
  end

  defp await_subagent(child_id, timeout) do
    receive do
      {:agent_event, ^child_id, {:turn_complete, output}} ->
        {:ok, output}

      {:agent_event, ^child_id, {:error, reason}} ->
        {:error, "Sub-agent #{child_id} failed: #{reason}"}
    after
      timeout ->
        {:error, "Timed out waiting for sub-agent #{child_id} after #{timeout}ms"}
    end
  end

  @doc """
  Resolves `path` against the session's working directory (`opts[:cd]`, defaulting to the
  current directory). Shared by the file and search tools so every tool roots itself the same way.
  """
  @spec resolve_path(String.t(), keyword()) :: String.t()
  def resolve_path(path, opts \\ []) do
    base = Keyword.get(opts, :cd, File.cwd!())
    Path.expand(path, base)
  end
end
