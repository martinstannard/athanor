defmodule Athanor.ToolGuardTest do
  @moduledoc """
  Read-before-write enforcement (design §7.6, plan §4, §9.2).

  `async: false`: the read-set is one named ETS table and the disabled case mutates a
  process-wide env var, so these tests must not overlap with the async suite.
  """
  use ExUnit.Case, async: false

  alias Athanor.{Config, ToolGuard, Tools}

  @moduletag :tmp_dir

  # A fresh session per test, so the shared table cannot leak state between tests.
  defp sid, do: "guard-#{System.unique_integer([:positive])}"

  describe "ToolGuard keys" do
    test "mark_read/read?/snapshot/reset are per session" do
      a = sid()
      b = sid()

      :ok = ToolGuard.mark_read(a, "/tmp/x")
      assert ToolGuard.read?(a, "/tmp/x")
      refute ToolGuard.read?(b, "/tmp/x")
      assert ToolGuard.snapshot(a) == MapSet.new(["/tmp/x"])

      :ok = ToolGuard.reset(a)
      refute ToolGuard.read?(a, "/tmp/x")
      assert ToolGuard.snapshot(a) == MapSet.new()
    end

    test "a nil session is a no-op, never an error" do
      assert :ok = ToolGuard.mark_read(nil, "/tmp/x")
      refute ToolGuard.read?(nil, "/tmp/x")
      assert ToolGuard.snapshot(nil) == MapSet.new()
      assert :ok = ToolGuard.reset(nil)
    end

    test "refuse?/2 is true only for an existing, unread path in a known session", %{tmp_dir: dir} do
      existing = Path.join(dir, "exists.txt")
      File.write!(existing, "hi")
      missing = Path.join(dir, "nope.txt")
      session = sid()

      assert ToolGuard.refuse?(session, existing)
      refute ToolGuard.refuse?(session, missing)
      refute ToolGuard.refuse?(nil, existing)

      ToolGuard.mark_read(session, existing)
      refute ToolGuard.refuse?(session, existing)
    end
  end

  describe "Tools.execute enforcement" do
    test "creating a new file is always allowed", %{tmp_dir: dir} do
      session = sid()

      assert {:ok, _} =
               Tools.execute(
                 "write_file",
                 %{"path" => "new.txt", "content" => "hello"},
                 cd: dir,
                 session_id: session
               )

      assert File.read!(Path.join(dir, "new.txt")) == "hello"
    end

    test "writing an existing unread file is refused, and the file is untouched", %{tmp_dir: dir} do
      session = sid()
      path = Path.join(dir, "keep.txt")
      File.write!(path, "original")

      assert {:error, message} =
               Tools.execute(
                 "write_file",
                 %{"path" => "keep.txt", "content" => "clobbered"},
                 cd: dir,
                 session_id: session
               )

      assert message =~ "has not been read"
      # the invariant that matters: the bytes on disk are unchanged
      assert File.read!(path) == "original"
    end

    test "read then write is allowed", %{tmp_dir: dir} do
      session = sid()
      path = Path.join(dir, "doc.txt")
      File.write!(path, "original")

      assert {:ok, "original"} =
               Tools.execute("read_file", %{"path" => "doc.txt"}, cd: dir, session_id: session)

      assert {:ok, _} =
               Tools.execute(
                 "write_file",
                 %{"path" => "doc.txt", "content" => "updated"},
                 cd: dir,
                 session_id: session
               )

      assert File.read!(path) == "updated"
    end

    test "edit_file on an existing unread file is refused; after a read it works", %{tmp_dir: dir} do
      session = sid()
      path = Path.join(dir, "sample.ex")
      File.write!(path, "defmodule Foo do\n  def bar, do: :old\nend\n")

      assert {:error, message} =
               Tools.execute(
                 "edit_file",
                 %{"path" => "sample.ex", "old_string" => ":old", "new_string" => ":new"},
                 cd: dir,
                 session_id: session
               )

      assert message =~ "has not been read"
      assert File.read!(path) =~ ":old"

      asserted = Tools.execute("read_file", %{"path" => "sample.ex"}, cd: dir, session_id: session)
      assert {:ok, _content} = asserted

      assert {:ok, "Edited sample.ex successfully"} =
               Tools.execute(
                 "edit_file",
                 %{"path" => "sample.ex", "old_string" => ":old", "new_string" => ":new"},
                 cd: dir,
                 session_id: session
               )

      assert File.read!(path) =~ ":new"
    end

    test "a successful write marks the path as read (no second read needed)", %{tmp_dir: dir} do
      session = sid()
      Tools.execute("write_file", %{"path" => "new.txt", "content" => "v1"}, cd: dir, session_id: session)

      assert {:ok, _} =
               Tools.execute(
                 "edit_file",
                 %{"path" => "new.txt", "old_string" => "v1", "new_string" => "v2"},
                 cd: dir,
                 session_id: session
               )

      assert File.read!(Path.join(dir, "new.txt")) == "v2"
    end

    test "equivalent path spellings share one guard entry", %{tmp_dir: dir} do
      session = sid()
      File.write!(Path.join(dir, "a.txt"), "text")

      # read via a normalised spelling...
      assert {:ok, _} = Tools.execute("read_file", %{"path" => "a.txt"}, cd: dir, session_id: session)

      # ...then write via a path that resolves to the same file
      assert {:ok, _} =
               Tools.execute(
                 "write_file",
                 %{"path" => "./a.txt", "content" => "ok"},
                 cd: dir,
                 session_id: session
               )
    end

    test "the guard is a no-op without a session id", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "original")

      assert {:ok, _} =
               Tools.execute("write_file", %{"path" => "a.txt", "content" => "new"}, cd: dir)

      assert File.read!(Path.join(dir, "a.txt")) == "new"
    end

    test "ATHANOR_TOOL_GUARD=0 disables enforcement", %{tmp_dir: dir} do
      saved = System.get_env("ATHANOR_TOOL_GUARD")
      System.put_env("ATHANOR_TOOL_GUARD", "0")
      on_exit(fn -> restore("ATHANOR_TOOL_GUARD", saved) end)

      refute Config.tool_guard_enabled?()

      File.write!(Path.join(dir, "a.txt"), "original")

      assert {:ok, _} =
               Tools.execute(
                 "write_file",
                 %{"path" => "a.txt", "content" => "new"},
                 cd: dir,
                 session_id: sid()
               )

      assert File.read!(Path.join(dir, "a.txt")) == "new"
    end
  end

  describe "config knobs" do
    test "the guard defaults on, with both switches independent" do
      assert Config.tool_guard_enabled?()
      assert Config.prelude_read_required?()
    end

    test "ATHANOR_PRELUDE_READ=0 disables only the read rule" do
      saved = System.get_env("ATHANOR_PRELUDE_READ")
      System.put_env("ATHANOR_PRELUDE_READ", "0")
      on_exit(fn -> restore("ATHANOR_PRELUDE_READ", saved) end)

      assert Config.tool_guard_enabled?()
      refute Config.prelude_read_required?()
    end
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)
end
