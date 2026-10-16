defmodule Athanor.LogTest do
  # `async: false`: the diagnostic log is configured through application env (`:log_path`), which
  # is global — a concurrent test mutating it would race this one.
  use ExUnit.Case, async: false

  alias Athanor.Log

  # The handler writes to the console (via `Logger`) as well as the file, so capture the console
  # output to keep the test run readable; the assertions read the file, not the console.
  @moduletag :capture_log
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "logs/athanor.log")
    on_exit(fn -> Application.delete_env(:athanor, :log_path) end)
    Application.put_env(:athanor, :log_path, path)
    %{path: path}
  end

  test "log_path/0 honours the :log_path override", %{path: path} do
    assert Log.log_path() == Path.expand(path)
  end

  test "enabled?/0 is true when a :log_path is set", _ctx do
    assert Log.enabled?()
  end

  test "install/0 writes warnings to disk, creating the directory", %{path: path} do
    :ok = Log.install()
    on_exit(&Log.remove/0)

    Log.wedge(:turn_timeout, session: "conductor-main", phase: "llm_stream")
    Log.event(:custom, foo: "bar")

    # The file handler is asynchronous; give it a moment to flush.
    wait_until(fn -> File.exists?(path) and File.read!(path) =~ "custom" end)

    contents = File.read!(path)
    assert contents =~ "event=wedge:turn_timeout"
    assert contents =~ "session=conductor-main"
    assert contents =~ "phase=llm_stream"
    assert contents =~ "event=custom foo=bar"
  end

  test "install/0 is idempotent — it does not double-write", %{path: path} do
    :ok = Log.install()
    :ok = Log.install()
    on_exit(&Log.remove/0)

    Log.event(:once, n: 1)
    wait_until(fn -> File.exists?(path) and File.read!(path) =~ "event=once" end)

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(lines, &(&1 =~ "event=once")) == 1
  end

  test "event/2 never raises on an unencodable payload" do
    :ok = Log.install()
    on_exit(&Log.remove/0)

    assert Log.event(:weird, pid: self(), ref: make_ref()) == :ok
    assert Log.wedge(:weird, nested: %{a: self()}) == :ok
  end

  test "rotation keeps one previous file once the cap is exceeded", %{path: path} do
    Application.put_env(:athanor, :log_max_bytes, 200)
    on_exit(fn -> Application.delete_env(:athanor, :log_max_bytes) end)

    :ok = Log.install()
    on_exit(&Log.remove/0)

    # Enough writes to cross 200 bytes several times.
    for i <- 1..40, do: Log.event(:filler, n: i, pad: String.duplicate("x", 20))

    wait_until(fn -> File.exists?(path <> ".1") end)
    assert File.exists?(path <> ".1")
    assert File.stat!(path).size < 1_000
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
