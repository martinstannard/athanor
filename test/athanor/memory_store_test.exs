defmodule Athanor.MemoryStoreTest do
  @moduledoc """
  Filesystem layer for §7.5 memory: the append-only `learnings.jsonl`, the curated
  `MEMORY.md`, and workspace-root discovery (plan §3.2, §3.4, §11.5).
  """
  use ExUnit.Case, async: true

  alias Athanor.Memory.Entry
  alias Athanor.Memory.Store

  @moduletag :tmp_dir

  defp entry(attrs), do: Entry.new(attrs)

  describe "learnings.jsonl" do
    test "append then read round-trips through JSON", %{tmp_dir: dir} do
      assert :ok =
               Store.append_learning(
                 dir,
                 entry(%{scope: :project, category: :gotcha, text: "mix test needs ATHANOR_* env"})
               )

      assert [%Entry{} = e] = Store.read_learnings(dir)
      assert e.text == "mix test needs ATHANOR_* env"
      assert e.category == :gotcha
      assert e.scope == :project
      assert e.id =~ ~r/^mem_[0-9a-f]{12}$/
    end

    test "read_learnings is [] when the file is absent", %{tmp_dir: dir} do
      assert Store.read_learnings(dir) == []
    end

    test "appended lines are one JSON object per line", %{tmp_dir: dir} do
      Store.append_learning(dir, entry(%{scope: :project, category: :fact, text: "one"}))
      Store.append_learning(dir, entry(%{scope: :project, category: :fact, text: "two"}))

      lines = dir |> Path.join("learnings.jsonl") |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
      assert Enum.all?(lines, &match?({:ok, _}, JSON.decode(&1)))
    end

    test "a tombstone line drops the entry it names", %{tmp_dir: dir} do
      e = entry(%{scope: :project, category: :fact, text: "temporary"})
      :ok = Store.append_learning(dir, e)

      # Forward-compatible reader: a line carrying an "op" is an op, not an entry (§8.3).
      File.write!(
        Path.join(dir, "learnings.jsonl"),
        JSON.encode!(%{"op" => "forget", "id" => e.id}) <> "\n",
        [:append]
      )

      assert Store.read_learnings(dir) == []
    end

    test "deprecated entries are excluded from reads", %{tmp_dir: dir} do
      e = entry(%{scope: :project, category: :fact, text: "old", deprecated: true})
      :ok = Store.append_learning(dir, e)
      assert Store.read_learnings(dir) == []
    end

    test "a torn final line is ignored, not fatal", %{tmp_dir: dir} do
      e = entry(%{scope: :project, category: :fact, text: "good"})
      :ok = Store.append_learning(dir, e)
      File.write!(Path.join(dir, "learnings.jsonl"), "{\"id\": \"mem_trunc", [:append])
      assert [%Entry{} = kept] = Store.read_learnings(dir)
      assert kept.text == "good"
    end
  end

  describe "MEMORY.md (curated projection)" do
    test "read_memory is nil when absent", %{tmp_dir: dir} do
      assert Store.read_memory(dir) == nil
    end

    test "upsert_bullet creates the section and is idempotent", %{tmp_dir: dir} do
      assert :ok = Store.upsert_bullet(dir, "Gotchas", "Worktrees share memory in this repo")
      assert :ok = Store.upsert_bullet(dir, "Gotchas", "Worktrees share memory in this repo")

      content = Store.read_memory(dir)
      assert content =~ "## Gotchas"
      assert content =~ "- Worktrees share memory in this repo"
      # exactly one bullet, not two
      assert length(String.split(content, "- Worktrees share memory in this repo")) == 2
    end

    test "upsert_bullet adds a second distinct bullet to the same section", %{tmp_dir: dir} do
      :ok = Store.upsert_bullet(dir, "Gotchas", "First gotcha")
      :ok = Store.upsert_bullet(dir, "Gotchas", "Second gotcha")

      content = Store.read_memory(dir)
      assert content =~ "- First gotcha"
      assert content =~ "- Second gotcha"
      assert length(String.split(content, "## Gotchas")) == 2
    end

    test "upsert_bullet preserves existing blank-line formatting in the section", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "MEMORY.md"), "## Facts\n- first\n\n- second\n")
      :ok = Store.upsert_bullet(dir, "Facts", "third")

      content = Store.read_memory(dir)
      assert content =~ "- first\n\n- second"
      assert content =~ "- third"
    end

    test "upsert_bullet preserves other sections", %{tmp_dir: dir} do
      :ok = Store.upsert_bullet(dir, "Architecture", "Auth lives in Athanor.Auth")
      :ok = Store.upsert_bullet(dir, "Gotchas", "A gotcha")

      content = Store.read_memory(dir)
      assert content =~ "## Architecture"
      assert content =~ "- Auth lives in Athanor.Auth"
      assert content =~ "## Gotchas"
    end
  end

  describe "workspace-root discovery (§11.5)" do
    test "ascends from a nested cd to the directory holding .athanor", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".athanor"))
      nested = Path.join([dir, "sub", "deeper"])
      File.mkdir_p!(nested)

      assert Store.workspace_root(nested) == dir
      assert Store.project_dir(nested) == Path.join(dir, ".athanor")
    end

    test "a .git directory is also a workspace marker", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      nested = Path.join(dir, "lib")
      File.mkdir_p!(nested)

      assert Store.workspace_root(nested) == dir
      # no .athanor yet: project_dir is nil, so injection is a no-op until remember creates it
      assert Store.project_dir(nested) == nil
    end

    test "an in-repo worktree-shaped cd resolves to the repo root, not the worktree", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".athanor"))
      wt = Path.join([dir, ".athanor", "worktrees", "w1"])
      File.mkdir_p!(wt)

      assert Store.workspace_root(wt) == dir
    end

    test "an out-of-repo worktree resolves through its .git pointer file", %{tmp_dir: dir} do
      # A real linked worktree has a .git *file* containing `gitdir: <main>/.git/worktrees/<n>`.
      main = Path.join(dir, "main")
      File.mkdir_p!(Path.join(main, ".athanor"))
      File.mkdir_p!(Path.join([main, ".git", "worktrees", "wt1"]))

      wt = Path.join(dir, "elsewhere/wt1")
      File.mkdir_p!(wt)

      File.write!(
        Path.join(wt, ".git"),
        "gitdir: #{Path.join([main, ".git", "worktrees", "wt1"])}\n"
      )

      assert Store.workspace_root(wt) == main
      assert Store.project_dir(wt) == Path.join(main, ".athanor")
    end

    test "no .athanor and no .git means no workspace (injection is a no-op)", %{tmp_dir: dir} do
      assert Store.workspace_root(dir) == nil
      assert Store.project_dir(dir) == nil
    end
  end

  describe "directory permissions" do
    test "ensure_dir creates the tier directory 0700", %{tmp_dir: dir} do
      target = Path.join(dir, "memory")
      assert :ok = Store.ensure_dir(target)
      assert File.dir?(target)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(target)
      assert Bitwise.band(mode, 0o777) == 0o700
    end
  end
end
