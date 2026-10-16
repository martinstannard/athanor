defmodule Athanor.ProjectContextTest do
  use ExUnit.Case, async: true

  alias Athanor.ProjectContext

  @moduletag :tmp_dir

  describe "load/2" do
    test "finds the nearest AGENTS.md above the working directory", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      File.write!(Path.join(repo, "AGENTS.md"), "Always use tabs.\n")
      workdir = Path.join(repo, "lib/nested")
      File.mkdir_p!(workdir)

      assert {:ok, body} = ProjectContext.load(workdir)
      assert body =~ "Always use tabs."
    end

    test "a nested AGENTS.md wins over the repo-root one", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "root instructions")
      nested = Path.join(tmp_dir, "lib/nested")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "AGENTS.md"), "nested instructions")

      assert {:ok, "nested instructions"} = ProjectContext.load(nested)
    end

    test "returns :none when there is no AGENTS.md before the .git boundary", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      workdir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(workdir)

      assert :none = ProjectContext.load(workdir)
    end

    test "stops at the .git boundary and ignores an AGENTS.md above it", %{tmp_dir: tmp_dir} do
      # The outer tmp_dir looks like a repo with instructions, but the inner checkout is its own
      # repo, so nothing above its `.git` may leak in.
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "outer, must not be read")
      inner = Path.join(tmp_dir, "inner")
      File.mkdir_p!(Path.join(inner, ".git"))
      workdir = Path.join(inner, "lib")
      File.mkdir_p!(workdir)

      assert :none = ProjectContext.load(workdir)
    end

    test "treats absent and blank files as :none", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      assert :none = ProjectContext.load(tmp_dir)

      File.write!(Path.join(tmp_dir, "AGENTS.md"), "   \n\t\n")
      assert :none = ProjectContext.load(tmp_dir)
    end

    test "respects the byte cap and leaves a visible marker", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "0123456789ABCDEF")

      assert {:ok, body} = ProjectContext.load(tmp_dir, max_bytes: 10)
      assert body =~ "0123456789"
      refute body =~ "ABCDEF"
      assert body =~ "truncated"
    end

    test "does not split a multi-byte codepoint when truncating", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      # "é" is two bytes, so a 2-byte cap lands *inside* the second codepoint.
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "éé")

      assert {:ok, body} = ProjectContext.load(tmp_dir, max_bytes: 3)
      assert String.valid?(body)
      assert body =~ "é"
      assert body =~ "truncated"
    end

    test "sentinel/0 is a stable non-empty marker" do
      assert ProjectContext.sentinel() =~ "athanor:project-instructions"
    end
  end
end
