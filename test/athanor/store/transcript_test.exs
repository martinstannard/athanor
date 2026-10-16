defmodule Athanor.Store.TranscriptTest do
  use ExUnit.Case, async: true

  alias Athanor.Store.Transcript

  @moduletag :tmp_dir

  # NB: every test takes `tmp_dir` and only ever touches that directory — no test may read or
  # write `~/.athanor` (plan §9.1).

  defp record(seq, kind, payload) do
    Transcript.new_record(kind, payload, seq: seq, session_id: "s1", ts: ~U[2026-01-01 12:00:00Z])
  end

  describe "append/2 + read/1 round trip" do
    test "appends records in order and reads them back unchanged", %{tmp_dir: dir} do
      user = %{"role" => "user", "content" => "hello"}
      assistant = %{"role" => "assistant", "content" => "", "tool_calls" => []}
      tool = %{"role" => "tool", "tool_call_id" => "call_1", "content" => "ok"}

      assert :ok = Transcript.append(dir, record(1, "user", user))
      assert :ok = Transcript.append(dir, record(2, "assistant", assistant))
      assert :ok = Transcript.append(dir, record(3, "tool", tool))

      assert {:ok, records} = Transcript.read(dir)
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3]
      assert Enum.map(records, & &1["kind"]) == ["user", "assistant", "tool"]
      assert Enum.map(records, & &1["payload"]) == [user, assistant, tool]
      assert Enum.all?(records, &(&1["v"] == 1))
      assert Enum.all?(records, &(&1["session_id"] == "s1"))
    end

    test "each record occupies exactly one newline-terminated line", %{tmp_dir: dir} do
      assert :ok =
               Transcript.append(dir, record(1, "user", %{"role" => "user", "content" => "a\nb"}))

      raw = File.read!(Transcript.path(dir))
      assert String.ends_with?(raw, "\n")
      assert length(String.split(raw, "\n")) == 2
      # An embedded newline in the payload must be escaped, not written literally.
      refute String.contains?(raw, "a\nb")
    end

    test "atom-keyed records are written with string keys", %{tmp_dir: dir} do
      assert :ok = Transcript.append(dir, %{kind: "event", payload: %{"event" => "boom"}})

      assert {:ok, [record]} = Transcript.read(dir)
      assert record["kind"] == "event"
      assert record["v"] == 1
      assert record["payload"] == %{"event" => "boom"}
    end

    test "reading a missing transcript is an empty list, not an error", %{tmp_dir: dir} do
      refute File.exists?(Transcript.path(dir))
      assert {:ok, []} = Transcript.read(dir)
    end

    test "an empty file reads as no records", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Transcript.path(dir), "")
      assert {:ok, []} = Transcript.read(dir)
    end
  end

  describe "open_append/1" do
    test "creates the file (and its parent directory) on a fresh path", %{tmp_dir: dir} do
      nested = Path.join(dir, "sessions/worker-1")
      refute File.exists?(Transcript.path(nested))

      assert {:ok, fd} = Transcript.open_append(nested)
      assert File.exists?(Transcript.path(nested))
      assert :ok = Transcript.close(fd)
    end

    test "records written through one handle keep their order", %{tmp_dir: dir} do
      assert {:ok, fd} = Transcript.open_append(dir)

      for seq <- 1..5 do
        assert :ok = Transcript.append(fd, record(seq, "status", %{"status" => "idle"}))
      end

      assert :ok = Transcript.close(fd)

      assert {:ok, records} = Transcript.read(dir)
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3, 4, 5]
    end

    test "close/1 is idempotent", %{tmp_dir: dir} do
      assert {:ok, fd} = Transcript.open_append(dir)
      assert :ok = Transcript.close(fd)
      assert :ok = Transcript.close(fd)
    end
  end

  describe "truncation tolerance (C7)" do
    test "drops a malformed final newline-less line and still returns the good prefix", %{
      tmp_dir: dir
    } do
      for seq <- 1..3 do
        assert :ok =
                 Transcript.append(
                   dir,
                   record(seq, "user", %{"role" => "user", "content" => "m#{seq}"})
                 )
      end

      # Simulate a crash mid-`write`: a partial JSON object with no trailing newline.
      partial = ~s({"v":1,"seq":4,"kind":"assis)
      raw = File.read!(Transcript.path(dir))
      File.write!(Transcript.path(dir), raw <> partial)

      assert {:ok, records, meta} = Transcript.read(dir)
      assert Enum.map(records, & &1["seq"]) == [1, 2, 3]
      assert meta == %{truncated: byte_size(partial)}
      assert byte_size(partial) > 0
    end

    test "a complete but unparseable final line is also reported as truncated", %{tmp_dir: dir} do
      assert :ok =
               Transcript.append(dir, record(1, "user", %{"role" => "user", "content" => "a"}))

      File.write!(Transcript.path(dir), File.read!(Transcript.path(dir)) <> "not json at all")

      assert {:ok, [%{"seq" => 1}], %{truncated: 15}} = Transcript.read(dir)
    end

    test "a torn line that happens to be valid JSON is kept (it is a complete record)", %{
      tmp_dir: dir
    } do
      # Guards the boundary: only *unparseable* tails are dropped. A final line with no
      # newline that parses cleanly is a real record (the writer crashed after the bytes hit
      # the page cache).
      line = JSON.encode!(record(1, "user", %{"role" => "user", "content" => "a"}))
      File.mkdir_p!(dir)
      File.write!(Transcript.path(dir), line)

      assert {:ok, [%{"seq" => 1}]} = Transcript.read(dir)
    end

    test "an empty trailing line is not reported as truncation", %{tmp_dir: dir} do
      assert :ok =
               Transcript.append(dir, record(1, "user", %{"role" => "user", "content" => "a"}))

      assert {:ok, [%{"seq" => 1}]} = Transcript.read(dir)
    end
  end

  describe "interior corruption" do
    test "a malformed line followed by more data is {:error, :corrupt}", %{tmp_dir: dir} do
      good = JSON.encode!(record(1, "user", %{"role" => "user", "content" => "a"}))
      later = JSON.encode!(record(3, "user", %{"role" => "user", "content" => "c"}))

      File.mkdir_p!(dir)
      File.write!(Transcript.path(dir), good <> "\n" <> "{oops" <> "\n" <> later <> "\n")

      assert {:error, :corrupt} = Transcript.read(dir)
    end
  end

  describe "forward compatibility" do
    test "unknown kinds and unknown fields are tolerated", %{tmp_dir: dir} do
      line =
        JSON.encode!(%{
          "v" => 1,
          "seq" => 1,
          "ts" => "2026-01-01T00:00:00Z",
          "session_id" => "s1",
          "kind" => "quantum_entanglement",
          "payload" => %{"role" => "user", "content" => "x"},
          "future_field" => %{"nested" => [1, 2, 3]}
        })

      File.mkdir_p!(dir)
      File.write!(Transcript.path(dir), line <> "\n")

      assert {:ok, [record]} = Transcript.read(dir)
      assert record["kind"] == "quantum_entanglement"
      assert record["future_field"] == %{"nested" => [1, 2, 3]}
      assert record["payload"] == %{"role" => "user", "content" => "x"}
    end

    test "records with v <= current are readable", %{tmp_dir: dir} do
      line = JSON.encode!(%{"v" => 0, "seq" => 1, "kind" => "user", "payload" => %{}})
      File.mkdir_p!(dir)
      File.write!(Transcript.path(dir), line <> "\n")

      assert {:ok, [%{"v" => 0}]} = Transcript.read(dir)
    end

    test "a JSON array line is not a record (a record must be an object)", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Transcript.path(dir), "[1,2,3]\n")
      assert {:error, :corrupt} = Transcript.read(dir)
    end
  end

  describe "new_record/3" do
    test "fills the envelope defaults" do
      record =
        Transcript.new_record(:user, %{"role" => "user", "content" => "hi"}, session_id: "s1")

      assert record["v"] == 1
      assert record["seq"] == 0
      assert record["kind"] == "user"
      assert record["session_id"] == "s1"
      assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(record["ts"])
    end
  end
end
