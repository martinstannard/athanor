defmodule Athanor.Store.RecorderTest do
  # `async: false`: the Recorder subscribes to the node-global `"deck:events"` topic of a
  # `:duplicate` Registry, and these tests publish into it. Running them alongside other
  # subscribers would make the assertions order-dependent (plan §9.6).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Athanor.{Bus, Store}
  alias Athanor.Store.{Handoff, Recorder, Transcript}

  @moduletag :tmp_dir

  @id "rec-worker-1"
  @meta %{
    id: @id,
    title: "Audit Worker",
    role: :worker,
    parent_id: "conductor-main",
    model: "deepseek-v4.1-flash",
    status: :idle,
    session_id: "ses_athanor_ab12cd34ef56"
  }

  # Every test starts its own Recorder against `tmp_dir` with `name: nil`: the
  # application-supervised singleton must not be fought over for the name, and nothing may be
  # written outside `tmp_dir` (plan §9.1).
  defp start_recorder!(dir), do: start_recorder!(dir, [])

  defp start_recorder!(dir, opts) do
    start_supervised!({Recorder, Keyword.merge([root: dir, name: nil], opts)})
  end

  # `stats/1` is a `GenServer.call`, so it is handled after every event already sent to the
  # Recorder: it doubles as a barrier, letting a test assert a settled state without sleeping.
  defp session_stats(pid, id), do: Recorder.stats(pid).sessions[id]

  # A settled-state barrier: polls the counter via the (serialising) `stats/1` call until the
  # debounce window has closed and its pending status is cleared.
  defp wait_for_status_flush(pid, id, attempts) do
    stats = session_stats(pid, id)

    cond do
      stats.pending_status == nil and stats.meta_writes > 1 -> stats
      attempts == 0 -> flunk("status never flushed for #{id}: #{inspect(stats)}")
      true -> Process.sleep(50) && wait_for_status_flush(pid, id, attempts - 1)
    end
  end

  defp publish_started(id \\ @id), do: Bus.publish_event(id, nil, {:session_started, @meta})

  defp records(id, dir) do
    assert {:ok, records, meta} = Store.load_records(id, root: dir)
    {records, meta}
  end

  describe "the write path (plan §5.1, C1)" do
    test "{:session_started, _} then {:message, _} writes meta.json + transcript.jsonl", %{
      tmp_dir: dir
    } do
      pid = start_recorder!(dir)
      publish_started()

      # A realistic turn: the exact message maps `Athanor.Agent.record_messages/2` publishes.
      messages = [
        %{role: "user", content: "What is inside secret.txt?"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: ~s({"path":"secret.txt"})}
            }
          ]
        },
        %{role: "tool", tool_call_id: "call_1", content: "alchemical_gold"},
        %{role: "assistant", content: "The secret is alchemical_gold.", tool_calls: []}
      ]

      Enum.each(messages, &Bus.publish_message(@id, nil, &1))

      assert %{records: 4, seq: 4, open?: true} = session_stats(pid, @id)

      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["id"] == @id
      assert meta["title"] == "Audit Worker"
      assert meta["role"] == "worker"
      assert meta["parent_id"] == "conductor-main"
      assert meta["model"] == "deepseek-v4.1-flash"
      assert meta["session_id"] == "ses_athanor_ab12cd34ef56"
      assert meta["last_status"] == "idle"

      {records, read_meta} = records(@id, dir)
      assert read_meta[:truncated] == 0
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3, 4]
      assert Enum.map(records, & &1["kind"]) == ["user", "assistant", "tool", "assistant"]
      assert Enum.all?(records, &(&1["session_id"] == @id))
      assert Enum.all?(records, &(&1["v"] == 1))

      # The exact message maps are persisted verbatim (C1): nothing is reconstructed, so the
      # `tool_call.id` and the JSON-string `arguments` survive a resume round trip.
      assert Enum.map(records, & &1["payload"]) == [
               %{"role" => "user", "content" => "What is inside secret.txt?"},
               %{
                 "role" => "assistant",
                 "content" => "",
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{
                       "name" => "read_file",
                       "arguments" => ~s({"path":"secret.txt"})
                     }
                   }
                 ]
               },
               %{"role" => "tool", "tool_call_id" => "call_1", "content" => "alchemical_gold"},
               %{
                 "role" => "assistant",
                 "content" => "The secret is alchemical_gold.",
                 "tool_calls" => []
               }
             ]

      # One JSON object per line, newline-terminated: the append-only invariant (C7).
      raw = File.read!(Transcript.path(Store.session_dir(@id, root: dir)))
      assert String.ends_with?(raw, "\n")
      assert length(String.split(raw, "\n", trim: true)) == 4
    end

    test "a session's directory and meta.json are created lazily by its first record", %{
      tmp_dir: dir
    } do
      pid = start_recorder!(dir)

      # No {:session_started, _} was ever published for this id.
      Bus.publish_message("rec-lazy", nil, %{role: "user", content: "hello"})

      assert %{records: 1} = session_stats(pid, "rec-lazy")
      assert File.exists?(Store.meta_path("rec-lazy", root: dir))

      assert {:ok, [%{"kind" => "user"}], %{truncated: 0}} =
               Store.load_records("rec-lazy", root: dir)
    end
  end

  describe "filtering (plan §4.4, C2/C13)" do
    test "text_delta, turn_complete, tool_start/end, user_message and system are not persisted",
         %{
           tmp_dir: dir
         } do
      pid = start_recorder!(dir)
      publish_started()

      # A real record first: the noise below must not be appended *next to* it either.
      Bus.publish_message(@id, nil, %{role: "user", content: "count me"})

      # C2: one record per streamed token would explode the transcript.
      Bus.publish_event(@id, nil, {:text_delta, "The "})
      Bus.publish_event(@id, nil, {:text_delta, "secret"})
      # C13: redundant with the assistant message record.
      Bus.publish_event(@id, nil, {:turn_complete, "The secret is alchemical_gold."})
      # TUI-only activity events.
      Bus.publish_event(@id, nil, {:tool_start, "read_file", "{}"})
      Bus.publish_event(@id, nil, {:tool_end, "read_file", {:ok, "alchemical_gold"}})
      Bus.publish_event(@id, nil, {:user_message, "count me"})
      # C13: the system message is re-derived on resume, never persisted.
      Bus.publish_message(@id, nil, %{role: "system", content: "You are an Athanor Conductor"})
      # Unknown events are dropped too.
      Bus.publish_event(@id, nil, {:something_new, 1})
      Bus.publish_event(@id, nil, :some_other_bare_event)

      assert %{records: 1, seq: 1} = session_stats(pid, @id)

      {records, read_meta} = records(@id, dir)
      assert read_meta[:truncated] == 0
      assert [%{"kind" => "user", "seq" => 1}] = records
    end

    test "nothing at all is written when every event is filtered out", %{tmp_dir: dir} do
      pid = start_recorder!(dir)

      Bus.publish_event(@id, nil, {:text_delta, "x"})
      Bus.publish_message(@id, nil, %{role: "system", content: "prompt"})

      assert Recorder.stats(pid).sessions == %{}
      refute File.exists?(Store.session_dir(@id, root: dir))
    end
  end

  describe "subscribe-once (plan C-dup)" do
    test "the Recorder holds exactly one \"deck:events\" registry entry", %{tmp_dir: dir} do
      pid = start_recorder!(dir)

      # `Athanor.PubSub` is a :duplicate Registry, so a second `Bus.subscribe/1` would add a
      # second entry for this pid and deliver every event twice. Counting the entries is the
      # structural form of the guarantee; the test below is its behavioural form.
      entries = Registry.lookup(Athanor.PubSub, "deck:events")
      assert Enum.count(entries, fn {entry_pid, _value} -> entry_pid == pid end) == 1
    end

    test "one broadcast yields exactly one transcript record", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()

      # `Athanor.Bus.subscribe/1` registers on a :duplicate Registry and is therefore not
      # idempotent: a second subscription in `init/1` would deliver this one message twice and
      # write two records.
      Bus.publish_message(@id, nil, %{role: "user", content: "once"})

      assert %{records: 1} = session_stats(pid, @id)

      raw = File.read!(Transcript.path(Store.session_dir(@id, root: dir)))
      assert length(String.split(raw, "\n", trim: true)) == 1
    end
  end

  describe "audit records (plan §4.1)" do
    test "error, cancelled and child_done are recorded as kind \"event\"", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()

      # A reason the JSON encoder cannot represent directly: `sanitise/1` must keep the write
      # from raising and taking the Recorder down with it.
      Bus.publish_event(@id, nil, {:error, {:econnrefused, "unreachable"}})
      Bus.publish_event(@id, nil, :cancelled)

      Bus.publish_event(@id, nil, {
        :child_done,
        %{child_id: "worker-2", title: "Docs", status: "ok", summary: "all good"}
      })

      assert %{records: 3} = session_stats(pid, @id)

      {records, _meta} = records(@id, dir)
      assert Enum.map(records, & &1["kind"]) == ["event", "event", "event"]
      assert Enum.map(records, & &1["payload"]["event"]) == ["error", "cancelled", "child_done"]
      assert records |> hd() |> get_in(["payload", "data", "reason"]) =~ "econnrefused"
      assert List.last(records)["payload"]["data"]["child_id"] == "worker-2"

      # A terminal transition bypasses the debounce (§5.1).
      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["last_status"] == "error"
    end
  end

  describe "resume markers (plan §4.3, C12)" do
    test "{:resume, %{from: v}} appends a kind \"resume\" record", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()
      Bus.publish_message(@id, nil, %{role: "user", content: "before the restart"})

      Bus.publish_event(@id, nil, {:resume, %{from: 1}})

      assert %{records: 2} = session_stats(pid, @id)

      {records, %{truncated: 0}} = records(@id, dir)
      assert Enum.map(records, & &1["kind"]) == ["user", "resume"]
      assert List.last(records)["payload"] == %{"from" => 1}

      # A resume marker is an audit record only: it must not disturb the handoff or the
      # compaction counter.
      refute File.exists?(Store.handoff_path(@id, root: dir))
      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["compaction"] == nil
    end
  end

  describe "clear markers (design §7.4, /clear)" do
    test "{:context_cleared, _} appends a kind \"clear\" record and nothing else", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()
      Bus.publish_message(@id, nil, %{role: "user", content: "before the clear"})

      Bus.publish_event(@id, nil, {:context_cleared, %{}})

      assert %{records: 2} = session_stats(pid, @id)

      {records, %{truncated: 0}} = records(@id, dir)
      assert Enum.map(records, & &1["kind"]) == ["user", "clear"]

      marker = List.last(records)
      assert marker["payload"]["event"] == "clear"
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(marker["payload"]["ts"])

      # Like the resume marker: an audit record only — no handoff rewrite, no compaction bump.
      refute File.exists?(Store.handoff_path(@id, root: dir))
      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["compaction"] == nil
    end

    test "a clear marker for a path-unsafe session id writes nothing", %{tmp_dir: dir} do
      pid = start_recorder!(dir)

      Bus.publish_event("../escape", nil, {:context_cleared, %{}})

      assert Recorder.stats(pid).sessions == %{}
      refute File.exists?(Path.join(dir, "escape"))
      refute File.exists?(Path.expand(Path.join(dir, "../escape")))
    end
  end

  describe "compaction persistence (plan §4.3, §5.4)" do
    test "{:compaction, %{summary, kept, dropped}} appends a marker, rewrites HANDOFF.md and bumps meta",
         %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()

      # A realistic prefix: a user prompt, an assistant tool call and its result, so the handoff
      # has something to summarise.
      Bus.publish_message(@id, nil, %{role: "user", content: "Audit all files under lib/"})

      Bus.publish_message(@id, nil, %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{
            id: "call_1",
            type: "function",
            function: %{name: "read_file", arguments: ~s({"path":"mix.exs"})}
          }
        ]
      })

      Bus.publish_message(@id, nil, %{
        role: "tool",
        tool_call_id: "call_1",
        content: "elixir ~> 1.19"
      })

      Bus.publish_event(@id, nil, {:compaction, %{summary: "S", kept: 2, dropped: 5}})

      # (a) the transcript carries an explicit compaction marker, and nothing was truncated.
      assert %{records: 4} = session_stats(pid, @id)

      {records, %{truncated: 0}} = records(@id, dir)
      assert Enum.map(records, & &1["kind"]) == ["user", "assistant", "tool", "compaction"]

      marker = List.last(records)
      assert marker["payload"]["summary"] == "S"
      assert marker["payload"]["kept"] == 2
      assert marker["payload"]["dropped"] == 5
      assert is_binary(marker["payload"]["ts"])

      # (b) HANDOFF.md was rewritten from the session + the whole transcript, atomically.
      handoff = Store.handoff_path(@id, root: dir)
      assert File.exists?(handoff)
      refute File.exists?(Handoff.tmp_path(handoff))

      doc = File.read!(handoff)
      assert doc =~ "# Handoff — Audit Worker (#{@id})"
      assert doc =~ "## Goal\nAudit all files under lib/"

      # The handoff was rendered from the *transcript*, not from the agent's compacted working
      # set: the tool call and its result — the turns a compaction just dropped — are still in
      # the summary.
      assert doc =~ "## Completed steps"
      assert doc =~ ~s|- [x] read_file("mix.exs") → elixir ~> 1.19|
      assert doc =~ "compacted 5 messages → kept 2 (summary: S)"

      assert {:ok, parsed} = Handoff.parse(doc)
      assert Enum.any?(parsed.compaction_log, &(&1 =~ "summary: S"))

      # (c) meta.json#compaction was bumped, atomically.
      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      compaction = meta["compaction"]
      assert compaction["count"] == 1
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(compaction["last_at"])

      assert compaction["transcript_bytes"] ==
               File.stat!(Transcript.path(Store.session_dir(@id, root: dir))).size

      refute File.exists?(Store.meta_path(@id, root: dir) <> ".tmp")

      # A second compaction increments the counter rather than restarting it.
      Bus.publish_event(@id, nil, {:compaction, %{summary: "S2", kept: 1, dropped: 3}})

      assert %{records: 5} = session_stats(pid, @id)

      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["compaction"]["count"] == 2

      {records, %{truncated: 0}} = records(@id, dir)
      assert Enum.map(records, & &1["kind"]) |> List.last() == "compaction"
      assert length(records) == 5
    end

    test "compaction never truncates the transcript", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()

      Enum.each(1..8, fn n ->
        Bus.publish_message(@id, nil, %{role: "user", content: "m#{n}"})
      end)

      Bus.publish_event(
        @id,
        nil,
        {:compaction, %{summary: "everything summarised", kept: 2, dropped: 6}}
      )

      assert %{records: 9} = session_stats(pid, @id)

      # Every message record is still on disk, in order, and the file is still append-only and
      # newline-terminated: the compaction marker shrank HANDOFF.md and the in-memory working
      # set, never the transcript.
      {records, %{truncated: 0}} = records(@id, dir)
      assert length(records) == 9

      assert records |> Enum.take(8) |> Enum.map(& &1["payload"]["content"]) ==
               Enum.map(1..8, &"m#{&1}")

      assert List.last(records)["kind"] == "compaction"

      assert File.read!(Transcript.path(Store.session_dir(@id, root: dir)))
             |> String.ends_with?("\n")

      # `seq` stays monotonic across the marker, so a resumed reader keeps the whole history.
      assert Enum.map(records, & &1["seq"]) == Enum.to_list(1..9)
    end

    test "a compaction for a path-unsafe session id writes nothing at all", %{tmp_dir: dir} do
      pid = start_recorder!(dir)

      Bus.publish_event("../escape", nil, {:compaction, %{summary: "S", kept: 1, dropped: 1}})

      # The id gate covers all three steps: no marker, no HANDOFF.md outside the root, no meta.
      assert Recorder.stats(pid).sessions == %{}
      refute File.exists?(Path.join(dir, "escape"))
      refute File.exists?(Path.expand(Path.join(dir, "../escape")))
    end
  end

  describe "status debounce (plan §5.1)" do
    test "a burst of {:status, _} rewrites meta.json once, then settles on the last value", %{
      tmp_dir: dir
    } do
      pid = start_recorder!(dir)
      publish_started()

      # `{:session_started, _}` is the one write before the burst.
      assert %{meta_writes: 1, pending_status: nil} = session_stats(pid, @id)

      Enum.each([:streaming, :executing_tools, :streaming, :idle, :streaming], fn status ->
        Bus.publish_event(@id, nil, {:status, status})
      end)

      # Barrier: all five statuses have been seen, none of them has hit the disk individually.
      assert %{meta_writes: 1, pending_status: :streaming} = session_stats(pid, @id)

      # The window (500 ms) closes.
      Process.sleep(700)

      assert %{meta_writes: 2, pending_status: nil} = session_stats(pid, @id)

      # Exactly one rewrite for the burst, and it carries the last status of the burst.
      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["last_status"] == "streaming"
    end

    test "terminate/2 flushes a status still inside its window", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      publish_started()

      Bus.publish_event(@id, nil, {:status, :executing_tools})
      assert %{pending_status: :executing_tools} = session_stats(pid, @id)

      # Stop before the 500 ms window closes: an orderly shutdown must not lose the status.
      assert :ok = stop_supervised(Recorder)

      refute Process.alive?(pid)

      assert {:ok, meta} = Store.read_meta(@id, root: dir)
      assert meta["last_status"] == "executing_tools"
    end
  end

  describe "crash safety (plan §5.2, C7)" do
    test "a torn trailing line is repaired before the next append", %{tmp_dir: dir} do
      id = "rec-torn"
      assert :ok = Store.ensure_session([id: id, title: "Torn"], root: dir)

      path = Store.transcript_path(id, root: dir)

      good =
        JSON.encode!(
          Transcript.new_record("user", %{"role" => "user", "content" => "a"},
            seq: 1,
            session_id: id
          )
        )

      # Simulate a crash mid-`write`: a partial record with no trailing newline.
      File.write!(path, good <> "\n" <> ~s({"v":1,"seq":2,"kind":"assis))

      pid = start_recorder!(dir)
      Bus.publish_message(id, nil, %{role: "user", content: "b"})

      # The torn fragment was dropped, `seq` continued after the last good record, and the new
      # record did not get spliced onto the fragment (which would make the file *interior*
      # -corrupt and unreadable).
      assert %{records: 1, seq: 2} = session_stats(pid, id)

      assert {:ok, records, %{truncated: 0}} = Store.load_records(id, root: dir)
      assert Enum.map(records, & &1["seq"]) == [1, 2]
      assert Enum.map(records, & &1["kind"]) == ["user", "user"]
      assert File.read!(path) |> String.ends_with?("\n")
    end

    test "a final record that lost only its newline is kept, and seq continues past it", %{
      tmp_dir: dir
    } do
      id = "rec-recomplete"
      assert :ok = Store.ensure_session([id: id, title: "Kept"], root: dir)

      path = Store.transcript_path(id, root: dir)

      first =
        JSON.encode!(
          Transcript.new_record("user", %{"role" => "user", "content" => "a"},
            seq: 1,
            session_id: id
          )
        )

      second =
        JSON.encode!(
          Transcript.new_record("assistant", %{"role" => "assistant", "content" => "b"},
            seq: 2,
            session_id: id
          )
        )

      # The write reached the page cache before the crash; only the separator is missing.
      File.write!(path, first <> "\n" <> second)

      pid = start_recorder!(dir)
      Bus.publish_message(id, nil, %{role: "tool", tool_call_id: "c", content: "c"})

      # seq resumed after the recovered record rather than restarting at 1.
      assert %{records: 1, seq: 3} = session_stats(pid, id)

      assert {:ok, records, %{truncated: 0}} = Store.load_records(id, root: dir)
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3]
    end

    test "meta.json stays valid JSON and the transcript is still readable after churn", %{
      tmp_dir: dir
    } do
      pid = start_recorder!(dir)
      publish_started()

      Enum.each(1..20, fn n ->
        Bus.publish_message(@id, nil, %{role: "user", content: "m#{n}"})
        Bus.publish_event(@id, nil, {:status, Enum.random([:streaming, :executing_tools, :idle])})
      end)

      assert %{records: 20} = session_stats(pid, @id)

      # Wait for the debounce window to close (the flush that carries the last status), so the
      # `.tmp`-file assertion below cannot race a rename in progress.
      wait_for_status_flush(pid, @id, 40)

      # Every meta.json write is an atomic tmp + rename, so a reader never sees a partial file.
      raw = File.read!(Store.meta_path(@id, root: dir))
      assert {:ok, %{} = decoded} = JSON.decode(raw)
      assert decoded["id"] == @id

      assert {:ok, records, %{truncated: 0}} = Store.load_records(@id, root: dir)
      assert length(records) == 20
      refute File.exists?(Store.meta_path(@id, root: dir) <> ".tmp")
    end

    test "a restarted Recorder re-subscribes once and continues the session's seq", %{
      tmp_dir: dir
    } do
      pid = start_recorder!(dir)
      publish_started()
      Bus.publish_message(@id, nil, %{role: "user", content: "before"})
      Bus.publish_message(@id, nil, %{role: "assistant", content: "reply", tool_calls: []})
      assert %{records: 2, seq: 2} = session_stats(pid, @id)

      # Simulate a crash/restart: the fresh process knows nothing, subscribes once for itself and
      # lazily re-opens the handle (§2.3). `seq` must continue rather than restart, or a resume
      # would interleave the two runs.
      assert :ok = stop_supervised(Recorder)
      new_pid = start_recorder!(dir)
      refute new_pid == pid

      assert Enum.count(Registry.lookup(Athanor.PubSub, "deck:events"), fn {p, _} ->
               p == new_pid
             end) ==
               1

      Bus.publish_message(@id, nil, %{role: "user", content: "after"})

      assert %{records: 1, seq: 3} = session_stats(new_pid, @id)

      assert {:ok, records, %{truncated: 0}} = Store.load_records(@id, root: dir)
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3]
      assert Enum.map(records, & &1["payload"]["content"]) == ["before", "reply", "after"]
    end
  end

  describe "id validation (defence in depth)" do
    test "a record for a path-unsafe session id is dropped, not written outside the root", %{
      tmp_dir: dir
    } do
      pid = start_recorder!(dir)

      # The id doubles as a directory name; `Athanor.Agent` validates before starting, but a store
      # must not depend on a publisher having done so.
      Bus.publish_event("../escape", nil, {:session_started, %{id: "../escape", role: :worker}})
      Bus.publish_message("../escape", nil, %{role: "user", content: "nope"})

      assert Recorder.stats(pid).sessions == %{}
      refute File.exists?(Path.join(dir, "escape"))
      refute File.exists?(Path.expand(Path.join(dir, "../escape")))
    end
  end

  describe "bounded handles (open-fd LRU cap)" do
    test "more sessions than the cap still get every record, and the cap holds", %{tmp_dir: dir} do
      # A cap of 2 with 5 sessions forces an eviction on almost every record; the assertion is
      # that a closed handle is invisible in the transcript (reopened lazily, appended at EOF).
      pid = start_recorder!(dir, max_open_fds: 2)

      assert %{max_open_fds: 2, open_fds: 0} = Recorder.stats(pid)

      ids = Enum.map(1..5, &"rec-cap-#{&1}")

      # Two records per session, round-robin: every session is touched again *after* its handle
      # was evicted, so each record path crosses a close/reopen boundary.
      Enum.each(1..2, fn round ->
        Enum.each(ids, fn id ->
          Bus.publish_message(id, nil, %{role: "user", content: "r#{round}"})

          stats = Recorder.stats(pid)
          assert stats.open_fds <= 2
          assert Enum.count(stats.sessions, fn {_id, s} -> s.open? end) == stats.open_fds
        end)
      end)

      # The cap is not merely respected in transit: it is what the settled state holds.
      assert %{open_fds: 2, max_open_fds: 2} = Recorder.stats(pid)

      Enum.each(ids, fn id ->
        assert {:ok, records, %{truncated: 0}} = Store.load_records(id, root: dir)

        # Both rounds are on disk, in arrival order and with monotonic seq: an eviction never
        # lost or reordered a line.
        assert Enum.map(records, & &1["payload"]["content"]) == ["r1", "r2"]
        assert Enum.map(records, & &1["seq"]) == [1, 2]

        path = Transcript.path(Store.session_dir(id, root: dir))
        assert File.read!(path) |> String.ends_with?("\n")
      end)
    end

    test "the least recently *used* handle is the one evicted", %{tmp_dir: dir} do
      pid = start_recorder!(dir, max_open_fds: 2)

      # a and b fill the cap; then b and then a are used again, so `b` is the coldest when `c`
      # arrives. A cap that evicted by insertion order would drop `a` instead.
      Bus.publish_message("rec-a", nil, %{role: "user", content: "a1"})
      Bus.publish_message("rec-b", nil, %{role: "user", content: "b1"})
      Bus.publish_message("rec-b", nil, %{role: "user", content: "b2"})
      Bus.publish_message("rec-a", nil, %{role: "user", content: "a2"})

      assert %{open?: true} = session_stats(pid, "rec-a")
      assert %{open?: true} = session_stats(pid, "rec-b")

      Bus.publish_message("rec-c", nil, %{role: "user", content: "c1"})

      stats = Recorder.stats(pid)
      assert stats.open_fds == 2
      assert stats.sessions["rec-a"].open?
      assert stats.sessions["rec-c"].open?
      refute stats.sessions["rec-b"].open?

      # …and the evicted session keeps its history: its next record reopens and continues `seq`.
      Bus.publish_message("rec-b", nil, %{role: "user", content: "b3"})

      assert %{records: 3, seq: 3, open?: true} = session_stats(pid, "rec-b")

      assert {:ok, records, %{truncated: 0}} = Store.load_records("rec-b", root: dir)
      assert Enum.map(records, & &1["payload"]["content"]) == ["b1", "b2", "b3"]
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3]
    end

    test "the default cap is Config.recorder_max_open_fds/0", %{tmp_dir: dir} do
      pid = start_recorder!(dir)

      assert %{max_open_fds: cap} = Recorder.stats(pid)
      assert cap == Athanor.Config.recorder_max_open_fds()
      assert cap >= 1
    end
  end

  describe "advisory single-writer lock" do
    test "init writes the lock naming this os_pid, terminate removes it", %{tmp_dir: dir} do
      pid = start_recorder!(dir)
      lock = Path.join(Store.sessions_root(root: dir), ".recorder.lock")

      assert File.exists?(lock)

      assert {:ok, %{"os_pid" => os_pid, "node" => node_name, "started_at" => started_at}} =
               lock |> File.read!() |> JSON.decode()

      assert os_pid == System.pid()
      assert node_name == to_string(node())
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(started_at)

      assert :ok = stop_supervised(Recorder)
      refute Process.alive?(pid)

      # Best-effort cleanup: an orderly stop leaves no stale lock behind.
      refute File.exists?(lock)
    end

    test "a lock naming a foreign live pid logs a warning but does not refuse to start", %{
      tmp_dir: dir
    } do
      lock = Path.join(Store.sessions_root(root: dir), ".recorder.lock")
      File.mkdir_p!(Path.dirname(lock))

      # A real, live, *other* OS process: the warning must fire on the stated condition — a
      # different pid that is still alive — not on the mere presence of a lock file. A real child
      # of this user is used rather than pid 1 because probing a process owned by another user can
      # legitimately fail with EPERM, making "alive" indistinguishable from "gone" for `kill -0`.
      port =
        Port.open(
          {:spawn_executable, System.find_executable("sleep")},
          [:binary, args: ["30"]]
        )

      {:os_pid, foreign} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", [to_string(foreign)]) end)

      File.write!(
        lock,
        JSON.encode!(%{
          node: "foreign@node",
          os_pid: to_string(foreign),
          started_at: "2026-01-01T00:00:00Z"
        })
      )

      log =
        capture_log([level: :warning], fn ->
          pid = start_recorder!(dir)
          send(self(), {:recorder, pid})
        end)

      assert_received {:recorder, pid}
      assert Process.alive?(pid)
      assert log =~ "another Recorder may be writing"
      assert log =~ Store.sessions_root(root: dir)
      assert log =~ to_string(foreign)

      # The instance started anyway and replaced the foreign lock with its own.
      assert {:ok, %{"os_pid" => os_pid, "node" => _node}} = lock |> File.read!() |> JSON.decode()
      assert os_pid == System.pid()

      publish_started()
      Bus.publish_message(@id, nil, %{role: "user", content: "still writing"})

      assert %{records: 1} = session_stats(pid, @id)

      assert {:ok, [%{"payload" => %{"content" => "still writing"}}], %{truncated: 0}} =
               Store.load_records(@id, root: dir)
    end

    test "a lock naming a dead pid is stale and overwritten silently", %{tmp_dir: dir} do
      lock = Path.join(Store.sessions_root(root: dir), ".recorder.lock")
      File.mkdir_p!(Path.dirname(lock))

      # A pid far above the maximum (2^22 on Linux, 99998 on macOS) cannot be running.
      File.write!(
        lock,
        JSON.encode!(%{
          node: "crashed@node",
          os_pid: "4194303",
          started_at: "2026-01-01T00:00:00Z"
        })
      )

      log =
        capture_log([level: :warning], fn ->
          _ = start_recorder!(dir)
          send(self(), {:started, true})
        end)

      assert_received {:started, true}
      refute log =~ "another Recorder may be writing"

      assert {:ok, %{"os_pid" => os_pid}} = lock |> File.read!() |> JSON.decode()
      assert os_pid == System.pid()
    end
  end

  describe "application wiring (plan §2.3)" do
    test "the application supervises the Recorder as its last child, :permanent", %{} do
      # `which_children/1` lists children in *reverse* start order, so the last-started child
      # (`Athanor.Store.Recorder`, per §2.3 — every other subsystem may publish before it is
      # listening) is the head of the list.
      assert [{Recorder, pid, :worker, [Recorder]} | rest] =
               Supervisor.which_children(Athanor.Supervisor)

      assert is_pid(pid)

      assert Enum.map(rest, &elem(&1, 0)) == [
               Athanor.GoalSupervisor,
               Athanor.AgentSupervisor,
               Athanor.Worktree.Server,
               Athanor.ToolGuard,
               Athanor.GoalRegistry,
               Athanor.PubSub,
               Athanor.AgentRegistry
             ]

      {:ok, spec} = :supervisor.get_childspec(Athanor.Supervisor, Recorder)
      assert spec.restart == :permanent

      # Under `mix test` the singleton must not persist fixtures into a real store (§9.1).
      assert %{enabled?: false} = Recorder.stats(pid)

      # …and with `root:` absent it resolves the configured home, so a real run writes there.
      assert Recorder.stats(pid).root == Athanor.Config.home()
    end
  end
end
