defmodule Athanor.TUITest do
  use ExUnit.Case, async: true

  alias Athanor.{Daemon, Store, TUI}
  alias Athanor.Store.Transcript

  describe "handle_key/2" do
    test "accumulates text, handles backspace, and submits on Enter" do
      tui = TUI.new(width: 80, height: 24)

      {:cont, tui} = TUI.handle_key(tui, "hello")
      {:cont, tui} = TUI.handle_key(tui, "!")
      assert tui.input == "hello!"

      {:cont, tui} = TUI.handle_key(tui, <<127>>)
      assert tui.input == "hello"

      {:submit, "hello", tui} = TUI.handle_key(tui, "\r")
      assert tui.input == ""
    end

    test "quits on Ctrl+C or /quit" do
      tui = TUI.new()
      assert {:quit, _} = TUI.handle_key(tui, <<3>>)

      {:cont, tui} = TUI.handle_key(tui, "/quit")
      assert {:quit, _} = TUI.handle_key(tui, "\r")
    end

    test "cancels on Esc when active session is busy" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event({:status, :streaming})

      assert {:cancel, _} = TUI.handle_key(tui, "\e")
    end

    # Regression for "Esc doesn't cancel anything" (docs/wedge-findings.md): Esc used to be gated
    # on the client's cached `active_status/1`, so a stale/missed status event made it a silent
    # no-op even while the daemon-side session was busy. It must always dispatch a cancel now.
    test "Esc issues a cancel even when the cached status says idle" do
      tui = TUI.new()
      assert TUI.active_status(tui) == :idle
      assert {:cancel, _} = TUI.handle_key(tui, "\e")
    end

    test "Esc issues a cancel for a session that never reported a status" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-x",
          {:session_started, %{id: "worker-x", title: "x", role: :worker, parent_id: nil}}
        )

      # A freshly attached client may have missed the status events entirely.
      assert {:cancel, _} = TUI.handle_key(tui, "\e")
    end

    test "switches themes with /theme and lists them with a bare /theme" do
      tui = TUI.new()
      original = tui.theme.key

      typed = elem(TUI.handle_key(tui, "/theme dracula"), 1)
      {:theme, "dracula", cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      typed = elem(TUI.handle_key(tui, "/theme"), 1)
      {:theme, nil, _} = TUI.handle_key(typed, "\r")

      listed = TUI.apply_theme(tui, nil)
      entries = listed.sessions["conductor-main"].entries

      assert Enum.any?(entries, fn
               {:system, msg} -> msg =~ "Themes:"
               _ -> false
             end)

      applied = TUI.apply_theme(tui, "nord")
      assert applied.theme.key == :nord

      unknown = TUI.apply_theme(tui, "not-a-theme")
      assert unknown.theme.key == original

      assert Enum.any?(
               unknown.sessions["conductor-main"].entries,
               fn
                 {:system, msg} -> msg =~ "Unknown theme"
                 _ -> false
               end
             )
    end

    test "renders with a selected theme's colours" do
      tui = TUI.new(theme: "dracula", width: 100, height: 24)
      assert tui.theme.key == :dracula

      frame = TUI.render_frame(tui)

      # Encoding-agnostic: the global theme mode may be 24-bit or 256-colour.
      expected =
        case Athanor.Theme.colour!(tui.theme, :accent) do
          {r, g, b} -> "38;2;#{r};#{g};#{b}"
          index -> "38;5;#{index}"
        end

      assert frame =~ expected
      assert frame =~ "theme: dracula"
    end

    test "Tab switches focus between input and the session deck, and j/k + Enter navigate it" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "Audit", role: :worker, parent_id: "conductor-main"}}
        )

      assert tui.focus == :input
      assert tui.active_id == "conductor-main"

      # Tab moves focus to the deck without changing the active session
      {:cont, tui} = TUI.handle_key(tui, "\t")
      assert tui.focus == :sessions
      assert tui.active_id == "conductor-main"

      # 'j' moves the highlight down, Enter selects and returns focus to input
      {:cont, tui} = TUI.handle_key(tui, "j")
      assert tui.sidebar_index == 1
      {:cont, tui} = TUI.handle_key(tui, "\r")
      assert tui.focus == :input
      assert tui.active_id == "worker-1"

      # 'k' navigates back up; Enter selects conductor-main and returns focus to input
      {:cont, tui} = TUI.handle_key(tui, "\t")
      assert tui.focus == :sessions
      # focus follows the active session
      assert tui.sidebar_index == 1
      {:cont, tui} = TUI.handle_key(tui, "k")
      assert tui.sidebar_index == 0
      {:cont, tui} = TUI.handle_key(tui, "\r")
      assert tui.focus == :input
      assert tui.active_id == "conductor-main"

      # Arrow keys also navigate the deck
      {:cont, tui} = TUI.handle_key(tui, "\t")
      {:cont, tui} = TUI.handle_key(tui, "\e[B")
      assert tui.sidebar_index == 1
      {:cont, tui} = TUI.handle_key(tui, "\e[A")
      assert tui.sidebar_index == 0

      # Printable keys are swallowed while the deck is focused
      {:cont, tui} = TUI.handle_key(tui, "x")
      assert tui.input == ""

      # Return focus to the input line before typing commands
      {:cont, tui} = TUI.handle_key(tui, "\t")
      assert tui.focus == :input

      {:cont, tui} = TUI.handle_key(tui, "/spawn Docs :: Check README")
      assert {:spawn_subagent, "Docs", "Check README", tui} = TUI.handle_key(tui, "\r")

      {:cont, tui} = TUI.handle_key(tui, "/conductor ops")
      assert {:spawn_conductor, "ops", _} = TUI.handle_key(tui, "\r")
    end

    # Regression for the streaming wedge (docs/wedge-findings.md): a token burst used to be
    # re-rendered per token, starving input and making Esc feel dead. `drain_pending_events/1`
    # folds every queued event into the state before the next render.
    test "drains a queued burst of deltas into one state update" do
      tui = TUI.new()

      for chunk <- ["a", "b", "c", "d", "e"],
          do: send(self(), {:agent_event, "conductor-main", {:text_delta, chunk}})

      coalesced = TUI.drain_pending_events(tui)
      session = coalesced.sessions["conductor-main"]
      assert session.streaming_buffer == "abcde"
      # The queue is empty afterwards: everything was folded, nothing re-rendered.
      refute_received {:agent_event, _, _}
    end

    test "leaves an empty queue untouched" do
      tui = TUI.new()
      assert TUI.drain_pending_events(tui) == tui
    end
  end

  describe "handle_agent_event/3 and render_frame/1" do
    test "streams deltas, records tool execution, and renders split-pane deck frame" do
      tui =
        TUI.new(model: "deepseek-v4.1-flash", width: 100, height: 24)
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "test-runner", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event({:user_message, "Read mix.exs"})
        |> TUI.handle_agent_event({:status, :executing_tools})
        |> TUI.handle_agent_event({:tool_start, "read_file", ~s({"path":"mix.exs"})})
        |> TUI.handle_agent_event({:tool_end, "read_file", {:ok, "defmodule Athanor.MixProject"}})
        |> TUI.handle_agent_event({:status, :streaming})
        |> TUI.handle_agent_event({:text_delta, "It uses Elixir "})
        |> TUI.handle_agent_event({:text_delta, "1.19."})

      frame_streaming = TUI.render_frame(tui)
      assert frame_streaming =~ "ATHANOR"
      assert frame_streaming =~ "DECK SESSIONS"
      assert frame_streaming =~ "test-runner"
      assert frame_streaming =~ "Read mix.exs"
      assert frame_streaming =~ "read_file"
      assert frame_streaming =~ "It uses Elixir 1.19.▍"

      tui_done = TUI.handle_agent_event(tui, {:turn_complete, "It uses Elixir 1.19."})
      assert TUI.active_status(tui_done) == :idle

      frame_done = TUI.render_frame(tui_done)
      assert frame_done =~ "IDLE"
      assert frame_done =~ "It uses Elixir 1.19."
    end
  end

  # design §7.4 / plan §6.4 + M4: the `/resume` command surface.
  describe "/resume" do
    test "/resume <id> parses to the resume branch and bare /resume to the listing" do
      tui = TUI.new()

      typed = elem(TUI.handle_key(tui, "/resume abc"), 1)
      assert {:resume, "abc", cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      # Surrounding whitespace is trimmed; the id itself is preserved verbatim.
      typed = elem(TUI.handle_key(tui, "/resume   worker-1a2b  "), 1)
      assert {:resume, "worker-1a2b", _} = TUI.handle_key(typed, "\r")

      # No argument is the "list what is resumable" signal `loop/2` branches on.
      typed = elem(TUI.handle_key(tui, "/resume"), 1)
      assert {:resume, nil, cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      # Only the exact verb is a command: `/resumex` stays an ordinary prompt.
      typed = elem(TUI.handle_key(tui, "/resumex"), 1)
      assert {:submit, "/resumex", _} = TUI.handle_key(typed, "\r")
    end

    @tag :tmp_dir
    test "bare /resume lists the resumable sessions from disk", %{tmp_dir: dir} do
      :ok =
        Store.ensure_session(
          [id: "resume-listed", role: :worker, title: "Listed worker", cd: dir],
          root: dir
        )

      tui = TUI.new(width: 100, height: 24)
      listed = TUI.list_resumable_sessions(tui, root: dir)

      assert Enum.any?(entries(listed), fn
               {:system, msg} -> msg =~ "resume-listed" and msg =~ "/resume"
               _ -> false
             end)

      # An empty store is a plain transcript line, never a crash or an empty screen.
      empty = TUI.list_resumable_sessions(TUI.new(), root: Path.join(dir, "no-such-root"))

      assert Enum.any?(entries(empty), fn
               {:system, msg} -> msg =~ "No resumable sessions"
               _ -> false
             end)
    end

    @tag :tmp_dir
    test "a resume hydrates the persisted transcript into a rendered frame", %{tmp_dir: dir} do
      id = "resume-hydrated"

      :ok =
        Store.ensure_session(
          [id: id, role: :conductor, title: "Hydrated conductor", cd: dir],
          root: dir
        )

      records = [
        {"user", %{"role" => "user", "content" => "Read the note"}, 1},
        {"assistant",
         %{
           "role" => "assistant",
           "content" => "",
           "tool_calls" => [
             %{
               "id" => "call_read_note",
               "type" => "function",
               "function" => %{"name" => "read_file", "arguments" => ~s({"path":"note.txt"})}
             }
           ]
         }, 2},
        {"tool", %{"role" => "tool", "tool_call_id" => "call_read_note", "content" => "gold"}, 3},
        {"assistant",
         %{
           "role" => "assistant",
           "content" => "The note says alchemical_gold.",
           "tool_calls" => []
         }, 4}
      ]

      for {kind, payload, seq} <- records do
        :ok =
          Transcript.append(
            Store.session_dir(id, root: dir),
            Transcript.new_record(kind, payload, seq: seq, session_id: id)
          )
      end

      {:ok, loaded, _meta} = Store.load_records(id, root: dir)
      messages = Enum.flat_map(loaded, &persisted_message/1)

      # This is exactly the daemon path a client takes (plan §6.4/§9.8): the loaded records are
      # turned into TUI entries by `Daemon.messages_to_tui_entries/1` and fed to the existing
      # `hydrate_sessions/2` — the resume command adds no rendering of its own.
      session = %{
        id: id,
        title: "Hydrated conductor",
        role: :conductor,
        parent_id: nil,
        status: :idle,
        messages: messages
      }

      tui = TUI.new(width: 100, height: 30, active_id: id) |> TUI.hydrate_sessions([session])

      assert tui.sessions[id].entries == Daemon.messages_to_tui_entries(messages)
      assert tui.sessions[id].entries != []

      frame = TUI.render_frame(tui)
      assert is_binary(frame) and frame != ""
      assert frame =~ "The note says alchemical_gold."
      assert frame =~ "Read the note"
    end
  end

  defp entries(tui), do: tui.sessions[tui.active_id].entries

  defp persisted_message(%{"kind" => kind, "payload" => payload})
       when kind in ["user", "assistant", "tool"],
       do: [payload]

  defp persisted_message(_record), do: []

  # design §7.4 + issue #31: the `/clear` command surface.
  describe "/clear" do
    test "/clear parses to {:clear_context, tui} and clears the input line" do
      tui = TUI.new()

      typed = elem(TUI.handle_key(tui, "/clear"), 1)
      assert {:clear_context, cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      # `/clear-queue` is a different verb, and a longer verb is still an ordinary prompt.
      typed = elem(TUI.handle_key(TUI.new(), "/clear-queue"), 1)
      assert {:clear_queue, _} = TUI.handle_key(typed, "\r")

      typed = elem(TUI.handle_key(TUI.new(), "/clearx"), 1)
      assert {:submit, "/clearx", _} = TUI.handle_key(typed, "\r")
    end

    test "clears the active session's local transcript and leaves other sessions untouched" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event({:user_message, "hello conductor"})
        |> TUI.handle_agent_event("worker-1", {:user_message, "hello worker"})

      assert Enum.any?(tui.sessions["conductor-main"].entries, &match?({:user, _}, &1))
      worker_entries = tui.sessions["worker-1"].entries
      assert Enum.any?(worker_entries, &match?({:user, _}, &1))

      # This is exactly what `dispatch/3` runs for `{:clear_context, tui}` once the RPC succeeds.
      cleared = TUI.clear_local_context(tui)

      # The active session's prior transcript is gone, replaced by a single notice.
      refute Enum.any?(cleared.sessions["conductor-main"].entries, &match?({:user, _}, &1))

      assert Enum.any?(cleared.sessions["conductor-main"].entries, fn
               {:system, msg} -> msg =~ "context cleared"
               _ -> false
             end)

      # A peer session is not the active one, so nothing about it changes.
      assert cleared.sessions["worker-1"].entries == worker_entries
    end

    test "the agent's {:context_cleared, _} event empties that session's view idempotently" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event({:user_message, "hello conductor"})
        |> TUI.handle_agent_event("worker-1", {:user_message, "hello worker"})

      cleared = TUI.handle_agent_event(tui, "worker-1", {:context_cleared, %{}})

      # The event names the session it applies to: conductor-main is *not* cleared.
      assert Enum.any?(cleared.sessions["conductor-main"].entries, &match?({:user, _}, &1))
      refute Enum.any?(cleared.sessions["worker-1"].entries, &match?({:user, _}, &1))

      # Applying it again is a no-op (the view is replaced, never appended to) — the client that
      # typed `/clear` both clears locally and receives this event.
      assert TUI.handle_agent_event(cleared, "worker-1", {:context_cleared, %{}}) == cleared
    end
  end

  # design §10.3 + §10.9 T5 / issue #19: the `/kill` command surface.
  describe "/kill" do
    test "/kill <id> parses to the kill branch; --force is accepted before or after the id" do
      tui = TUI.new()

      typed = elem(TUI.handle_key(tui, "/kill worker-1"), 1)
      assert {:kill, "worker-1", false, cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      typed = elem(TUI.handle_key(tui, "/kill worker-1 --force"), 1)
      assert {:kill, "worker-1", true, _} = TUI.handle_key(typed, "\r")

      # Flag-first reads naturally too.
      typed = elem(TUI.handle_key(tui, "/kill --force worker-1"), 1)
      assert {:kill, "worker-1", true, _} = TUI.handle_key(typed, "\r")

      # A bare `/kill` is the "what is running?" listing signal `loop/2` branches on.
      typed = elem(TUI.handle_key(tui, "/kill"), 1)
      assert {:kill, nil, false, cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      # Only the exact verb is a command: `/killx` stays an ordinary prompt.
      typed = elem(TUI.handle_key(TUI.new(), "/killx"), 1)
      assert {:submit, "/killx", _} = TUI.handle_key(typed, "\r")
    end

    test "removes only the named session from the deck, leaving peers and their transcripts" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event(
          "worker-2",
          {:session_started, %{id: "worker-2", title: "w2", role: :worker, parent_id: "conductor-main"}}
        )

      assert tui.session_order == ["conductor-main", "worker-1", "worker-2"]

      # This is exactly what `dispatch/3` runs for `{:kill, …}` once the RPC succeeds.
      killed = TUI.remove_local_session(tui, "worker-1")

      refute Map.has_key?(killed.sessions, "worker-1")
      refute "worker-1" in killed.session_order
      assert Map.has_key?(killed.sessions, "worker-2")
      assert Map.has_key?(killed.sessions, "conductor-main")

      # conductor-main was active, and it still exists, so the selection does not move.
      assert killed.active_id == "conductor-main"
    end

    test "killing the active worker selects its parent Conductor, not just any survivor" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event(
          "conductor-2",
          {:session_started, %{id: "conductor-2", title: "c2", role: :conductor, parent_id: nil}}
        )
        |> Map.put(:active_id, "worker-1")

      killed = TUI.remove_local_session(tui, "worker-1")

      # `conductor-2` comes later in the order, but the natural "where was I" is the parent.
      assert killed.active_id == "conductor-main"
      assert killed.scroll_offset == 0
    end

    test "killing the last remaining session keeps a valid active_id (never nil)" do
      tui = TUI.new(active_id: "solo")

      killed = TUI.remove_local_session(tui, "solo")

      assert killed.session_order == []
      assert killed.sessions == %{}
      # Every renderer assumes a binary `active_id`; an empty deck must not produce `nil`.
      assert is_binary(killed.active_id)
    end

    test "bare /kill lists what is running" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )

      listed = TUI.list_killable_sessions(tui)

      assert Enum.any?(entries(listed), fn
               {:system, msg} -> msg =~ "worker-1" and msg =~ "/kill"
               _ -> false
             end)
    end
  end

  # Issue #34: pasting multi-line text into the prompt.
  describe "multi-line input and pasting (#34)" do
    test "a pasted block keeps its newlines instead of being flattened" do
      # The old behaviour was `String.replace("\n", " ")`: a block collapsed to one line. A paste
      # with no bracketed-paste markers still arrives as ordinary text, so it must be preserved.
      tui = TUI.new(width: 80, height: 24)

      assert {:cont, tui} = TUI.handle_key(tui, "line one\nline two\nline three")

      assert tui.input == "line one\nline two\nline three"
      assert length(String.split(tui.input, "\n")) == 3
    end

    test "a typed Enter still submits, and a pasted block never does" do
      # `\r` is what a raw-mode terminal sends for Return, so it keeps submitting.
      typed = %{TUI.new() | input: "one\ntwo"}
      assert {:submit, "one\ntwo", _} = TUI.handle_key(typed, "\r")

      # A bracketed paste ending in a newline must NOT fire a turn: the body is inserted
      # atomically and the interior newline is text.
      tui = TUI.new()
      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~alpha\nbeta\n\e[201~")

      assert tui.input == "alpha\nbeta\n"
      assert tui.paste_buffer == nil
    end

    test "Ctrl+J inserts a newline rather than submitting" do
      tui = %{TUI.new() | input: "first"}

      assert {:cont, tui} = TUI.handle_key(tui, "\n")

      assert tui.input == "first\n"
    end

    test "backspace deletes one character across a line boundary" do
      tui = %{TUI.new() | input: "ab\ncd"}

      # Four deletes remove d, c, the newline (rejoining the lines), then b.
      tui = delete(tui, 4)

      assert tui.input == "a"
    end

    test "a paste split across chunks is reassembled atomically" do
      # The OTP-28 default adapter (`Termite.Terminal.Shell`) delivers a paste as many small
      # `{:data, _}` chunks — a 20 KB paste arrived as ~20 000 of them in the spike — so the body
      # must be buffered across calls, not inserted per chunk.
      tui = TUI.new()

      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~foo")
      assert tui.input == "", "an incomplete paste must not be visible yet"

      assert {:cont, tui} = TUI.handle_key(tui, "\nbar")
      assert tui.input == ""

      assert {:cont, tui} = TUI.handle_key(tui, "\e[201~")
      assert tui.input == "foo\nbar"
    end

    test "a paste terminator split across chunks still completes the paste" do
      # `suffix_ok=false` in the spike: the `\e[201~` itself can be delivered in pieces.
      tui = TUI.new()

      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~hello\e[20")
      assert tui.input == ""

      assert {:cont, tui} = TUI.handle_key(tui, "1~")
      assert tui.input == "hello"
    end

    test "keys after a paste are replayed as ordinary input" do
      # A terminal can coalesce the paste and the next keystroke into one read; the trailing bytes
      # must not be swallowed.
      tui = TUI.new()

      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~pasted\e[201~tail")

      assert tui.input == "pastedtail"
    end

    test "an Enter after a paste still submits" do
      tui = TUI.new()

      {:cont, tui} = TUI.handle_key(tui, "\e[200~body\e[201~")

      assert {:submit, "body", _} = TUI.handle_key(tui, "\r")
    end

    test "a `q` inside a paste is text, not a deck key" do
      # While a paste is in flight its bytes are literal text; the deck's key table must not see
      # them even when the deck has focus.
      tui = %{TUI.new() | focus: :sessions}

      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~quit\nq\e[201~")

      assert tui.input == "quit\nq"
      assert tui.focus == :sessions
    end

    test "CRLF and lone CR in a paste are folded to LF" do
      tui = TUI.new()

      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~a\r\nb\rc\e[201~")

      assert tui.input == "a\nb\nc"
    end

    test "an oversized paste is capped and the truncation is visible" do
      tui = TUI.new()
      body = String.duplicate("x", 200_000)

      assert {:cont, tui} = TUI.handle_key(tui, "\e[200~" <> body <> "\e[201~")

      assert String.contains?(tui.input, "[prompt truncated")
      assert byte_size(tui.input) < 200_000
    end

    test "the input box grows with the input and then caps, showing the tail" do
      # Three logical lines all fit in the box.
      tui = %{TUI.new(width: 80, height: 24) | input: "a\nb\nc"}
      frame = TUI.render_frame(tui)

      for line <- ["a", "b", "c"], do: assert(frame =~ line)
      assert drawn_rows(frame) == 24

      # A tall paste caps the box: the earliest lines scroll off (with a `⋮` marker) and the tail
      # — where the cursor always is — stays visible.
      tall = %{tui | input: Enum.map_join(1..20, "\n", &"line #{&1}")}
      tall_frame = TUI.render_frame(tall)

      assert tall_frame =~ "line 20"
      assert tall_frame =~ "⋮"
      refute tall_frame =~ "line 1\n"
      assert drawn_rows(tall_frame) == 24
    end

    test "a multi-line prompt round-trips through submit unchanged apart from the trim" do
      tui = %{TUI.new() | input: "  first line\nsecond line  "}

      # `submit_or_command/2` trims the whole prompt, exactly as it did for a single line; the
      # interior newline survives (only leading/trailing whitespace is cut).
      assert {:submit, "first line\nsecond line", _} = TUI.handle_key(tui, "\r")
    end

    test "a frame is always exactly `height` rows tall, however tall the input" do
      # A huge paste must push the transcript up, never the status bar / input box off the screen.
      for lines <- [1, 3, 6, 20, 200] do
        tui = %{TUI.new(width: 80, height: 24) | input: Enum.map_join(1..lines, "\n", &"line #{&1}")}

        assert drawn_rows(TUI.render_frame(tui)) == 24,
               "frame with #{lines} input lines was not 24 rows"
      end
    end
  end

  # The number of screen rows `render_frame/1` draws. It positions each row with a CSI cursor-move
  # followed by an erase-line (`\e[<row>;1H\e[2K`) rather than emitting literal newlines, so rows
  # are counted by that escape — splitting the frame on `"\n"` would count zero.
  defp drawn_rows(frame), do: length(:binary.matches(frame, "\e[2K"))

  defp delete(tui, 0), do: tui

  defp delete(tui, n) do
    {:cont, tui} = TUI.handle_key(tui, <<127>>)
    delete(tui, n - 1)
  end

  describe "activity indicator (throbber)" do
    test "busy?/1 reflects whether any session is working" do
      idle = TUI.new()
      refute TUI.busy?(idle)

      streaming =
        TUI.handle_agent_event(idle, "conductor-main", {:status, :streaming})

      assert TUI.busy?(streaming)

      tools =
        TUI.handle_agent_event(idle, "conductor-main", {:status, :executing_tools})

      assert TUI.busy?(tools)

      # a *different* session being busy still counts
      other = TUI.handle_agent_event(idle, "worker-1", {:status, :streaming})
      assert TUI.busy?(other)
    end

    test "tick/1 is a no-op while idle, so an idle TUI never re-renders" do
      # `new/1` starts dirty so the first frame is drawn; simulate "already rendered once".
      rendered = %{TUI.new() | dirty: false}

      assert TUI.tick(rendered) == rendered
      refute TUI.tick(rendered).dirty
    end

    test "tick/1 advances the frame and marks the state dirty while busy" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event("conductor-main", {:status, :streaming})
        |> Map.put(:dirty, false)

      ticked = TUI.tick(tui)

      assert ticked.tick == 1
      assert ticked.dirty
      assert ticked.tick != tui.tick
    end

    test "the status bar animates through distinct frames while busy" do
      tui =
        TUI.new(width: 100, height: 24)
        |> TUI.handle_agent_event("conductor-main", {:status, :streaming})

      frames =
        tui
        |> Stream.unfold(fn t -> {TUI.render_frame(t), TUI.tick(t)} end)
        |> Enum.take(4)

      assert length(Enum.uniq(frames)) == 4, "expected four distinct frames while streaming"

      # and every frame carries one of the spinner glyphs, not the old static dot
      for frame <- frames do
        assert Enum.any?(
                 ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
                 &String.contains?(frame, &1)
               ),
               "expected a spinner glyph in the frame"

        refute frame =~ "● STREAMING"
      end
    end

    test "an idle frame shows the static badge and no spinner" do
      frame = TUI.render_frame(TUI.new(width: 100, height: 24))

      assert frame =~ "○ IDLE"
      refute frame =~ "⠋"
      refute frame =~ "⠙"
    end

    test "a busy sub-agent is visible in the deck even when another session is active" do
      tui =
        TUI.new(width: 100, height: 24)
        |> TUI.handle_agent_event(
          "worker-9",
          {:session_started, %{id: "worker-9", title: "busy worker", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event("worker-9", {:status, :executing_tools})

      # conductor-main is the active (idle) session, so the status bar is static...
      assert TUI.render_frame(tui) =~ "○ IDLE"
      # ...but the spinner still appears in the deck for the busy worker
      assert Enum.any?(
               ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
               &String.contains?(TUI.render_frame(tui), &1)
             )

      assert TUI.busy?(tui)
    end
  end

  # design §2.1 + issue #18: stacking prompts while the active session streams.
  describe "prompt stacking" do
    test "Enter on non-empty input while streaming enqueues instead of dropping it" do
      tui = TUI.new() |> TUI.handle_agent_event({:status, :streaming})

      typed = elem(TUI.handle_key(tui, "keep going"), 1)
      assert {:enqueue, "keep going", cleared} = TUI.handle_key(typed, "\r")

      # The text is handed to the agent's FIFO queue and the input line is cleared, exactly as an
      # immediate submit would be — the prompt is not silently dropped.
      assert cleared.input == ""
    end

    test "executing_tools also stacks, but an idle session still submits immediately" do
      executing = TUI.new() |> TUI.handle_agent_event({:status, :executing_tools})

      typed = elem(TUI.handle_key(executing, "next"), 1)
      assert {:enqueue, "next", _} = TUI.handle_key(typed, "\r")

      idle = TUI.new()
      typed = elem(TUI.handle_key(idle, "next"), 1)
      assert {:submit, "next", _} = TUI.handle_key(typed, "\r")
    end

    test "Enter on empty input stays a no-op while streaming" do
      tui = TUI.new() |> TUI.handle_agent_event({:status, :streaming})
      assert {:cont, ^tui} = TUI.handle_key(tui, "\r")
    end

    test "renders the pending count and a preview of the next prompt" do
      tui =
        TUI.new(width: 120, height: 24)
        |> TUI.handle_agent_event({:status, :streaming})
        |> TUI.handle_agent_event({:prompt_queue, %{len: 2, next: "second follow-up"}})

      assert TUI.active_queue_len(tui) == 2

      frame = TUI.render_frame(tui)
      assert frame =~ "⧗ 2 queued"
      assert frame =~ "next: second follow-up"

      # The agent's authoritative event is what the indicator follows: a drained prompt moves both
      # the count and the preview.
      drained = TUI.handle_agent_event(tui, {:prompt_queue, %{len: 1, next: "third"}})
      assert TUI.active_queue_len(drained) == 1
      assert TUI.render_frame(drained) =~ "⧗ 1 queued"
      refute TUI.render_frame(drained) =~ "second follow-up"
    end

    test "no indicator is rendered when nothing is stacked" do
      refute TUI.render_frame(TUI.new(width: 120, height: 24)) =~ "queued"
    end

    test "/clear-queue forgets the stack, reports what it dropped, and leaves the turn running" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event({:status, :streaming})
        |> TUI.handle_agent_event({:prompt_queue, %{len: 3, next: "one"}})

      typed = elem(TUI.handle_key(tui, "/clear-queue"), 1)
      assert {:clear_queue, cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      local = TUI.clear_local_queue(cleared)
      assert TUI.active_queue_len(local) == 0

      assert Enum.any?(entries(local), fn
               {:system, msg} -> msg =~ "Cleared 3 stacked prompt(s)"
               _ -> false
             end)

      # Clearing the stack is not a cancel: the in-flight turn is untouched.
      assert TUI.active_status(local) == :streaming
    end

    test "/clear-queue on an empty stack adds no noise" do
      tui = TUI.new() |> TUI.handle_agent_event({:status, :streaming})
      typed = elem(TUI.handle_key(tui, "/clear-queue"), 1)
      {:clear_queue, cleared} = TUI.handle_key(typed, "\r")

      assert TUI.clear_local_queue(cleared).sessions["conductor-main"].entries ==
               cleared.sessions["conductor-main"].entries
    end

    test "/unqueue drops only the most recently stacked prompt" do
      tui =
        TUI.new(width: 120, height: 24)
        |> TUI.handle_agent_event({:status, :streaming})
        |> TUI.handle_agent_event({:prompt_queue, %{len: 2, next: "first follow-up"}})

      typed = elem(TUI.handle_key(tui, "/unqueue"), 1)
      assert {:drop_queued, cleared} = TUI.handle_key(typed, "\r")
      assert cleared.input == ""

      dropped = TUI.drop_last_local_queue(cleared)
      assert TUI.active_queue_len(dropped) == 1
      # The head is untouched, so the preview still names the next prompt to run.
      assert TUI.render_frame(dropped) =~ "next: first follow-up"

      # Dropping the last remaining prompt empties the queue (and the preview with it).
      empty = TUI.drop_last_local_queue(dropped)
      assert TUI.active_queue_len(empty) == 0
      refute TUI.render_frame(empty) =~ "queued"
    end

    test "a longer verb is still an ordinary prompt" do
      typed = elem(TUI.handle_key(TUI.new(), "/unqueuex"), 1)
      assert {:submit, "/unqueuex", _} = TUI.handle_key(typed, "\r")
    end
  end

  describe "daemon connectivity header (#25)" do
    test "reports connected, unreachable and local, with theme roles" do
      base = TUI.new(daemon_node: :"athanor_daemon@127.0.0.1", width: 120)
      assert {"● athanor_daemon@127.0.0.1", :success} = TUI.daemon_status(%{base | daemon_connected?: true})

      down = %{
        base
        | daemon_connected?: false,
          daemon_down_since: System.monotonic_time(:millisecond) - 12_500
      }

      assert {"✕ unreachable (12s)", :error} = TUI.daemon_status(down)

      local = TUI.new(daemon_node: Node.self(), daemon_mode: :local)
      assert {"○ local", :warning} = TUI.daemon_status(local)
    end

    test "a nodedown of the attached node flips the status; unrelated nodes are ignored" do
      tui =
        TUI.new(daemon_node: :"athanor_daemon@127.0.0.1", width: 120)
        |> Map.put(:daemon_connected?, true)

      assert TUI.handle_node_event(tui, {:nodedown, :"someone_else@127.0.0.1"}) == tui

      down = TUI.handle_node_event(tui, {:nodedown, :"athanor_daemon@127.0.0.1"})
      refute down.daemon_connected?
      assert down.dirty
      assert is_integer(down.daemon_down_since)

      up = TUI.handle_node_event(down, {:nodeup, :"athanor_daemon@127.0.0.1"})
      assert up.daemon_connected?
      assert up.daemon_down_since == nil
    end

    test "the header renders the daemon indicator" do
      tui =
        TUI.new(width: 120)
        |> Map.put(:daemon_node, :"athanor_daemon@127.0.0.1")
        |> Map.put(:daemon_connected?, true)

      assert TUI.render_frame(tui) =~ "daemon ● athanor_daemon@127.0.0.1"
    end
  end

  describe "/stats (#26)" do
    test "renders the active session's stats into the viewport" do
      stats = %{
        turns: 2,
        tool_calls: %{"bash" => 1},
        prompt_tokens: 100,
        completion_tokens: 20,
        cached_tokens: 0,
        reasoning_tokens: 0,
        context_tokens: 50,
        model: "m"
      }

      tui = TUI.new() |> TUI.handle_agent_event({:stats, stats}) |> TUI.stats_command(:active)
      {:system, text} = tui.sessions["conductor-main"].entries |> List.last()
      assert text =~ "Stats — conductor-main (model: m)"
      assert text =~ "tool calls:   1 (bash 1)"
    end

    test "says so when there are no stats yet" do
      tui = TUI.new() |> TUI.stats_command(:active)
      {:system, text} = tui.sessions["conductor-main"].entries |> List.last()
      assert text =~ "No stats yet"
    end

    test "/stats all aggregates every session that has stats" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event({:stats, %{turns: 2, tool_calls: %{"bash" => 1}, model: "m"}})
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event("worker-1", {:stats, %{turns: 3, tool_calls: %{"bash" => 2}, model: "m"}})
        |> TUI.stats_command(:all)

      {:system, text} = tui.sessions["conductor-main"].entries |> List.last()
      assert text =~ "Stats — total (2 session(s))"
      assert text =~ "turns:        5"
    end
  end
end
