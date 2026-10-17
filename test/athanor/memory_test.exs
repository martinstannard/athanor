defmodule Athanor.MemoryTest do
  @moduledoc """
  Pure data layer for §7.5 memory: `Entry`, `Redact`, `Merge`, `Injector` and the facade
  (plan §3, §4, §9.1, §11.1).
  """
  use ExUnit.Case, async: true

  alias Athanor.Memory
  alias Athanor.Memory.Entry
  alias Athanor.Memory.Injector
  alias Athanor.Memory.Merge
  alias Athanor.Memory.Redact
  alias Athanor.Memory.Store

  @moduletag :tmp_dir

  defp entry(attrs), do: Entry.new(attrs)

  describe "Entry.new/1" do
    test "fills id, hash and timestamps" do
      e = entry(%{scope: :project, category: :gotcha, text: "A durable fact"})

      assert e.id =~ ~r/^mem_[0-9a-f]{12}$/
      assert is_binary(e.hash) and byte_size(e.hash) == 16
      assert {:ok, _, _} = DateTime.from_iso8601(e.created_at)
      assert e.created_at == e.updated_at
      assert e.deprecated == false
      assert e.hits == 0
      assert e.tags == []
    end

    test "accepts a keyword list and defaults source" do
      e = entry(scope: :global, category: :preference, text: "Prefer rebase")
      assert e.scope == :global
      assert is_map(e.source)
    end
  end

  describe "Entry.normalize/1 and hash/1 (D7)" do
    test "case and whitespace variants normalize identically" do
      assert Entry.normalize("  Mix   TEST\nneeds ENV. ") == Entry.normalize("mix test needs env")
    end

    test "variants share a hash, so they dedup" do
      a = entry(%{scope: :project, category: :fact, text: "Auth   lives in Athanor.Auth."})
      b = entry(%{scope: :project, category: :fact, text: "auth lives in athanor.auth"})
      assert a.hash == b.hash
    end

    test "different facts have different hashes" do
      a = entry(%{scope: :project, category: :fact, text: "one"})
      b = entry(%{scope: :project, category: :fact, text: "two"})
      assert a.hash != b.hash
    end
  end

  describe "Entry JSON round-trip" do
    test "to_json/from_json preserve the shape" do
      e =
        entry(%{
          scope: :project,
          category: :gotcha,
          text: "a gotcha",
          tags: ["x"],
          source: %{"session_id" => "s1", "kind" => "tool"}
        })

      assert {:ok, back} = e |> Entry.to_json() |> Entry.from_json()
      assert back.id == e.id
      assert back.scope == :project
      assert back.category == :gotcha
      assert back.text == e.text
      assert back.tags == ["x"]
      assert back.hash == e.hash
      assert back.source["session_id"] == "s1"
    end

    test "from_json rejects a non-object line" do
      assert {:error, _} = Entry.from_json("not json")
    end
  end

  describe "Redact.scrub/1 (D6)" do
    test "scrubs AI-style keys" do
      refute Redact.scrub("key sk-abcdef0123456789abcdef here") =~ "sk-abcdef0123456789abcdef"
    end

    test "scrubs a bearer token" do
      refute Redact.scrub("Authorization: Bearer abc123def456") =~ "abc123def456"
    end

    test "scrubs an AWS access key" do
      refute Redact.scrub("AKIAIOSFODNN7EXAMPLE") =~ "AKIAIOSFODNN7EXAMPLE"
    end

    test "scrubs a PEM private key block" do
      pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----"
      refute Redact.scrub(pem) =~ "MIIabc"
    end

    test "scrubs a generic key=value secret" do
      refute Redact.scrub("api_key=supersecretvalue") =~ "supersecretvalue"
    end

    test "leaves ordinary prose alone" do
      assert Redact.scrub("Prefer git rebase over merge commits") ==
               "Prefer git rebase over merge commits"
    end
  end

  describe "Merge.merge/1 precedence (§4.2)" do
    test "same hash at project and global collapses to project" do
      p = entry(%{scope: :project, category: :fact, text: "Shared fact"})
      g = entry(%{scope: :global, category: :fact, text: "shared fact"})

      assert [%Entry{scope: :project}] = Merge.merge([g, p])
    end

    test "session outranks project" do
      p = entry(%{scope: :project, category: :fact, text: "Shared fact"})
      s = entry(%{scope: :session, category: :fact, text: "shared fact"})

      assert [%Entry{scope: :session}] = Merge.merge([p, s])
    end

    test "deprecated entries are dropped" do
      assert Merge.merge([entry(%{scope: :project, category: :fact, text: "x", deprecated: true})]) == []
    end

    test "orders by rank then recency" do
      old = entry(%{scope: :project, category: :fact, text: "old", updated_at: "2020-01-01T00:00:00Z"})
      new = entry(%{scope: :project, category: :fact, text: "new", updated_at: "2026-01-01T00:00:00Z"})
      global = entry(%{scope: :global, category: :fact, text: "global fact"})

      assert [a, b, c] = Merge.merge([old, global, new])
      assert a.text == "new"
      assert b.text == "old"
      assert c.text == "global fact"
    end
  end

  describe "Injector.build/2" do
    test "renders curated project memory with a heading", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "MEMORY.md"), "# Project Memory\n\n## Gotchas\n- A known gotcha\n")

      section = Injector.build(%{project_dir: dir, global_dir: nil}, [])
      assert section =~ "## Memory"
      assert section =~ "A known gotcha"
    end

    test "is nil when there is nothing to inject", %{tmp_dir: dir} do
      assert Injector.build(%{project_dir: dir, global_dir: nil}, []) == nil
    end

    test "redacts secrets on injection, not just on write (D6)", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "MEMORY.md"), "## Facts\n- the key is sk-abcdef0123456789abcd\n")

      section = Injector.build(%{project_dir: dir, global_dir: nil}, [])
      refute section =~ "sk-abcdef0123456789abcd"
    end

    test "truncates to the project budget, dropping the tail and pointing at recall", %{tmp_dir: dir} do
      bullets = Enum.map_join(1..50, "\n", fn i -> "- bullet number #{i} with some padding text" end)
      File.write!(Path.join(dir, "MEMORY.md"), "## Facts\n#{bullets}\n")

      section = Injector.build(%{project_dir: dir, global_dir: nil}, project_budget: 300)

      assert byte_size(section) <= 400
      assert section =~ "use recall"
      # the first bullet is kept, later ones are the ones dropped
      assert section =~ "bullet number 1 "
      refute section =~ "bullet number 50"
    end

    test "global memory is header-only by default (D8)", %{tmp_dir: dir} do
      global = Path.join(dir, "global")
      File.mkdir_p!(global)
      File.write!(Path.join(global, "MEMORY.md"), "## Preferences\n- A machine-specific secret workflow\n")

      section = Injector.build(%{project_dir: nil, global_dir: global}, [])
      assert section =~ "Global memory"
      refute section =~ "A machine-specific secret workflow"
    end

    test "global memory is fully injected when opted in", %{tmp_dir: dir} do
      global = Path.join(dir, "global")
      File.mkdir_p!(global)
      File.write!(Path.join(global, "MEMORY.md"), "## Preferences\n- A machine-specific workflow\n")

      section = Injector.build(%{project_dir: nil, global_dir: global}, global_inject: true)
      assert section =~ "A machine-specific workflow"
    end
  end

  describe "Memory.resolve/1" do
    test "returns the workspace root, project dir and global dir", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".athanor"))
      nested = Path.join(dir, "a/b")
      File.mkdir_p!(nested)
      global = Path.join(dir, "ghome")

      resolved = Memory.resolve(cd: nested, global_dir: global)
      assert resolved.workspace_root == dir
      assert resolved.project_dir == Path.join(dir, ".athanor")
      assert resolved.global_dir == global
    end

    test "degrades gracefully outside a workspace", %{tmp_dir: dir} do
      resolved = Memory.resolve(cd: dir, global_dir: Path.join(dir, "ghome"))
      assert resolved.workspace_root == nil
      assert resolved.project_dir == nil
    end
  end

  describe "Memory.distill/2 (§7.5 M4)" do
    test "records learnings and projects only curated categories into MEMORY.md", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".athanor"))

      entries = [
        %{"category" => "gotcha", "fact" => "A durable gotcha"},
        %{"category" => "fact", "fact" => "An incidental fact"}
      ]

      assert {:ok, summary} = Memory.distill(entries, cd: dir)
      assert summary =~ "Distilled 2"

      memory = Store.read_memory(Path.join(dir, ".athanor"))
      assert memory =~ "- A durable gotcha"
      refute memory =~ "An incidental fact"
    end

    test "is idempotent across runs", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".athanor"))
      entries = [%{"category" => "gotcha", "fact" => "A durable gotcha"}]

      assert {:ok, _first} = Memory.distill(entries, cd: dir)
      assert {:ok, second} = Memory.distill(entries, cd: dir)
      assert second =~ "already known"

      memory = Store.read_memory(Path.join(dir, ".athanor"))
      assert length(String.split(memory, "- A durable gotcha")) == 2
    end

    test "surfaces a failure rather than reporting success", %{tmp_dir: dir} do
      # No .git/.athanor above the directory: there is nowhere to persist a project learning.
      assert {:error, message} = Memory.distill([%{"category" => "fact", "fact" => "x"}], cd: dir)
      assert message =~ "workspace"
    end
  end

  describe "Memory.system_prompt_section/1" do
    test "is nil with no memory anywhere", %{tmp_dir: dir} do
      assert Memory.system_prompt_section(cd: dir, global_dir: Path.join(dir, "ghome")) == nil
    end

    test "injects project memory found by ascending from cd", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".athanor"))
      File.write!(Path.join([dir, ".athanor", "MEMORY.md"]), "## Conventions\n- Use tagged tuples\n")

      section =
        Memory.system_prompt_section(cd: dir, global_dir: Path.join(dir, "ghome"))

      assert section =~ "Use tagged tuples"
    end
  end
end
