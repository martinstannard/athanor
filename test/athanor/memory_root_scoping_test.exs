defmodule Athanor.MemoryRootScopingTest do
  @moduledoc """
  `:root` scopes every memory tier (issue #51).

  `Memory.recall/2` used to resolve the **project** tier from `:cd`/`File.cwd!()` and ignore
  `:root` entirely, so a call that explicitly asked to be scoped to a scratch directory still read
  the ambient checkout's `.athanor/learnings.jsonl`. Any `remember`ed fact whose text contained a
  word an unrelated test asserted against then failed that test repo-wide, for everyone, until the
  entry was forgotten — and by then the failure message pointed nowhere near the cause.

  The fixture here is a **stand-in checkout** (`standin/`: a `.git/` marker — which is what the old
  ascension latched onto — plus a `.athanor/learnings.jsonl` carrying a nonce word) rather than this
  repository's real `.athanor/`. That is deliberate: the invariant is asserted directly, so these
  tests do not depend on a developer's accumulated memory, and running them cannot write to it.

  The pre-fix mechanism, for the record: `tier_dir(:project, root: isolated, cd: standin)` called
  `Store.workspace_root(standin)` — `:root` was never read — so the stand-in's learning was in
  scope; `remember/2` did the same and wrote into the `:cd` workspace instead of `:root`.
  """
  use ExUnit.Case, async: false

  alias Athanor.Memory
  alias Athanor.Memory.{Entry, Store}

  @moduletag :tmp_dir

  # A word no fixture, and no real learning, contains. The old leak made a *common* word ("worktrees",
  # in `memory_transcript_recall_test.exs`) the trigger; a nonce keeps this file's outcome a function
  # of the code alone.
  @word "nonceambientword"

  # A minimal stand-in for an ambient checkout: `.git/` makes it a workspace root (so an ascension
  # from `:cd` finds it), and `.athanor/learnings.jsonl` holds one learnable fact.
  defp standin(root) do
    File.mkdir_p!(Path.join(root, ".git"))
    dir = Path.join(root, ".athanor")
    Store.ensure_dir(dir)

    :ok =
      Store.append_learning(
        dir,
        Entry.new(%{scope: :project, category: :fact, text: "#{@word} lives in the stand-in"})
      )

    root
  end

  defp recall_body(args, opts) do
    {:ok, body} = Memory.recall(args, opts)
    body
  end

  defp texts(body) do
    body |> JSON.decode!() |> Enum.map(& &1["text"])
  end

  describe "recall/2 honours an explicit :root (issue #51)" do
    test "an explicit :root beats :cd, so an ambient checkout cannot leak in", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))
      isolated = Path.join(dir, "isolated")
      File.mkdir_p!(isolated)

      # `cd` is precisely what the old code resolved from; the explicit `:root` must win, and the
      # isolated directory has no memory of its own.
      assert recall_body(%{"query" => @word}, root: isolated, cd: standin) ==
               "No matching learnings."
    end

    test "the same call scoped to the stand-in does read it (the fixture is real)", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))

      assert [text] = recall_body(%{"query" => @word, "scope" => "project"}, root: standin) |> texts()
      assert text =~ @word
    end

    test "scope 'all' keeps the global tier inside :root too", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))
      isolated = Path.join(dir, "isolated")
      File.mkdir_p!(isolated)

      # No `global_dir`: the machine's real `~/.athanor/memory` must not be consulted, so a global
      # learning can no more leak into a scoped call than a project one.
      assert recall_body(%{"query" => @word, "scope" => "all"}, root: isolated, cd: standin) ==
               "No matching learnings."
    end

    test "a global learning is read from <root>/memory", %{tmp_dir: dir} do
      isolated = Path.join(dir, "isolated")
      global = Path.join(isolated, "memory")
      Store.ensure_dir(global)
      :ok = Store.append_learning(global, Entry.new(%{scope: :global, category: :fact, text: "a machine fact"}))

      assert [text] =
               recall_body(%{"query" => "machine", "scope" => "global"}, root: isolated) |> texts()

      assert text == "a machine fact"
    end

    test ":root is taken literally, never ascended", %{tmp_dir: dir} do
      # `isolated` is nested *inside* the stand-in checkout, whose `.athanor/` is one level up: the
      # old ascension found it, a literal `:root` must not.
      standin = standin(Path.join(dir, "checkout"))
      isolated = Path.join([standin, "lib", "deep"])
      File.mkdir_p!(isolated)

      assert recall_body(%{"query" => @word}, root: isolated, cd: standin) ==
               "No matching learnings."
    end
  end

  describe "remember/2 and forget/2 honour an explicit :root" do
    test "written where the caller asked, not in the :cd workspace", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))
      isolated = Path.join(dir, "isolated")

      assert {:ok, summary} =
               Memory.remember(%{"category" => "fact", "fact" => "only under root"},
                 root: isolated,
                 cd: standin
               )

      assert summary =~ "Remembered"

      assert [entry] = Store.read_learnings(Path.join(isolated, ".athanor"))
      assert entry.text == "only under root"

      # The stand-in still holds exactly its seeded learning, so nothing escaped into it.
      assert [%Entry{text: text}] = Store.read_learnings(Path.join(standin, ".athanor"))
      assert text =~ @word
    end

    test "forget/2 resolves and tombstones under the same :root", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))
      isolated = Path.join(dir, "isolated")
      opts = [root: isolated, cd: standin]

      assert {:ok, _} =
               Memory.remember(%{"category" => "fact", "fact" => "forgettable"}, opts)

      [entry] = Store.read_learnings(Path.join(isolated, ".athanor"))
      assert {:ok, "Forgot " <> _} = Memory.forget(%{"id" => entry.id}, opts)
      assert Store.read_learnings(Path.join(isolated, ".athanor")) == []

      # The stand-in's own learning is untouched.
      assert [%Entry{text: text}] = Store.read_learnings(Path.join(standin, ".athanor"))
      assert text =~ @word
    end
  end

  describe "resolve/1 scopes to :root" do
    test "returns the root's tiers, not the :cd workspace's", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))
      isolated = Path.join(dir, "isolated")
      File.mkdir_p!(isolated)

      resolved = Memory.resolve(root: isolated, cd: standin)
      assert resolved.workspace_root == isolated
      # No `.athanor/` yet: discovery stays read-only and reports absence (plan risk 9).
      assert resolved.project_dir == nil
      assert resolved.global_dir == Path.join(isolated, "memory")

      File.mkdir_p!(Path.join(isolated, ".athanor"))

      assert Memory.resolve(root: isolated, cd: standin).project_dir ==
               Path.join(isolated, ".athanor")
    end
  end

  describe "without :root, the :cd path is unchanged (production)" do
    test "project memory is still found by ascending from cd", %{tmp_dir: dir} do
      standin = standin(Path.join(dir, "checkout"))
      nested = Path.join([standin, "lib", "deep"])
      File.mkdir_p!(nested)

      # `remember`/`recall`/`forget` in production pass `cd` and never `root`; that path must keep
      # resolving to the workspace root exactly as before.
      assert [text] = recall_body(%{"query" => @word}, cd: nested) |> texts()
      assert text =~ @word
    end
  end
end
