defmodule Athanor.StoreTest do
  use ExUnit.Case, async: true

  alias Athanor.Store
  alias Athanor.Store.{Schema, Session, Transcript}

  @moduletag :tmp_dir

  # Every test passes `root: tmp_dir` explicitly so nothing reads or writes `~/.athanor`.

  defp session_attrs(overrides \\ []) do
    Keyword.merge(
      [
        id: "worker-1",
        title: "Audit Worker",
        role: :worker,
        parent_id: "conductor-main",
        model: "deepseek-v4.1-flash",
        cd: "/home/me/project",
        session_id: "ses_athanor_ab12cd34ef56",
        created_at: ~U[2026-01-01 12:00:00Z],
        updated_at: ~U[2026-01-01 12:05:00Z],
        last_status: :idle,
        turn_count: 3,
        child_ids: ["worker-2"],
        compaction: %{"count" => 1, "last_at" => "2026-01-01T12:04:50.000Z"}
      ],
      overrides
    )
  end

  describe "path resolution" do
    test "root/1 honours :root and expands it", %{tmp_dir: dir} do
      assert Store.root(root: dir) == Path.expand(dir)

      assert Store.root(root: Path.join(dir, "nested/../nested")) ==
               Path.expand(Path.join(dir, "nested"))
    end

    test "sessions_root/1 and session_dir/2 build the documented layout", %{tmp_dir: dir} do
      assert Store.sessions_root(root: dir) == Path.join(Path.expand(dir), "sessions")

      assert Store.session_dir("worker-1", root: dir) ==
               Path.join([Path.expand(dir), "sessions", "worker-1"])

      assert Store.meta_path("worker-1", root: dir) ==
               Path.join([dir, "sessions", "worker-1", "meta.json"])

      assert Store.transcript_path("w", root: dir) ==
               Path.join([dir, "sessions", "w", "transcript.jsonl"])

      assert Store.handoff_path("w", root: dir) == Path.join([dir, "sessions", "w", "HANDOFF.md"])
    end

    test "root/1 falls back to Config.home/0", %{tmp_dir: dir} do
      previous = System.get_env("ATHANOR_HOME")
      System.put_env("ATHANOR_HOME", dir)
      on_exit(fn -> restore_env("ATHANOR_HOME", previous) end)

      assert Store.root() == Path.expand(dir)
      assert Athanor.Config.home() == Path.expand(dir)
    end

    test "no test path escapes the tmp root", %{tmp_dir: dir} do
      # Pin the whole path, do not substring-match the home dir. `~/.athanor/worktrees` is the
      # *default* worktree root, so a checkout living under it contains "/.athanor" in its own
      # tmp_dir path and any substring heuristic false-positives there — which is what made this
      # test red in every default worktree (#40). Exact equality is strictly stronger: a helper
      # that ignored `root:` and resolved to the real `~/.athanor` still yields a different path.
      assert Store.session_dir("x", root: dir) == Path.join([Path.expand(dir), "sessions", "x"])
    end
  end

  describe "Session.new/1, to_map/1, from_map/1" do
    test "new/1 derives role, title and defaults" do
      child = Session.new(id: "worker-1", parent_id: "conductor-main", cd: "/tmp")
      assert child.role == :worker
      assert child.title == "worker-1"
      assert child.parent_id == "conductor-main"

      root = Session.new(id: "conductor-main", cd: "/tmp")
      assert root.role == :conductor
      assert root.parent_id == nil
      assert root.version == 1
      assert root.last_status == :idle
      assert root.turn_count == 0
    end

    test "round-trips through map form with iso8601 timestamps" do
      session = Session.new(session_attrs())
      map = Session.to_map(session)

      assert map["version"] == 1
      assert map["id"] == "worker-1"
      assert map["role"] == "worker"
      assert map["session_id"] == "ses_athanor_ab12cd34ef56"
      assert map["created_at"] == "2026-01-01T12:00:00Z"
      assert map["child_ids"] == ["worker-2"]

      assert {:ok, decoded} = Session.from_map(map)
      assert decoded.id == session.id
      assert decoded.role == :worker
      assert decoded.opencode_session_id == "ses_athanor_ab12cd34ef56"
      assert decoded.created_at == ~U[2026-01-01 12:00:00Z]
      assert decoded.compaction == %{"count" => 1, "last_at" => "2026-01-01T12:04:50.000Z"}
      assert Session.to_map(decoded) == map
    end

    test "from_map/1 tolerates unknown fields and a missing version" do
      map = %{
        "id" => "w",
        "role" => "conductor",
        "future" => %{"worktree" => "/tmp/wt"},
        "goal_id" => "goal-1"
      }

      assert {:ok, session} = Session.from_map(map)
      assert session.version == 1
      assert session.role == :conductor
      assert session.title == "w"
      assert session.child_ids == []
    end

    test "from_map/1 accepts opencode_session_id as an alias for session_id" do
      map = %{"id" => "w", "role" => "worker", "opencode_session_id" => "ses_alias"}
      assert {:ok, session} = Session.from_map(map)
      assert session.opencode_session_id == "ses_alias"

      # …but to_map/1 always writes the canonical key (design §7.4 naming).
      assert Session.to_map(session)["session_id"] == "ses_alias"
      refute Map.has_key?(Session.to_map(session), "opencode_session_id")
    end

    test "from_map/1 rejects maps without mandatory fields" do
      assert {:error, :corrupt} = Session.from_map(%{"role" => "worker"})
      assert {:error, :corrupt} = Session.from_map(%{"id" => "w"})
      assert {:error, :corrupt} = Session.from_map(%{"id" => "w", "role" => nil})
      assert {:error, :corrupt} = Session.from_map("not a map")
    end

    test "normalises unknown role/status strings to safe atoms" do
      assert {:ok, session} =
               Session.from_map(%{"id" => "w", "role" => "wat", "last_status" => "exploding"})

      assert session.role == :conductor
      assert session.last_status == :idle
    end
  end

  describe "ensure_session/2" do
    test "creates the directory and meta.json, and meta precedes the first transcript record", %{
      tmp_dir: dir
    } do
      refute File.exists?(Store.session_dir("worker-1", root: dir))

      assert :ok = Store.ensure_session(session_attrs(), root: dir)

      assert File.dir?(Store.session_dir("worker-1", root: dir))
      assert File.exists?(Store.meta_path("worker-1", root: dir))
      refute File.exists?(Store.transcript_path("worker-1", root: dir))

      assert {:ok, %Session{} = session} = Store.load("worker-1", root: dir)
      assert session.id == "worker-1"
      assert session.role == :worker
      assert session.parent_id == "conductor-main"
      assert session.opencode_session_id == "ses_athanor_ab12cd34ef56"
      assert session.turn_count == 3
    end

    test "accepts a %Session{} struct", %{tmp_dir: dir} do
      session = Session.new(session_attrs(id: "conductor-main", role: :conductor, parent_id: nil))
      assert :ok = Store.ensure_session(session, root: dir)

      assert {:ok, %Session{id: "conductor-main", role: :conductor}} =
               Store.load("conductor-main", root: dir)
    end

    test "is idempotent and never leaves a .tmp behind", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(), root: dir)
      assert :ok = Store.ensure_session(session_attrs(turn_count: 9), root: dir)

      assert {:ok, session} = Store.load("worker-1", root: dir)
      assert session.turn_count == 9
      refute File.exists?(Store.meta_path("worker-1", root: dir) <> ".tmp")
      assert File.ls!(Store.session_dir("worker-1", root: dir)) |> Enum.sort() == ["meta.json"]
    end

    test "meta.json is replaced atomically (no partial read window)", %{tmp_dir: dir} do
      # A reader looping while writers replace meta.json must never see invalid JSON.
      assert :ok = Store.ensure_session(session_attrs(), root: dir)

      task =
        Task.async(fn ->
          for i <- 1..50 do
            Store.ensure_session(session_attrs(turn_count: i), root: dir)
          end
        end)

      for _ <- 1..50 do
        path = Store.meta_path("worker-1", root: dir)

        case File.read(path) do
          {:ok, content} -> assert {:ok, %{"id" => "worker-1"}} = JSON.decode(content)
          {:error, :enoent} -> flunk("meta.json vanished during an atomic replace")
        end
      end

      Task.await(task)
      assert {:ok, %Session{}} = Store.load("worker-1", root: dir)
    end

    test "creates the session dir with owner-only permissions", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(), root: dir)

      # Transcripts can hold secrets the agent read (plan §10 risk 5).
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Store.session_dir("worker-1", root: dir))
      assert Bitwise.band(mode, 0o077) == 0
    end
  end

  describe "load/1 and load_records/1" do
    test "load/1 reports missing sessions as :not_found", %{tmp_dir: dir} do
      assert {:error, :not_found} = Store.load("nope", root: dir)
    end

    test "load/1 reports unparseable meta as :corrupt", %{tmp_dir: dir} do
      File.mkdir_p!(Store.session_dir("bad", root: dir))
      File.write!(Store.meta_path("bad", root: dir), "{not json")
      assert {:error, :corrupt} = Store.load("bad", root: dir)
    end

    test "load/1 reports a meta with no id/role as :corrupt", %{tmp_dir: dir} do
      File.mkdir_p!(Store.session_dir("bad", root: dir))
      File.write!(Store.meta_path("bad", root: dir), JSON.encode!(%{"version" => 1}))
      assert {:error, :corrupt} = Store.load("bad", root: dir)
    end

    test "load_records/1 returns every record plus metadata", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(), root: dir)

      message = %{"role" => "user", "content" => "hi"}

      assert :ok =
               Transcript.append(
                 Store.session_dir("worker-1", root: dir),
                 Transcript.new_record(:user, message, seq: 1, session_id: "worker-1")
               )

      assert {:ok, [record], meta} = Store.load_records("worker-1", root: dir)
      assert record["payload"] == message
      assert meta["id"] == "worker-1"
      assert meta[:truncated] == 0
    end

    test "load_records/1 surfaces a truncated tail", %{tmp_dir: root} do
      assert :ok = Store.ensure_session(session_attrs(), root: root)
      sdir = Store.session_dir("worker-1", root: root)

      assert :ok =
               Transcript.append(
                 sdir,
                 Transcript.new_record(:user, %{"role" => "user"}, seq: 1, session_id: "worker-1")
               )

      File.write!(Transcript.path(sdir), File.read!(Transcript.path(sdir)) <> ~s({"v":1,"seq":2))
      assert {:ok, [_one], meta} = Store.load_records("worker-1", root: root)
      assert meta[:truncated] > 0
    end

    test "load_records/1 propagates interior corruption", %{tmp_dir: root} do
      assert :ok = Store.ensure_session(session_attrs(), root: root)
      sdir = Store.session_dir("worker-1", root: root)
      File.write!(Transcript.path(sdir), "{\"seq\":1}\nGARBAGE\n{\"seq\":3}\n")
      assert {:error, :corrupt} = Store.load_records("worker-1", root: root)
    end

    test "load_records/1 works for a session with metadata but no transcript", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(), root: dir)
      assert {:ok, [], %{"id" => "worker-1"} = meta} = Store.load_records("worker-1", root: dir)
      assert meta[:truncated] == 0
    end
  end

  describe "list/1 (tolerant directory scan)" do
    test "returns every loadable session sorted by id", %{tmp_dir: dir} do
      for id <- ["worker-b", "conductor-main", "worker-a"] do
        assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)
      end

      assert Store.list(root: dir) |> Enum.map(& &1.id) == [
               "conductor-main",
               "worker-a",
               "worker-b"
             ]
    end

    test "is empty when the root does not exist", %{tmp_dir: dir} do
      assert Store.list(root: Path.join(dir, "absent")) == []
    end

    test "skips directories without meta.json", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(id: "real"), root: dir)
      File.mkdir_p!(Store.session_dir("half-written", root: dir))

      assert Store.list(root: dir) |> Enum.map(& &1.id) == ["real"]
    end

    test "skips malformed, corrupt and too-new meta.json files", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(id: "good"), root: dir)

      File.mkdir_p!(Store.session_dir("garbage", root: dir))
      File.write!(Store.meta_path("garbage", root: dir), "{{{")

      File.mkdir_p!(Store.session_dir("empty", root: dir))
      File.write!(Store.meta_path("empty", root: dir), JSON.encode!(%{"version" => 1}))

      File.mkdir_p!(Store.session_dir("future", root: dir))

      File.write!(
        Store.meta_path("future", root: dir),
        JSON.encode!(%{"version" => 99, "id" => "future", "role" => "worker"})
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Store.list(root: dir) |> Enum.map(& &1.id) == ["good"]
        end)

      assert log =~ "skipping session"
      assert log =~ "garbage"
      assert log =~ "unsupported_version"
    end
  end

  describe "check_version/1" do
    test "accepts the current version and older ones" do
      assert Store.check_version(%{"version" => 1}) == :ok
      assert Store.check_version(%{"version" => 0}) == :ok
      assert Store.check_version(%{"v" => 1}) == :ok
      assert Store.check_version(%{}) == :ok
    end

    test "rejects a newer version with {:unsupported_version, n}" do
      assert Store.check_version(%{"version" => 2}) == {:error, {:unsupported_version, 2}}
      assert Store.check_version(%{"version" => 99}) == {:error, {:unsupported_version, 99}}
      assert Store.check_version(%{"v" => 7}) == {:error, {:unsupported_version, 7}}
    end

    test "load/1 refuses a too-new meta.json", %{tmp_dir: dir} do
      File.mkdir_p!(Store.session_dir("future", root: dir))

      File.write!(
        Store.meta_path("future", root: dir),
        JSON.encode!(%{"version" => 2, "id" => "future", "role" => "worker"})
      )

      assert {:error, {:unsupported_version, 2}} = Store.load("future", root: dir)
    end

    test "unknown fields are skipped by readers", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(id: "fwd"), root: dir)

      map =
        Store.meta_path("fwd", root: dir)
        |> File.read!()
        |> JSON.decode!()
        |> Map.put("worktree_path", "/tmp/wt")
        |> Map.put("goal_id", "goal-1")

      File.write!(Store.meta_path("fwd", root: dir), JSON.encode!(map))

      assert {:ok, session} = Store.load("fwd", root: dir)
      assert session.id == "fwd"
      assert Store.list(root: dir) |> Enum.map(& &1.id) == ["fwd"]
    end
  end

  describe "Schema" do
    test "version constants all start at 1" do
      assert Schema.meta_version() == 1
      assert Schema.record_version() == 1
      assert Schema.handoff_version() == 1
      assert Schema.current_version() == 1
    end

    test "migrate/1 is an identity for the current version" do
      doc = %{"version" => 1, "id" => "w"}
      assert {:ok, ^doc} = Schema.migrate(doc)
      assert {:ok, %{"id" => "w"}} = Schema.migrate(%{"id" => "w"})
    end

    test "migrate/1 rejects a future version and non-map input" do
      assert {:error, {:unsupported_version, 99}} = Schema.migrate(%{"version" => 99})
      assert {:error, :corrupt} = Schema.migrate([1, 2, 3])
    end

    test "migrate/1 passes an older version through while its migration is unwritten" do
      # Version 0 = a pre-versioning fixture. Its shape is a superset of version 1's required
      # fields, so it is loadable as-is (plan §9.4/§9.7: a v0 fixture must not crash the sweep).
      assert {:ok, %{"version" => 0, "id" => "w", "role" => "worker"}} =
               Schema.migrate(%{"version" => 0, "id" => "w", "role" => "worker"})
    end

    test "load/1 reads a version 0 fixture in place", %{tmp_dir: dir} do
      File.mkdir_p!(Store.session_dir("legacy", root: dir))

      File.write!(
        Store.meta_path("legacy", root: dir),
        JSON.encode!(%{"version" => 0, "id" => "legacy", "role" => "worker"})
      )

      assert {:ok, session} = Store.load("legacy", root: dir)
      assert session.id == "legacy"
      assert session.role == :worker
      assert session.version == 0
    end

    test "version_of/1 tolerates junk" do
      assert Schema.version_of(%{"version" => "one"}) == 1
      assert Schema.version_of(%{"version" => -1}) == 1
      assert Schema.version_of(:nope) == 1
    end
  end

  describe "delete/1" do
    test "delete/1 removes the whole session directory and is idempotent", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(), root: dir)
      assert File.dir?(Store.session_dir("worker-1", root: dir))

      assert :ok = Store.delete("worker-1", root: dir)
      refute File.exists?(Store.session_dir("worker-1", root: dir))
      assert :ok = Store.delete("worker-1", root: dir)
      refute File.exists?(Store.session_dir("worker-1", root: dir))
      assert Store.list(root: dir) == []
    end

    test "delete/1 only removes the target session", %{tmp_dir: dir} do
      assert :ok = Store.ensure_session(session_attrs(id: "a"), root: dir)
      assert :ok = Store.ensure_session(session_attrs(id: "b"), root: dir)

      assert :ok = Store.delete("a", root: dir)
      assert Store.list(root: dir) |> Enum.map(& &1.id) == ["b"]
    end
  end

  describe "reconcile/2 (M6)" do
    # The scenario the plan pins (§5.2 "Recorder crash", §11 M6): the Recorder was down while a
    # turn was appended to the agent's working set, so the transcript is missing its tail.
    test "appends the live messages beyond the longest common prefix", %{tmp_dir: dir} do
      id = "rec-a"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)
      write_messages(id, dir, [{:user, user_msg("u1"), 1}, {:assistant, assistant_msg("a1"), 2}])

      live = [user_msg("u1"), assistant_msg("a1"), user_msg("u2")]

      assert {:ok, %{appended: 1}} = Store.reconcile(id, root: dir, messages: live)

      # The transcript now reads back exactly the live set.
      assert persisted_messages(id, dir) == live

      # …and re-running is a no-op: the first run made the transcript a prefix of the live set.
      assert {:ok, %{appended: 0}} = Store.reconcile(id, root: dir, messages: live)
      assert persisted_messages(id, dir) == live

      # Nothing was duplicated, reordered or rewritten.
      assert length(records(id, dir)) == 3
    end

    test "is a no-op when the transcript already equals the live set", %{tmp_dir: dir} do
      id = "rec-equal"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      live = [user_msg("u1"), assistant_msg("a1")]
      write_messages(id, dir, [{:user, user_msg("u1"), 1}, {:assistant, assistant_msg("a1"), 2}])

      before = File.read!(Store.transcript_path(id, root: dir))
      assert {:ok, %{appended: 0}} = Store.reconcile(id, root: dir, messages: live)
      assert File.read!(Store.transcript_path(id, root: dir)) == before
    end

    test "a transcript holding more than the live set is a warned no-op", %{tmp_dir: dir} do
      id = "rec-more"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      write_messages(id, dir, [
        {:user, user_msg("u1"), 1},
        {:assistant, assistant_msg("a1"), 2},
        {:user, user_msg("u2"), 3}
      ])

      before = records(id, dir)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{appended: 0}} =
                   Store.reconcile(id, root: dir, messages: [user_msg("u1"), assistant_msg("a1")])
        end)

      assert log =~ "nothing to reconcile"
      assert log =~ id
      # Never a deletion: the extra persisted record survives.
      assert records(id, dir) == before
    end

    test "a mid-history divergence appends the live tail without rewriting anything", %{
      tmp_dir: dir
    } do
      id = "rec-diverge"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      write_messages(id, dir, [{:user, user_msg("u1"), 1}, {:assistant, assistant_msg("a1"), 2}])

      # The first message agrees; the second does not, so the append point is the first mismatch.
      live = [user_msg("u1"), assistant_msg("a2")]

      assert {:ok, %{appended: 1}} = Store.reconcile(id, root: dir, messages: live)

      assert Enum.map(records(id, dir), & &1["payload"]) ==
               [user_msg("u1"), assistant_msg("a1"), assistant_msg("a2")]
    end

    test "compares structurally: atom-keyed live messages match string-keyed records", %{
      tmp_dir: dir
    } do
      id = "rec-keys"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      write_messages(id, dir, [{:assistant, assistant_msg("a1"), 1}])

      # An `Agent.get_state/1` working set is atom-keyed; its persisted record is JSON-decoded.
      assert {:ok, %{appended: 0}} =
               Store.reconcile(id,
                 root: dir,
                 messages: [%{role: "assistant", content: "a1", tool_calls: []}]
               )

      assert {:ok, %{appended: 1}} =
               Store.reconcile(id,
                 root: dir,
                 messages: [
                   %{role: "assistant", content: "a1", tool_calls: []},
                   %{role: :user, content: "u2"}
                 ]
               )

      assert persisted_messages(id, dir) == [assistant_msg("a1"), user_msg("u2")]
    end

    test "ignores the system message and appends tool calls with a continuing seq", %{
      tmp_dir: dir
    } do
      id = "rec-tool"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)
      write_messages(id, dir, [{:user, user_msg("u1"), 5}])

      system = %{role: "system", content: "you are a sub-agent"}

      assistant = %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{
            id: "call_1",
            type: "function",
            function: %{name: "bash", arguments: ~s({"command":"true"})}
          }
        ]
      }

      tool = %{role: "tool", tool_call_id: "call_1", content: ""}

      # The `system` message is never persisted (C13), so it takes no part in the diff.
      assert {:ok, %{appended: 2}} =
               Store.reconcile(id, root: dir, messages: [system, user_msg("u1"), assistant, tool])

      assert {:ok, aged, _meta} = Store.load_records(id, root: dir)

      assert aged |> Enum.map(& &1["seq"]) == [5, 6, 7]
      assert aged |> Enum.map(& &1["kind"]) == ["user", "assistant", "tool"]

      # The live message was atom-keyed; the persisted payload is its JSON-decoded form.
      assert Enum.at(aged, 2)["payload"] == JSON.decode!(JSON.encode!(tool))

      # The tool call survives verbatim (its `arguments` stays a JSON string).
      assert Enum.at(aged, 1)["payload"]["tool_calls"]
             |> hd()
             |> get_in(["function", "arguments"]) ==
               ~s({"command":"true"})
    end

    test "audit records take no part in the diff", %{tmp_dir: dir} do
      id = "rec-audit"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      write_messages(id, dir, [{:user, user_msg("u1"), 1}])

      assert :ok =
               Transcript.append(
                 Store.session_dir(id, root: dir),
                 Transcript.new_record(:status, %{"status" => "idle"}, seq: 2, session_id: id)
               )

      assert {:ok, %{appended: 1}} =
               Store.reconcile(id, root: dir, messages: [user_msg("u1"), assistant_msg("a1")])

      assert persisted_messages(id, dir) == [user_msg("u1"), assistant_msg("a1")]
      assert records(id, dir) |> Enum.map(& &1["kind"]) == ["user", "status", "assistant"]
    end

    test "falls back to a live agent's get_state/1 when no :messages is given", %{tmp_dir: dir} do
      id = "rec-live-#{System.unique_integer([:positive])}"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      # Only the first two messages reach the "disk" (as if the Recorder had been down for the
      # rest of the turn).
      write_messages(id, dir, [{:user, user_msg("u1"), 1}])

      llm_fn = fn _messages, _tools, _pid ->
        {:ok, %{role: "assistant", content: "done", tool_calls: []}}
      end

      {:ok, agent} =
        Athanor.Agent.start_link(
          id: id,
          register: true,
          subscriber: nil,
          cd: dir,
          llm_fn: llm_fn
        )

      assert :ok = Athanor.Agent.prompt(agent, "u1")
      wait_until_idle(agent)
      live = Athanor.Agent.get_state(agent).messages

      # `system` leads the live list but is never transcribed, so only user + assistant are added.
      assert Enum.map(live, & &1.role) == ["system", "user", "assistant"]

      assert {:ok, %{appended: 1}} = Store.reconcile(id, root: dir)
      assert persisted_messages(id, dir) == [user_msg("u1"), assistant_msg("done")]
      assert {:ok, %{appended: 0}} = Store.reconcile(id, root: dir)

      GenServer.stop(agent)
    end

    test "drops a torn transcript tail before appending (C7)", %{tmp_dir: dir} do
      id = "rec-torn"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)
      write_messages(id, dir, [{:user, user_msg("u1"), 1}])

      # A crash mid-`write` left an unterminated, unparseable fragment. Appending straight after
      # it would splice two records onto one line and turn the transcript into an *interior*
      # malformed line, which every reader rejects.
      path = Store.transcript_path(id, root: dir)
      File.write!(path, File.read!(path) <> ~s({"v":1,"seq":2,"kind":"assis))

      assert {:ok, %{appended: 1}} =
               Store.reconcile(id, root: dir, messages: [user_msg("u1"), assistant_msg("a1")])

      # The torn fragment is gone and the transcript reads back cleanly.
      assert {:ok, records, meta} = Store.load_records(id, root: dir)
      assert meta[:truncated] == 0
      assert Enum.map(records, & &1["kind"]) == ["user", "assistant"]
      assert persisted_messages(id, dir) == [user_msg("u1"), assistant_msg("a1")]

      # …and a reconcile that has nothing to append leaves the torn tail alone.
      File.write!(path, File.read!(path) <> "{\"v\":1")

      assert {:ok, %{appended: 0}} =
               Store.reconcile(id, root: dir, messages: [user_msg("u1"), assistant_msg("a1")])
    end

    test "returns :unavailable when there is no live working set", %{tmp_dir: dir} do
      id = "rec-unavailable"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      # No `:messages` option and no registered agent for this id in the Registry.
      assert {:error, :unavailable} = Store.reconcile(id, root: dir)
      assert records(id, dir) == []
    end

    test "returns :unavailable for a non-list :messages option", %{tmp_dir: dir} do
      id = "rec-bad-opt"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)
      assert {:error, :unavailable} = Store.reconcile(id, root: dir, messages: :nope)
    end

    test "never creates a session that does not exist", %{tmp_dir: dir} do
      assert {:error, :not_found} =
               Store.reconcile("rec-absent", root: dir, messages: [user_msg("u1")])

      refute File.exists?(Store.session_dir("rec-absent", root: dir))
    end

    test "propagates transcript read errors without writing", %{tmp_dir: dir} do
      id = "rec-corrupt"
      assert :ok = Store.ensure_session(session_attrs(id: id), root: dir)

      File.write!(Store.transcript_path(id, root: dir), "{\"seq\":1}\nGARBAGE\n{\"seq\":3}\n")
      before = File.read!(Store.transcript_path(id, root: dir))

      assert {:error, :corrupt} = Store.reconcile(id, root: dir, messages: [user_msg("u1")])
      assert File.read!(Store.transcript_path(id, root: dir)) == before
    end
  end

  describe "kinds/0" do
    test "lists exactly the documented record kinds" do
      assert Store.kinds() ==
               ~w(user assistant tool status event compaction resume clear checkpoint)
    end
  end

  describe "Config Store accessors (§8)" do
    test "home/0 defaults to ~/.athanor and expands it" do
      with_clean_env(["ATHANOR_HOME"], fn ->
        assert Athanor.Config.home() == Path.expand("~/.athanor")
      end)
    end

    test "home/0 honours ATHANOR_HOME and :athanor, :home", %{tmp_dir: dir} do
      with_clean_env(["ATHANOR_HOME"], fn ->
        System.put_env("ATHANOR_HOME", dir)
        assert Athanor.Config.home() == Path.expand(dir)

        System.delete_env("ATHANOR_HOME")

        with_app_env(:home, Path.join(dir, "cfg"), fn ->
          assert Athanor.Config.home() == Path.expand(Path.join(dir, "cfg"))
        end)
      end)
    end

    test "store_enabled?/0 is true by default and ATHANOR_STORE=0 disables it" do
      with_clean_env(["ATHANOR_STORE"], fn ->
        assert Athanor.Config.store_enabled?() == true

        for falsy <- ["0", "false", "FALSE", "no", "off"] do
          System.put_env("ATHANOR_STORE", falsy)
          assert Athanor.Config.store_enabled?() == false
        end

        System.put_env("ATHANOR_STORE", "1")
        assert Athanor.Config.store_enabled?() == true
      end)
    end

    test "context_limit_tokens/0 defaults to 128_000 and honours the env var" do
      with_clean_env(["ATHANOR_CONTEXT_LIMIT_TOKENS"], fn ->
        assert Athanor.Config.context_limit_tokens() == 128_000

        System.put_env("ATHANOR_CONTEXT_LIMIT_TOKENS", "200000")
        assert Athanor.Config.context_limit_tokens() == 200_000

        System.put_env("ATHANOR_CONTEXT_LIMIT_TOKENS", "nonsense")
        assert Athanor.Config.context_limit_tokens() == 128_000
      end)
    end

    test "compaction ratio accessors default, parse, and reject out-of-range values" do
      with_clean_env(
        ["ATHANOR_COMPACTION_THRESHOLD", "ATHANOR_COMPACTION_KEEP_FRACTION"],
        fn ->
          assert Athanor.Config.compaction_threshold() == 0.8
          assert Athanor.Config.compaction_keep_fraction() == 0.4

          System.put_env("ATHANOR_COMPACTION_THRESHOLD", "0.9")
          System.put_env("ATHANOR_COMPACTION_KEEP_FRACTION", "0.25")

          assert Athanor.Config.compaction_threshold() == 0.9
          assert Athanor.Config.compaction_keep_fraction() == 0.25

          for bad <- ["0", "-1", "1.5", "wat", ""] do
            System.put_env("ATHANOR_COMPACTION_THRESHOLD", bad)
            assert Athanor.Config.compaction_threshold() == 0.8
          end
        end
      )
    end

    test "compaction message-count accessors and max_turns default and honour env vars" do
      with_clean_env(
        [
          "ATHANOR_COMPACTION_MAX_MESSAGES",
          "ATHANOR_COMPACTION_KEEP_MESSAGES",
          "ATHANOR_MAX_TURNS"
        ],
        fn ->
          assert Athanor.Config.compaction_max_messages() == 400
          assert Athanor.Config.compaction_keep_messages() == 200
          assert Athanor.Config.max_turns() == :infinity

          System.put_env("ATHANOR_COMPACTION_MAX_MESSAGES", "350")
          System.put_env("ATHANOR_COMPACTION_KEEP_MESSAGES", "150")
          System.put_env("ATHANOR_MAX_TURNS", "50")

          assert Athanor.Config.compaction_max_messages() == 350
          assert Athanor.Config.compaction_keep_messages() == 150
          assert Athanor.Config.max_turns() == 50

          System.put_env("ATHANOR_MAX_TURNS", "infinity")
          assert Athanor.Config.max_turns() == :infinity
        end
      )
    end

    test "transcript_sync/0 defaults to :per_record and only accepts :batched otherwise" do
      with_clean_env(["ATHANOR_TRANSCRIPT_SYNC"], fn ->
        assert Athanor.Config.transcript_sync() == :per_record

        System.put_env("ATHANOR_TRANSCRIPT_SYNC", "batched")
        assert Athanor.Config.transcript_sync() == :batched

        System.put_env("ATHANOR_TRANSCRIPT_SYNC", "per_record")
        assert Athanor.Config.transcript_sync() == :per_record

        System.put_env("ATHANOR_TRANSCRIPT_SYNC", "sometimes")
        assert Athanor.Config.transcript_sync() == :per_record
      end)
    end
  end

  # -- reconcile/2 helpers ------------------------------------------------------

  defp user_msg(text), do: %{"role" => "user", "content" => text}
  defp assistant_msg(text), do: %{"role" => "assistant", "content" => text, "tool_calls" => []}

  defp records(id, root) do
    {:ok, records, _meta} = Store.load_records(id, root: root)
    records
  end

  defp persisted_messages(id, root) do
    id
    |> records(root)
    |> Enum.filter(&(&1["kind"] in ["user", "assistant", "tool"]))
    |> Enum.map(& &1["payload"])
  end

  defp write_messages(id, root, records) do
    dir = Store.session_dir(id, root: root)

    Enum.each(records, fn {kind, payload, seq} ->
      assert :ok =
               Transcript.append(
                 dir,
                 Transcript.new_record(kind, payload, seq: seq, session_id: id)
               )
    end)
  end

  # The agent goes `:idle` via a status event on its own topic; polling `get_state/1` keeps the
  # reconcile test independent of the PubSub topic shape.
  defp wait_until_idle(agent, attempts \\ 200)

  defp wait_until_idle(_agent, 0), do: flunk("agent never became idle")

  defp wait_until_idle(agent, attempts) do
    case Athanor.Agent.get_state(agent).status do
      :idle -> :ok
      _other -> Process.sleep(10) && wait_until_idle(agent, attempts - 1)
    end
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)

  # `System.put_env/2` is process-global, so every env mutation is undone on exit; the store
  # suite is the only module that touches these Athanor Store vars.
  defp with_clean_env(vars, fun) do
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)
    on_exit(fn -> Enum.each(previous, fn {var, value} -> restore_env(var, value) end) end)
    fun.()
  end

  defp with_app_env(key, value, fun) do
    previous = Application.get_env(:athanor, key)
    Application.put_env(:athanor, key, value)
    on_exit(fn -> restore_app_env(key, previous) end)
    fun.()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:athanor, key)
  defp restore_app_env(key, value), do: Application.put_env(:athanor, key, value)
end
