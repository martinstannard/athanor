defmodule Athanor.Tools do
  @moduledoc """
  Tool definitions (JSON Schemas) and local execution engine for Athanor Conductors
  and Sub-Agents.

  Includes:
  - Workspace tools (`read_file`, `write_file`, `edit_file`, `bash`) available to all sessions.
  - Orchestration tools (`launch_subagent`, `list_sessions`, `session_output`, `send_session`)
    available to `:conductor` sessions.
  """

  alias Athanor.{Bus, Orchestrator, SessionId}
  alias Athanor.Tools.{Glob, Grep}

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
      _ -> workspace_schemas()
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
                "description" =>
                  "Directory to search, relative to the session cd. Defaults to the session cd."
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
                "description" =>
                  "File or directory to search, relative to the session cd. Defaults to the session cd."
              },
              "glob" => %{
                "type" => "string",
                "description" =>
                  "Optional glob restricting which files are searched (e.g. \"**/*.ex\")."
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
          "description" =>
            "Send a follow-up message or prompt to an existing sub-agent or conductor over PubSub.",
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
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, exit_code}} ->
        {:error, "Command exited with status #{exit_code}:\n#{output}"}

      nil ->
        # Timed out: kill the subtree, then the task, so nothing outlives the call. Ordering
        # matters — reap the tree first (while `os_pid` is still valid), then shut the task.
        kill_tree(os_pid)
        _ = Task.shutdown(task, :brutal_kill)
        {:error, "Command timed out after #{timeout}ms"}

      {:exit, _reason} ->
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

    spawn_opts = [
      id: child_id,
      cd: cd,
      notify_parent_on_done: not wait?
    ]

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
        {:error, "Failed to launch sub-agent: #{inspect(reason)}"}
    end
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
             "send_session"
           ] do
    {:error, "Missing or invalid required arguments for tool #{tool_name}"}
  end

  def execute(unknown_tool, _args, _opts) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  defp edit_content(content, path, full_path, old_str, new_str) do
    parts = String.split(content, old_str)

    case length(parts) - 1 do
      0 ->
        {:error, "old_string not found in #{path}"}

      1 ->
        write_edit(full_path, Enum.join(parts, new_str), path)

      count ->
        {:error,
         "old_string matched #{count} locations in #{path}; include more context to make it unique"}
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
