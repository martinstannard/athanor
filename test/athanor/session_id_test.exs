defmodule Athanor.SessionIdTest do
  use ExUnit.Case, async: true

  alias Athanor.SessionId

  describe "generate/1" do
    test "produces a path- and ref-safe id carrying its prefix" do
      id = SessionId.generate("worker")

      assert String.starts_with?(id, "worker-")
      assert SessionId.valid?(id)
      # usable as a path component and as a git branch component (§7.1/§7.4)
      assert id == Path.basename(id)
      refute String.contains?(id, "/")
      refute String.contains?(id, ".")
      refute String.contains?(id, " ")
    end

    test "accepts an atom prefix" do
      assert String.starts_with?(SessionId.generate(:conductor), "conductor-")
    end

    test "refuses a prefix that could not form a valid id" do
      for bad <- ["", "Worker", "wo rker", "w/r", "-w", "9w", "w."] do
        assert_raise ArgumentError, fn -> SessionId.generate(bad) end
      end
    end

    test "ids are distinct across many sequential calls" do
      ids = for _ <- 1..5_000, do: SessionId.generate("worker")
      assert length(Enum.uniq(ids)) == 5_000
    end

    test "ids are distinct under concurrency (the old Registry.count-based race)" do
      ids =
        1..500
        |> Task.async_stream(fn _ -> SessionId.generate("worker") end, max_concurrency: 50)
        |> Enum.map(fn {:ok, id} -> id end)

      assert length(Enum.uniq(ids)) == 500
    end
  end

  describe "valid?/1" do
    test "accepts ids the codebase already uses" do
      for id <- [
            "conductor-main",
            "worker-1",
            "worker-audit",
            "conductor-daemon-test",
            "conductor-local-attach",
            "a",
            "ab",
            "a1",
            "worker_1"
          ] do
        assert SessionId.valid?(id), "expected #{inspect(id)} to be valid"
      end
    end

    test "rejects anything unsafe as a path segment or git ref" do
      refute SessionId.valid?("")
      refute SessionId.valid?("../evil")
      refute SessionId.valid?("a/b")
      refute SessionId.valid?("a\\b")
      refute SessionId.valid?("a b")
      refute SessionId.valid?("-leading")
      refute SessionId.valid?(".hidden")
      refute SessionId.valid?("trailing-")
      refute SessionId.valid?("Upper")
      refute SessionId.valid?(String.duplicate("a", SessionId.max_length() + 1))
    end

    test "rejects non-binaries" do
      refute SessionId.valid?(nil)
      refute SessionId.valid?(:atom)
      refute SessionId.valid?(123)
    end
  end
end
