defmodule Athanor.MemoryTranscriptRecallTest do
  @moduledoc """
  `recall` over §7.4 session transcripts (plan §7.3, OQ3).

  `async: false`: the feature flag and the sweep budget are global config, neutralised here so a
  stray shell env cannot decide the outcome.
  """
  use ExUnit.Case, async: false

  alias Athanor.Memory
  alias Athanor.Store
  alias Athanor.Store.Transcript

  @moduletag :tmp_dir

  @flag "ATHANOR_MEMORY_TRANSCRIPTS"
  @budget "ATHANOR_MEMORY_TRANSCRIPT_RECORDS"

  setup do
    saved =
      for {env, key} <- [
            {@flag, :memory_transcript_recall},
            {@budget, :memory_transcript_max_records}
          ] do
        {env, System.get_env(env), key, Application.get_env(:athanor, key)}
      end

    Enum.each([@flag, @budget], &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn {env, env_value, key, app_value} ->
        if env_value, do: System.put_env(env, env_value), else: System.delete_env(env)

        if app_value,
          do: Application.put_env(:athanor, key, app_value),
          else: Application.delete_env(:athanor, key)
      end)
    end)

    :ok
  end

  defp append(root, id, kind, content, seq) do
    :ok = Store.ensure_session([id: id, title: id, role: :worker, cd: "/tmp"], root: root)
    dir = Store.session_dir(id, root: root)

    assert :ok =
             Transcript.append(
               dir,
               Transcript.new_record(kind, %{"role" => kind, "content" => content},
                 seq: seq,
                 session_id: id
               )
             )
  end

  defp recall(root, query, scope \\ "transcripts") do
    {:ok, body} = Memory.recall(%{"query" => query, "scope" => scope}, root: root)

    # `recall` answers "No matching learnings." as prose when there is nothing to return.
    case JSON.decode(body) do
      {:ok, hits} when is_list(hits) -> hits
      _other -> body
    end
  end

  test "finds a message and reports its provenance", %{tmp_dir: root} do
    append(root, "s1", "user", "how do worktrees share memory", 1)
    append(root, "s1", "assistant", "they resolve to the repo root", 2)

    hits = recall(root, "worktrees")

    assert [%{"text" => text, "scope" => "session", "id" => id, "source" => source}] = hits
    assert text =~ "worktrees share memory"
    assert String.starts_with?(id, "tr_")
    assert source["session_id"] == "s1"
    assert source["kind"] == "user"
  end

  test "the same words in two sessions are two hits, not one", %{tmp_dir: root} do
    append(root, "s1", "user", "identical sentence about worktrees", 1)
    append(root, "s2", "user", "identical sentence about worktrees", 1)

    sessions =
      root
      |> recall("worktrees")
      |> Enum.map(& &1["source"]["session_id"])
      |> Enum.sort()

    assert sessions == ["s1", "s2"]
  end

  test "snippets are redacted on the way out", %{tmp_dir: root} do
    append(root, "s1", "user", "the key is sk-abcdef0123456789abcd", 1)

    assert [%{"text" => text}] = recall(root, "key")
    refute text =~ "sk-abcdef0123456789abcd"
  end

  test "non-message kinds are ignored", %{tmp_dir: root} do
    append(root, "s1", "status", "worktrees", 1)
    assert recall(root, "worktrees") == "No matching learnings."
  end

  test "the sweep stops at the record budget", %{tmp_dir: root} do
    Application.put_env(:athanor, :memory_transcript_max_records, 1)
    append(root, "s1", "user", "worktrees one", 1)
    append(root, "s1", "user", "worktrees two", 2)
    append(root, "s1", "user", "worktrees three", 3)

    assert [_one] = recall(root, "worktrees")
  end

  test "a disabled flag says so rather than silently finding nothing", %{tmp_dir: root} do
    Application.put_env(:athanor, :memory_transcript_recall, false)
    append(root, "s1", "user", "worktrees share memory", 1)

    assert {:error, message} = Memory.recall(%{"query" => "worktrees", "scope" => "transcripts"}, root: root)
    assert message =~ "disabled"
  end

  test "'all' does not include transcripts (they are opt-in by name)", %{tmp_dir: root} do
    append(root, "s1", "user", "worktrees share memory", 1)
    # No project/global learnings exist in this root, so `all` finds nothing.
    assert recall(root, "worktrees", "all") == "No matching learnings."
  end
end
