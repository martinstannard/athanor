defmodule Athanor.MemoryCompactionTest do
  @moduledoc """
  Opportunistic compaction of `learnings.jsonl` (plan §8.3, OQ7).

  `async: false`: the threshold is global config. Both the env var and the app env are neutralised
  so a stray `ATHANOR_MEMORY_COMPACT_BYTES` in the developer's shell cannot decide the outcome.
  """
  use ExUnit.Case, async: false

  alias Athanor.Memory.{Entry, Store}

  @moduletag :tmp_dir

  @env "ATHANOR_MEMORY_COMPACT_BYTES"

  setup do
    saved = {System.get_env(@env), Application.get_env(:athanor, :memory_compact_threshold_bytes)}
    System.delete_env(@env)

    on_exit(fn -> restore(saved) end)
    :ok
  end

  defp restore({env, app}) do
    if env, do: System.put_env(@env, env), else: System.delete_env(@env)

    if app,
      do: Application.put_env(:athanor, :memory_compact_threshold_bytes, app),
      else: Application.delete_env(:athanor, :memory_compact_threshold_bytes)
  end

  defp threshold(value), do: Application.put_env(:athanor, :memory_compact_threshold_bytes, value)

  defp entry(text), do: Entry.new(%{scope: :project, category: :fact, text: text})

  defp lines(dir) do
    dir |> Path.join("learnings.jsonl") |> File.read!() |> String.split("\n", trim: true)
  end

  test "past the threshold it drops the dead and keeps the live", %{tmp_dir: dir} do
    threshold(1)

    live = entry("keep me")
    dead = entry("forget me")
    :ok = Store.append_learning(dir, live)
    :ok = Store.append_learning(dir, dead)
    :ok = Store.append_tombstone(dir, dead.id)

    # The tombstoned entry *and* its tombstone are gone, and the live fact survives.
    assert [text] = Enum.map(lines(dir), &JSON.decode!(&1)["text"])
    assert text == "keep me"
    assert [%Entry{text: "keep me"}] = Store.read_learnings(dir)
  end

  test "a threshold of 0 disables it and leaves compaction to the explicit command", %{tmp_dir: dir} do
    threshold(0)

    dead = entry("forget me")
    :ok = Store.append_learning(dir, dead)
    :ok = Store.append_tombstone(dir, dead.id)

    # entry + tombstone both still on disk; the reader still hides the entry.
    assert length(lines(dir)) == 2
    assert Store.read_learnings(dir) == []
  end

  test "an ordinary append does not rewrite a small log", %{tmp_dir: dir} do
    # The realistic case: the default threshold is far larger than a test's file.
    threshold(10_000_000)

    fact = entry("a fact")
    :ok = Store.append_learning(dir, fact)
    :ok = Store.append_tombstone(dir, fact.id)

    assert length(lines(dir)) == 2
  end

  test "maybe_compact/1 is a no-op on an absent log", %{tmp_dir: dir} do
    threshold(1)
    assert :ok = Store.maybe_compact(dir)
  end
end
