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
          {:session_started,
           %{id: "worker-1", title: "Audit", role: :worker, parent_id: "conductor-main"}}
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
  end

  describe "handle_agent_event/3 and render_frame/1" do
    test "streams deltas, records tool execution, and renders split-pane deck frame" do
      tui =
        TUI.new(model: "deepseek-v4.1-flash", width: 100, height: 24)
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started,
           %{id: "worker-1", title: "test-runner", role: :worker, parent_id: "conductor-main"}}
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
end
