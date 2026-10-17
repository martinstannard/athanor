defmodule Athanor.ToolsTest do
  use ExUnit.Case, async: true

  alias Athanor.Memory.Store
  alias Athanor.Tools

  @moduletag :tmp_dir

  defp names(role) do
    Tools.schemas(role: role)
    |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)
  end

  describe "schemas/0 and schemas/1" do
    test "returns the workspace tool schemas by default" do
      names =
        Tools.schemas()
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      assert names == [
               "read_file",
               "write_file",
               "edit_file",
               "bash",
               "glob",
               "grep",
               "report_progress",
               "remember",
               "recall",
               "forget"
             ]
    end

    test "includes conductor orchestration tools when role: :conductor" do
      names =
        Tools.schemas(role: :conductor)
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      assert "launch_subagent" in names
      assert "list_sessions" in names
      assert "session_output" in names
      assert "send_session" in names
      assert "create_worktree" in names
      assert "list_worktrees" in names
      assert "remove_worktree" in names
      # workspace tools are still present for conductors
      assert "glob" in names
      assert "grep" in names
    end

    test "report_progress is advertised to a worker and not to a conductor" do
      worker_names =
        Tools.schemas(role: :worker)
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      assert "report_progress" in worker_names

      # A conductor owns goals; it has no goal of its own to report progress against.
      conductor_names =
        Tools.schemas(role: :conductor)
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      refute "report_progress" in conductor_names
    end

    test "worktree management is not advertised to a worker" do
      names =
        Tools.schemas(role: :worker)
        |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

      refute "create_worktree" in names
      refute "list_worktrees" in names
      refute "remove_worktree" in names
    end
  end

  describe "write_file and read_file" do
    test "writes a file (creating parent dirs) and reads it back", %{tmp_dir: tmp_dir} do
      assert {:ok, msg} =
               Tools.execute(
                 "write_file",
                 %{"path" => "nested/hello.txt", "content" => "hello elixir\n"},
                 cd: tmp_dir
               )

      assert msg =~ "Wrote 13 bytes"

      assert {:ok, "hello elixir\n"} =
               Tools.execute("read_file", %{"path" => "nested/hello.txt"}, cd: tmp_dir)
    end

    test "returns an error when reading a non-existent file", %{tmp_dir: tmp_dir} do
      assert {:error, reason} =
               Tools.execute("read_file", %{"path" => "missing.txt"}, cd: tmp_dir)

      assert reason =~ "Failed to read missing.txt"
    end
  end

  describe "edit_file" do
    test "replaces a unique occurrence of old_string", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sample.ex"), "defmodule Foo do\n  def bar, do: :old\nend\n")

      assert {:ok, "Edited sample.ex successfully"} =
               Tools.execute(
                 "edit_file",
                 %{
                   "path" => "sample.ex",
                   "old_string" => "def bar, do: :old",
                   "new_string" => "def bar, do: :new"
                 },
                 cd: tmp_dir
               )

      assert File.read!(Path.join(tmp_dir, "sample.ex")) ==
               "defmodule Foo do\n  def bar, do: :new\nend\n"
    end

    test "returns an error when old_string is not found", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sample.ex"), "hello world\n")

      assert {:error, "old_string not found in sample.ex"} =
               Tools.execute(
                 "edit_file",
                 %{
                   "path" => "sample.ex",
                   "old_string" => "missing",
                   "new_string" => "replacement"
                 },
                 cd: tmp_dir
               )
    end

    test "returns an error when old_string matches multiple times", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sample.ex"), "dup\ndup\n")

      assert {:error, msg} =
               Tools.execute(
                 "edit_file",
                 %{"path" => "sample.ex", "old_string" => "dup", "new_string" => "once"},
                 cd: tmp_dir
               )

      assert msg =~ "matched 2 locations"
    end
  end

  describe "bash" do
    test "executes a shell command in the target directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "marker.txt"), "found_me")

      assert {:ok, output} =
               Tools.execute("bash", %{"command" => "cat marker.txt"}, cd: tmp_dir)

      assert output == "found_me"
    end

    test "returns error tuple on non-zero exit code", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               Tools.execute("bash", %{"command" => "echo 'boom' >&2; exit 7"}, cd: tmp_dir)

      assert msg =~ "exited with status 7"
      assert msg =~ "boom"
    end

    test "enforces command timeout", %{tmp_dir: tmp_dir} do
      assert {:error, "Command timed out after 50ms"} =
               Tools.execute("bash", %{"command" => "sleep 2"}, cd: tmp_dir, timeout: 50)
    end

    # Regression for the confirmed OS-process leak (docs/wedge-findings.md): a timed-out command
    # used to leave its child running. The fix reaps the child's whole subtree from the port's
    # os_pid, so neither an `exec`'d process nor a backgrounded child survives.
    test "reaps the child process tree on timeout", %{tmp_dir: tmp_dir} do
      marker = "athanor_tools_test_#{System.unique_integer([:positive])}"

      assert {:error, msg} =
               Tools.execute("bash", %{"command" => "exec sleep 30 # #{marker}"},
                 cd: tmp_dir,
                 timeout: 300
               )

      assert msg =~ "timed out"

      # Give the reap a moment to be observable.
      wait_until(fn -> living(marker) == [] end, 40)
      assert living(marker) == []
    end

    test "reaps backgrounded grandchildren on timeout", %{tmp_dir: tmp_dir} do
      marker = "athanor_tools_test_bg_#{System.unique_integer([:positive])}"

      assert {:error, _msg} =
               Tools.execute(
                 "bash",
                 %{"command" => "sleep 30 & sleep 30; # #{marker}"},
                 cd: tmp_dir,
                 timeout: 300
               )

      wait_until(fn -> living(marker) == [] end, 40)
      assert living(marker) == []
    end
  end

  defp living(marker) do
    case System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  describe "JSON string arguments and unknown tools" do
    test "accepts JSON-encoded arguments string", %{tmp_dir: tmp_dir} do
      json = JSON.encode!(%{"path" => "from_json.txt", "content" => "ok"})

      assert {:ok, _} = Tools.execute("write_file", json, cd: tmp_dir)
      assert File.read!(Path.join(tmp_dir, "from_json.txt")) == "ok"
    end

    test "returns error for unknown tool" do
      assert {:error, "Unknown tool: magic_wand"} = Tools.execute("magic_wand", %{})
    end
  end

  describe "memory tools (§7.5 M3)" do
    test "both roles get remember/recall/forget (D2 regression)" do
      for role <- [:worker, :conductor] do
        assert "remember" in names(role)
        assert "recall" in names(role)
        assert "forget" in names(role)
      end
    end

    test "remember writes a learning with the session as its source", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".athanor"))

      assert {:ok, message} =
               Tools.execute(
                 "remember",
                 %{"category" => "gotcha", "fact" => "mix test needs ATHANOR_* env"},
                 cd: tmp_dir,
                 session_id: "s1"
               )

      assert message =~ "Remembered"

      [entry] = Store.read_learnings(Path.join(tmp_dir, ".athanor"))
      assert entry.text == "mix test needs ATHANOR_* env"
      assert entry.source["session_id"] == "s1"
    end

    test "recall finds what remember wrote, and forget removes it", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".athanor"))
      opts = [cd: tmp_dir, session_id: "s1"]

      {:ok, _} =
        Tools.execute("remember", %{"category" => "fact", "fact" => "worktrees share memory"}, opts)

      {:ok, found} = Tools.execute("recall", %{"query" => "worktrees"}, opts)
      assert found =~ "worktrees share memory"

      [entry] = Store.read_learnings(Path.join(tmp_dir, ".athanor"))
      assert {:ok, _} = Tools.execute("forget", %{"id" => entry.id}, opts)

      {:ok, after_forget} = Tools.execute("recall", %{"query" => "worktrees"}, opts)
      assert after_forget == "No matching learnings."
    end

    test "a curated category also lands in MEMORY.md", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".athanor"))
      opts = [cd: tmp_dir, session_id: "s1"]

      {:ok, _} =
        Tools.execute("remember", %{"category" => "gotcha", "fact" => "A durable gotcha"}, opts)

      memory = Store.read_memory(Path.join(tmp_dir, ".athanor"))
      assert memory =~ "## Gotchas"
      assert memory =~ "- A durable gotcha"
    end

    test "remember with a missing fact falls through to the argument error", %{tmp_dir: tmp_dir} do
      assert {:error, message} =
               Tools.execute("remember", %{"category" => "fact"}, cd: tmp_dir, session_id: "s1")

      assert message =~ "Missing or invalid required arguments"
    end

    test "a global learning cannot be forgotten by a tool (OQ5)", %{tmp_dir: tmp_dir} do
      global = Path.join(tmp_dir, "global")
      opts = [cd: tmp_dir, session_id: "s1", global_dir: global]

      {:ok, _} =
        Tools.execute(
          "remember",
          %{"category" => "preference", "fact" => "Prefer rebase", "scope" => "global"},
          opts
        )

      [entry] = Store.read_learnings(global)
      assert {:error, message} = Tools.execute("forget", %{"id" => entry.id}, opts)
      assert message =~ "only be forgotten by the user"
    end
  end
end
