defmodule Athanor.Tools do
  @moduledoc """
  Tool definitions (JSON Schemas) and local execution engine for Athanor agents.
  """

  @default_bash_timeout_ms 30_000

  @doc """
  Returns the OpenAI-compatible tool definitions sent to the LLM.
  """
  @spec schemas() :: [map()]
  def schemas do
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
      }
    ]
  end

  @doc """
  Executes a named tool with a map of string-keyed arguments (or a JSON-encoded string).
  Options:
  - `:cd` — base working directory for resolving relative paths and running bash commands (defaults to `File.cwd!()`).
  - `:timeout` — timeout in milliseconds for `bash` (defaults to `30_000`).
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
        parts = String.split(content, old_str)

        case length(parts) - 1 do
          0 ->
            {:error, "old_string not found in #{path}"}

          1 ->
            updated = Enum.join(parts, new_str)

            case File.write(full_path, updated) do
              :ok ->
                {:ok, "Edited #{path} successfully"}

              {:error, reason} ->
                {:error, "Failed to write #{path}: #{:file.format_error(reason)}"}
            end

          count ->
            {:error,
             "old_string matched #{count} locations in #{path}; include more context to make it unique"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def execute("bash", %{"command" => command}, opts) when is_binary(command) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, @default_bash_timeout_ms)

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], cd: cd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, exit_code}} ->
        {:error, "Command exited with status #{exit_code}:\n#{output}"}

      nil ->
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  def execute(tool_name, _args, _opts)
      when tool_name in ["read_file", "write_file", "edit_file", "bash"] do
    {:error, "Missing or invalid required arguments for tool #{tool_name}"}
  end

  def execute(unknown_tool, _args, _opts) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  defp resolve_path(path, opts) do
    base = Keyword.get(opts, :cd, File.cwd!())
    Path.expand(path, base)
  end
end
