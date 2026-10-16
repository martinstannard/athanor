defmodule Athanor.Store.HandoffTest do
  use ExUnit.Case, async: true

  alias Athanor.Store.{Handoff, Schema, Session}

  @moduletag :tmp_dir

  # NB: every test only touches its own `tmp_dir` (plan §9.1); none reads or writes `~/.athanor`.

  @sections [
    "## Goal",
    "## Completed steps",
    "## Open blockers",
    "## Active sub-agents",
    "## Files touched",
    "## Compaction log"
  ]

  defp session(overrides \\ []) do
    attrs =
      Keyword.merge(
        [
          id: "worker-1",
          title: "Audit Worker",
          role: :worker,
          parent_id: "conductor-main",
          model: "deepseek-v4.1-flash",
          cd: "/home/me/project",
          session_id: "ses_athanor_ab12cd34ef56",
          updated_at: ~U[2026-01-01 12:04:50Z],
          child_ids: ["worker-2"]
        ],
        overrides
      )

    if Keyword.get(attrs, :id) == :none do
      # A session with no id at all: `build/2` must fall back to "unknown" rather than raising.
      %{}
    else
      Session.new(attrs)
    end
  end

  defp user(content, opts \\ []),
    do: record(:user, %{"role" => "user", "content" => content}, opts)

  defp assistant(content, tool_calls, opts \\ []) do
    record(
      :assistant,
      %{"role" => "assistant", "content" => content, "tool_calls" => tool_calls},
      opts
    )
  end

  defp tool_result(id, content, opts \\ []) do
    record(:tool, %{"role" => "tool", "tool_call_id" => id, "content" => content}, opts)
  end

  defp tool_call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => JSON.encode!(args)}
    }
  end

  defp record(kind, payload, _opts) do
    %{"v" => 1, "seq" => 1, "kind" => to_string(kind), "payload" => payload}
  end

  defp event(payload), do: %{"kind" => "event", "payload" => payload}

  defp happy_path_records do
    [
      user("Audit all files under lib/ and report the Elixir version."),
      assistant("", [tool_call("c1", "read_file", %{"path" => "mix.exs"})]),
      tool_result("c1", "elixir ~> 1.19"),
      assistant("", [tool_call("c2", "bash", %{"command" => "mix test"})]),
      tool_result("c2", "42 tests, 0 failures"),
      event(%{
        "event" => "child_done",
        "child_id" => "worker-2",
        "status" => "idle",
        "summary" => "README checked"
      })
    ]
  end

  describe "render/2" do
    test "has every required section, in order, plus the sentinel" do
      doc = Handoff.render(session(), happy_path_records())

      assert String.contains?(doc, "<!-- athanor-handoff v1 -->")
      assert String.contains?(doc, "# Handoff — Audit Worker (worker-1)")

      positions =
        Enum.map(@sections, fn heading ->
          assert String.contains?(doc, heading), "missing #{heading}"
          {index, _length} = :binary.match(doc, heading)
          index
        end)

      assert positions == Enum.sort(positions), "sections are out of document order"
    end

    test "renders the documented metadata bullets from the session" do
      doc = Handoff.render(session(), [])

      assert String.contains?(doc, "- role: worker")
      assert String.contains?(doc, "- parent_id: conductor-main")
      assert String.contains?(doc, "- model: deepseek-v4.1-flash")
      assert String.contains?(doc, "- cd: /home/me/project")
      assert String.contains?(doc, "- opencode_session: ses_athanor_ab12cd34ef56")
      assert String.contains?(doc, "- updated_at: 2026-01-01T12:04:50Z")
    end

    test "renders completed steps and open blockers from tool outcomes" do
      records = [
        user("do the thing"),
        assistant("", [tool_call("c1", "read_file", %{"path" => "mix.exs"})]),
        tool_result("c1", "elixir ~> 1.19"),
        assistant("", [tool_call("c2", "bash", %{"command" => "mix nope"})]),
        tool_result("c2", "Error: no such task")
      ]

      doc = Handoff.render(session(), records)

      assert String.contains?(doc, ~s{- [x] read_file("mix.exs") → elixir ~> 1.19})
      assert String.contains?(doc, ~s{bash("mix nope"): Error: no such task})
      # The successful call is a step, the failing one a blocker — never both.
      assert length(String.split(doc, "- [x] ")) == 2
    end

    test "renders the sub-agent table from child_ids merged with child events" do
      doc = Handoff.render(session(), happy_path_records())

      assert String.contains?(doc, "| id | title | status | last summary |")
      assert String.contains?(doc, "|---|---|---|---|")
      assert String.contains?(doc, "| worker-2 | none | idle | README checked |")
    end

    test "renders files touched per path with the operations applied" do
      records = [
        user("edit it"),
        assistant("", [tool_call("c1", "read_file", %{"path" => "lib/a.ex"})]),
        tool_result("c1", "ok"),
        assistant("", [tool_call("c2", "edit_file", %{"path" => "lib/a.ex"})]),
        tool_result("c2", "ok"),
        assistant("", [tool_call("c3", "write_file", %{"path" => "lib/b.ex", "content" => "x"})]),
        tool_result("c3", "ok")
      ]

      doc = Handoff.render(session(), records)

      assert String.contains?(doc, "- lib/a.ex (read, edit)")
      assert String.contains?(doc, "- lib/b.ex (write)")
    end

    test "renders the compaction log from compaction records and session metadata" do
      records = [
        user("go"),
        %{
          "kind" => "compaction",
          "payload" => %{"at" => "2026-01-01T12:04:50Z", "kept" => 6, "dropped" => 18}
        }
      ]

      doc =
        Handoff.render(
          session(compaction: %{"count" => 1, "last_at" => "2026-01-01T12:05:00Z"}),
          records
        )

      assert String.contains?(doc, "2026-01-01T12:04:50Z: compacted 18 messages → kept 6")
      assert String.contains?(doc, "2026-01-01T12:05:00Z: compaction count=1")
    end

    test "empty sections render as `none`, so the document is never ambiguous" do
      doc = Handoff.render(session(), [])

      # Four empty list sections + the goal fallback's absence of a "- none" goal line.
      assert length(String.split(doc, "- none")) == 5
      assert String.contains?(doc, "## Goal\n(no goal recorded)")
    end

    test "tolerates a missing id and missing metadata without raising" do
      doc = Handoff.render(%{}, [])

      assert String.contains?(doc, "# Handoff — unknown (unknown)")
      assert String.contains?(doc, "- role: none")
    end
  end

  describe "parse/1 round trip" do
    test "parse(render(x)) returns exactly build/2's map" do
      s = session()
      records = happy_path_records()

      assert {:ok, parsed} = Handoff.parse(Handoff.render(s, records))
      assert parsed == Handoff.build(s, records)
    end

    test "round-trips an empty handoff" do
      s = session(child_ids: [])

      assert {:ok, parsed} = Handoff.parse(Handoff.render(s, []))
      assert parsed == Handoff.build(s, [])
      assert parsed.goal == "(no goal recorded)"
      assert parsed.completed_steps == []
      assert parsed.active_sub_agents == []
    end

    test "is idempotent: re-rendering a parsed document produces the same text" do
      s = session()
      first = Handoff.render(s, happy_path_records())

      assert {:ok, parsed} = Handoff.parse(first)

      assert Handoff.render(parsed, []) == first
    end

    test "round-trips unicode, pipes and markdown-ish content safely" do
      s = session(title: "Título — 日本語")
      records = [user("naïveté — 日本語 \n two lines | pipe")]

      assert {:ok, parsed} = Handoff.parse(Handoff.render(s, records))
      assert parsed == Handoff.build(s, records)
      assert parsed.title == "Título — 日本語"
    end

    test "rejects a document without the version sentinel" do
      assert {:error, :invalid_format} = Handoff.parse("# Handoff — x (y)\n## Goal\nhi")
    end

    test "rejects a document without the handoff heading" do
      assert {:error, :invalid_format} = Handoff.parse("<!-- athanor-handoff v1 -->\n## Goal\nhi")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_format} = Handoff.parse(nil)
      assert {:error, :invalid_format} = Handoff.parse(%{})
    end

    test "the sentinel is derived from Schema.handoff_version/0" do
      assert Handoff.sentinel() == "<!-- athanor-handoff v#{Schema.handoff_version()} -->"
      assert Handoff.sentinel() == Handoff.v1_sentinel()
    end
  end

  describe "to_summary_text/1" do
    test "contains the goal and the completed-step count" do
      data = Handoff.build(session(), happy_path_records())
      text = Handoff.to_summary_text(data)

      assert text =~ "Audit all files under lib/ and report the Elixir version."
      assert text =~ "Completed steps (2):"
      assert text =~ ~s{read_file("mix.exs") → elixir ~> 1.19}
      assert text =~ "worker-2 (idle): README checked"
    end

    test "is non-empty and well-formed for empty input" do
      text = Handoff.to_summary_text(%{})

      assert is_binary(text)
      assert String.trim(text) != ""
      assert text =~ "Goal: (no goal recorded)"
      assert text =~ "Completed steps (0): none"
    end

    test "is non-empty for a session with no records" do
      text = Handoff.to_summary_text(Handoff.build(session(), []))

      assert text =~ "Handoff for Audit Worker (worker-1)."
      assert text =~ "Goal: (no goal recorded)"
      assert text =~ "Completed steps (0): none"
    end

    test "flattens the sub-agent table into prose, not a Markdown table" do
      text = Handoff.to_summary_text(Handoff.build(session(), happy_path_records()))

      refute text =~ "|---|"
      refute text =~ "\n| "
    end

    test "accepts a rendered document string" do
      doc = Handoff.render(session(), happy_path_records())
      text = Handoff.to_summary_text(doc)

      assert text =~ "Completed steps (2):"
    end

    test "echoes back an unparseable string rather than raising" do
      assert Handoff.to_summary_text("not a handoff") == "not a handoff"
      assert Handoff.to_summary_text("") =~ "Goal: (no goal recorded)"
    end

    test "accepts a string-keyed data map" do
      data = %{
        "id" => "w",
        "title" => "T",
        "goal" => "ship it",
        "completed_steps" => ["a", "b"],
        "open_blockers" => ["blocked"],
        "active_sub_agents" => [],
        "files_touched" => ["f.ex (read)"],
        "compaction_log" => []
      }

      text = Handoff.to_summary_text(data)

      assert text =~ "Handoff for T (w)."
      assert text =~ "Goal: ship it"
      assert text =~ "Completed steps (2): a; b"
      assert text =~ "Open blockers: blocked"
    end

    test "a plain map with no section keys is treated as a session, not as data" do
      # A `%Session{}`-shaped map must never be misread as handoff data.
      text = Handoff.to_summary_text(%{id: "w", title: "T", role: "worker"})

      assert text =~ "Goal: (no goal recorded)"
      assert text =~ "Completed steps (0): none"
    end
  end

  describe "write/3 atomicity (C6)" do
    test "writes the document and leaves no tmp file behind", %{tmp_dir: dir} do
      path = Path.join(dir, "HANDOFF.md")

      assert :ok = Handoff.write(path, "# Handoff — x (y)\n")
      assert File.read!(path) == "# Handoff — x (y)\n"
      refute File.exists?(Handoff.tmp_path(path))
    end

    test "creates missing parent directories", %{tmp_dir: dir} do
      path = Path.join([dir, "sessions", "w", "HANDOFF.md"])

      assert :ok = Handoff.write(path, "hello")
      assert File.read!(path) == "hello"
    end

    test "replaces an existing file in place", %{tmp_dir: dir} do
      path = Path.join(dir, "HANDOFF.md")
      File.write!(path, "old")

      assert :ok = Handoff.write(path, "new")
      assert File.read!(path) == "new"
      refute File.exists?(Handoff.tmp_path(path))
    end

    test "a failure between tmp-write and rename leaves the old file intact and no stray .tmp",
         %{tmp_dir: dir} do
      path = Path.join(dir, "HANDOFF.md")
      File.write!(path, "the old handoff")

      inject = fn tmp, _target ->
        # The tmp file must be real and fully written at this point — that is what makes the
        # atomic rename meaningful.
        assert File.exists?(tmp)
        assert File.read!(tmp) == "the new handoff"
        {:error, :injected_crash}
      end

      assert {:error, :injected_crash} =
               Handoff.write(path, "the new handoff", before_rename: inject)

      assert File.read!(path) == "the old handoff"
      refute File.exists?(Handoff.tmp_path(path))
    end

    test "the tmp file is removed on a rename failure", %{tmp_dir: dir} do
      path = Path.join(dir, "HANDOFF.md")

      fail = fn _tmp, _target -> {:error, :boom} end

      assert {:error, :boom} = Handoff.write(path, "x", before_rename: fail)
      refute File.exists?(path)
      refute File.exists?(Handoff.tmp_path(path))
    end

    test "write/3 accepts a bare path (arity-2 call the plan's §12 lists)", %{tmp_dir: dir} do
      path = Path.join(dir, "HANDOFF.md")
      assert :ok = Handoff.write(path, "content")
      assert File.read!(path) == "content"
    end

    test "round-trips a rendered document through disk", %{tmp_dir: dir} do
      path = Path.join(dir, "HANDOFF.md")
      rendered = Handoff.render(session(), happy_path_records())

      assert :ok = Handoff.write(path, rendered)
      assert {:ok, parsed} = Handoff.parse(File.read!(path))
      assert parsed == Handoff.build(session(), happy_path_records())
    end
  end
end
