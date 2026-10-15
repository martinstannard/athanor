defmodule Athanor.TUITest do
  use ExUnit.Case, async: true

  alias Athanor.TUI

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

    test "cycles between conductor and sub-agents on Tab and supports /spawn and /conductor" do
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started,
           %{id: "worker-1", title: "Audit", role: :worker, parent_id: "conductor-main"}}
        )

      assert tui.active_id == "conductor-main"
      {:cont, tui} = TUI.handle_key(tui, "\t")
      assert tui.active_id == "worker-1"
      {:cont, tui} = TUI.handle_key(tui, "\t")
      assert tui.active_id == "conductor-main"

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
end
