defmodule Athanor.Store.ResumeTest do
  # `async: false`: this module drives real agents and a Store Recorder through the node-global
  # `"deck:events"` PubSub topic, so it must not interleave with other publishers (plan §9.7).
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, Orchestrator, Store}
  alias Athanor.Store.{Recorder, Transcript}

  @moduletag :tmp_dir

  # -- round-trip fidelity (the core test, plan §9.7) ---------------------------

  test "resume_all/1 restores the exact conversation history from disk", %{tmp_dir: dir} do
    recorder = start_supervised!({Recorder, [root: dir, name: nil]})
    File.write!(Path.join(dir, "note.txt"), "alchemical_gold\n")
    Bus.subscribe("deck:events")

    conductor_id = "resume-conductor"
    worker_id = "resume-worker"

    conductor_llm = fn _messages, _tools, _pid ->
      {:ok, %{role: "assistant", content: "Conductor ready.", tool_calls: []}}
    end

    # A real two-turn tool loop: the first call requests `read_file`, the second finishes.
    worker_llm = fn messages, _tools, _pid ->
      if Enum.any?(messages, &(message_role(&1) == "tool")) do
        {:ok,
         %{
           role: "assistant",
           content: "Read the note.\n===ATHANOR_DONE=== status=ok summary=read the note",
           tool_calls: []
         }}
      else
        {:ok,
         %{
           role: "assistant",
           content: "",
           tool_calls: [
             %{
               id: "call_read_note",
               type: "function",
               function: %{name: "read_file", arguments: ~s({"path":"note.txt"})}
             }
           ]
         }}
      end
    end

    {:ok, ^conductor_id, conductor_pid} =
      Orchestrator.spawn_session(
        id: conductor_id,
        role: :conductor,
        title: "Resume Conductor",
        cd: dir,
        llm_fn: conductor_llm
      )

    {:ok, ^worker_id, worker_pid} =
      Orchestrator.spawn_session(
        id: worker_id,
        role: :worker,
        parent_id: conductor_id,
        title: "Resume Worker",
        cd: dir,
        llm_fn: worker_llm,
        # Silence the [DONE] wakeup so the conductor's history stays a single clean turn.
        notify_parent_on_done: false
      )

    Orchestrator.send_session(conductor_id, "hello conductor")
    Orchestrator.send_session(worker_id, "please read note.txt")

    assert_receive {:agent_event, ^conductor_id, {:turn_complete, _reply}}, 5_000
    assert_receive {:agent_event, ^worker_id, {:turn_complete, _reply}}, 5_000

    conductor_messages = Agent.get_state(conductor_pid).messages
    worker_messages = Agent.get_state(worker_pid).messages

    # system + user + assistant(tool_calls) + tool + assistant
    assert Enum.map(worker_messages, &message_role/1) ==
             ["system", "user", "assistant", "tool", "assistant"]

    # Barrier: every `{:message, _}` published above has been durably written.
    wait_for_records(recorder, conductor_id, persisted_count(conductor_messages))
    wait_for_records(recorder, worker_id, persisted_count(worker_messages))

    # Tear the live sessions down, then rehydrate purely from disk.
    stop_session(conductor_pid)
    stop_session(worker_pid)

    assert {:ok, ids, []} = Orchestrator.resume_all(root: dir)

    assert conductor_id in ids
    assert worker_id in ids

    assert Enum.find_index(ids, &(&1 == conductor_id)) <
             Enum.find_index(ids, &(&1 == worker_id))

    resumed_conductor = resumed_messages(conductor_id)
    resumed_worker = resumed_messages(worker_id)

    # Exact fidelity: same order, same tool_call ids, same arguments strings. The captured
    # messages are atom-keyed (built by `Athanor.LLM.finalize_message/1`/the fake `llm_fn`),
    # the resumed ones string-keyed (they came back through JSON), so both sides are put through
    # one canonical JSON round trip before comparison.
    assert canonical(resumed_conductor) == canonical(conductor_messages)
    assert canonical(resumed_worker) == canonical(worker_messages)

    # Checked independently of the whole-list comparison: the tool-call identity survives
    # verbatim.
    tool_calls = resumed_worker |> canonical() |> Enum.flat_map(&Map.get(&1, "tool_calls", []))
    assert Enum.any?(tool_calls, &(&1["id"] == "call_read_note"))
    assert Enum.any?(tool_calls, &(&1["function"]["arguments"] == ~s({"path":"note.txt"})))

    # C3: exactly one system message after a resume (never two).
    assert Enum.count(resumed_conductor, &(message_role(&1) == "system")) == 1
    assert Enum.count(resumed_worker, &(message_role(&1) == "system")) == 1

    cleanup([conductor_id, worker_id])
  end

  # -- ordering (C8) ------------------------------------------------------------

  test "resumes parents before children and their parent resolves immediately", %{tmp_dir: dir} do
    Bus.subscribe("deck:events")

    conductor_id = "ord-conductor"
    child_1 = "ord-child-1"
    child_2 = "ord-child-2"

    assert :ok =
             Store.ensure_session(
               [id: conductor_id, role: :conductor, title: "C", cd: dir],
               root: dir
             )

    # Written out of id order to prove the ordering comes from `created_at`/`parent_id`, not a
    # directory scan.
    assert :ok =
             Store.ensure_session(
               [
                 id: child_2,
                 role: :worker,
                 parent_id: conductor_id,
                 title: "C2",
                 cd: dir,
                 created_at: ~U[2026-01-01 00:00:02Z]
               ],
               root: dir
             )

    assert :ok =
             Store.ensure_session(
               [
                 id: child_1,
                 role: :worker,
                 parent_id: conductor_id,
                 title: "C1",
                 cd: dir,
                 created_at: ~U[2026-01-01 00:00:01Z]
               ],
               root: dir
             )

    assert {:ok, ids, []} = Orchestrator.resume_all(root: dir)

    # Returned ids are in spawn order: the conductor before both of its children.
    assert ids == [conductor_id, child_1, child_2]

    # The parent is live and registered, so a restored child's `parent_id` resolves.
    assert {:ok, _conductor_pid} = Orchestrator.lookup(conductor_id)

    for child <- [child_1, child_2] do
      assert {:ok, child_pid} = Orchestrator.lookup(child)
      parent_id = Agent.get_state(child_pid).parent_id
      assert parent_id == conductor_id
      assert {:ok, _parent_pid} = Orchestrator.lookup(parent_id)
    end

    cleanup([conductor_id, child_1, child_2])
  end

  # -- versioning (§3.5) --------------------------------------------------------

  test "skips an unsupported version without crashing, and loads a version 0 session", %{
    tmp_dir: dir
  } do
    future = "resume-future"
    legacy = "resume-legacy"

    File.mkdir_p!(Store.session_dir(future, root: dir))

    File.write!(
      Store.meta_path(future, root: dir),
      JSON.encode!(%{"version" => 99, "id" => future, "role" => "worker"})
    )

    # A pre-versioning fixture: shape is a superset of v1's required fields, so it is loadable.
    File.mkdir_p!(Store.session_dir(legacy, root: dir))

    File.write!(
      Store.meta_path(legacy, root: dir),
      JSON.encode!(%{"version" => 0, "id" => legacy, "role" => "conductor", "cd" => dir})
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, ids, skipped} = Orchestrator.resume_all(root: dir)

        refute future in ids
        assert legacy in ids

        assert %{id: ^future, reason: {:unsupported_version, 99}} =
                 Enum.find(skipped, &(&1.id == future))
      end)

    # `Store.list/1` logged the skip rather than raising.
    assert log =~ future
    assert log =~ "unsupported_version"

    cleanup([legacy])
  end

  # -- single-id path -----------------------------------------------------------

  test "resume_session/2 rehydrates one session and round-trips its session_id (C4)", %{
    tmp_dir: dir
  } do
    id = "single-conductor"

    assert :ok =
             Store.ensure_session(
               [
                 id: id,
                 role: :conductor,
                 title: "Single",
                 cd: dir,
                 session_id: "ses_athanor_single"
               ],
               root: dir
             )

    sdir = Store.session_dir(id, root: dir)

    records = [
      {"user", %{"role" => "user", "content" => "hi"}, 1},
      {"assistant",
       %{
         "role" => "assistant",
         "content" => "hello",
         "tool_calls" => [
           %{
             "id" => "call_1",
             "type" => "function",
             "function" => %{"name" => "bash", "arguments" => ~s({"command":"true"})}
           }
         ]
       }, 2},
      {"tool", %{"role" => "tool", "tool_call_id" => "call_1", "content" => ""}, 3},
      {"assistant", %{"role" => "assistant", "content" => "done", "tool_calls" => []}, 4}
    ]

    for {kind, payload, seq} <- records do
      assert :ok =
               Transcript.append(
                 sdir,
                 Transcript.new_record(kind, payload, seq: seq, session_id: id)
               )
    end

    assert {:ok, ^id, pid} = Orchestrator.resume_session(id, root: dir)
    assert {:ok, ^pid} = Orchestrator.lookup(id)

    state = Agent.get_state(pid)
    messages = state.messages

    assert Enum.map(messages, &message_role/1) ==
             ["system", "user", "assistant", "tool", "assistant"]

    assert canonical(Enum.drop(messages, 1)) == canonical(Enum.map(records, &elem(&1, 1)))

    # C4: the OpenCode Go id persisted in `meta.json#session_id` survives the round trip.
    assert state.session_id == "ses_athanor_single"

    cleanup([id])
  end

  test "resume_session/2 returns an error for an unknown id", %{tmp_dir: dir} do
    assert {:error, :not_found} = Orchestrator.resume_session("no-such-session", root: dir)
  end

  # -- C12 + resume marker ------------------------------------------------------

  test "a session persisted mid-turn resumes :idle with no in-flight task (C12)", %{tmp_dir: dir} do
    id = "resume-inflight"

    assert :ok =
             Store.ensure_session(
               [id: id, role: :conductor, title: "Inflight", cd: dir, last_status: :streaming],
               root: dir
             )

    assert {:ok, ^id, pid} = Orchestrator.resume_session(id, root: dir)

    # `Agent.get_state/1` exposes the public status; `:sys.get_state/1` shows the raw struct so
    # the neutralised `current_task` is observable too.
    assert Agent.get_state(pid).status == :idle

    internal = :sys.get_state(pid)
    assert internal.status == :idle
    assert internal.current_task == nil

    cleanup([id])
  end

  test "resume publishes a {:resume, %{from: version}} marker (pinned shape)", %{tmp_dir: dir} do
    id = "resume-marker"
    Bus.subscribe("deck:events")

    assert :ok =
             Store.ensure_session([id: id, role: :conductor, title: "Marker", cd: dir], root: dir)

    assert {:ok, ^id, _pid} = Orchestrator.resume_session(id, root: dir)

    assert_receive {:agent_event, ^id, {:resume, %{from: 1}}}, 2_000

    cleanup([id])
  end

  # -- /clear marker (design §7.4, issue #31) -----------------------------------

  test "a clear marker drops every message before it on resume", %{tmp_dir: dir} do
    id = "resume-clear"

    assert :ok =
             Store.ensure_session(
               [id: id, role: :conductor, title: "Cleared", cd: dir],
               root: dir
             )

    sdir = Store.session_dir(id, root: dir)

    # An append-only transcript: the pre-clear turns stay on disk, the marker records the reset,
    # and the post-clear turns follow it.
    records = [
      {"user", %{"role" => "user", "content" => "old question"}, 1},
      {"assistant", %{"role" => "assistant", "content" => "old answer", "tool_calls" => []}, 2},
      {"clear", %{"event" => "clear", "ts" => "2026-01-01T00:00:00Z"}, 3},
      {"user", %{"role" => "user", "content" => "new question"}, 4},
      {"assistant", %{"role" => "assistant", "content" => "new answer", "tool_calls" => []}, 5}
    ]

    for {kind, payload, seq} <- records do
      assert :ok =
               Transcript.append(
                 sdir,
                 Transcript.new_record(kind, payload, seq: seq, session_id: id)
               )
    end

    assert {:ok, ^id, pid} = Orchestrator.resume_session(id, root: dir)

    messages = Agent.get_state(pid).messages

    # C13: the system message is re-derived; only the post-clear turns are replayed.
    assert Enum.map(messages, &message_role/1) == ["system", "user", "assistant"]

    assert canonical(Enum.drop(messages, 1)) ==
             canonical([
               %{"role" => "user", "content" => "new question"},
               %{"role" => "assistant", "content" => "new answer", "tool_calls" => []}
             ])

    refute Enum.any?(messages, &(Map.get(&1, "content") == "old answer"))

    cleanup([id])
  end

  # -- helpers ------------------------------------------------------------------

  defp message_role(msg), do: Map.get(msg, :role) || Map.get(msg, "role")

  # One canonical (string-keyed) form for both atom-keyed live messages and string-keyed
  # rehydrated ones, so `==` compares values, order and tool-call structure exactly.
  defp canonical(messages), do: messages |> JSON.encode!() |> JSON.decode!()

  defp persisted_count(messages), do: Enum.count(messages, &(message_role(&1) != "system"))

  defp resumed_messages(id) do
    {:ok, pid} = Orchestrator.lookup(id)
    Agent.get_state(pid).messages
  end

  defp stop_session(pid), do: DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)

  defp cleanup(ids) do
    for id <- ids do
      case Orchestrator.lookup(id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)
        :error -> :ok
      end
    end
  end

  # `Recorder.stats/1` is a `GenServer.call`, i.e. a barrier behind every event already sent to
  # the Recorder, so once it reports the expected record count the transcript is durably written.
  defp wait_for_records(recorder, id, expected, attempts \\ 200)

  defp wait_for_records(_recorder, id, expected, 0) do
    flunk("transcript for #{id} never reached #{expected} records")
  end

  defp wait_for_records(recorder, id, expected, attempts) do
    case Recorder.stats(recorder).sessions[id] do
      %{records: ^expected} -> :ok
      _other -> Process.sleep(10) && wait_for_records(recorder, id, expected, attempts - 1)
    end
  end
end
