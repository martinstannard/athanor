defmodule Athanor.Test.SSEServer do
  @moduledoc """
  A one-shot SSE server on a loopback port, for driving the **real** `Athanor.LLM.stream/4`
  through a real socket (issue #53).

  The unit tests in `llm_test.exs` exercise the parser directly (`consume_sse_chunk/3`), which is
  the right seam for a delta-shape assertion but proves nothing about the transport: whether Req's
  `into:` callback really reaches `consume_sse_chunk/3`, whether both event tags leave the process
  that owns the socket, and whether reasoning reaches the accumulator without becoming the
  assistant message. Those are the parts a fixture-based test would be trusting, and they are
  exactly the parts the reasoning feature depends on.

  Deliberately built on `:gen_tcp` rather than a `Plug`/`Bandit` dependency: this repo has neither,
  and adding a web server to test one parser is not a trade worth making. The server is one-shot
  and single-connection — it accepts one request, writes the whole body, closes — which is all a
  streaming client needs and keeps the fixture free of request parsing.
  """

  @doc """
  Starts a server that answers exactly one request with `body` as an SSE stream.

  Returns `{:ok, %{port: port, url: base_url, accept: ref}}` where `base_url` is ready to be passed
  as `Athanor.LLM.stream/4`'s `:base_url` (the `/chat/completions` path is appended by the client).

  The listener and the accept process are both linked to the caller, so they die with the test.
  Callers should `await/1` to be sure the request was actually served before the test ends —
  otherwise a client-side failure can look like a flaky "no data".
  """
  @spec start(binary()) :: {:ok, %{port: :inet.port_number(), url: String.t(), accepted: reference()}}
  def start(body) when is_binary(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        # Loopback only: a test fixture must never be reachable from another host.
        ip: {127, 0, 0, 1},
        backlog: 5
      ])

    {:ok, port} = :inet.port(listen)
    caller = self()
    ref = make_ref()

    spawn_link(fn -> serve_once(listen, body, caller, ref) end)

    {:ok, %{port: port, url: "http://127.0.0.1:#{port}/v1", accepted: ref}}
  end

  defp serve_once(listen, body, caller, ref) do
    # `accept` on the listening socket, not a pre-opened connection: the client is what starts the
    # exchange, so the fixture must wait for it.
    {:ok, socket} = :gen_tcp.accept(listen, 5_000)

    # Read the request head (headers end with a blank line). The client sends no body we care about
    # — the fixture answers regardless of what was asked — but it must be drained so the client does
    # not see a reset before it has read the response.
    drain_request(socket)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\n" <>
          "content-type: text/event-stream\r\n" <>
          "cache-control: no-cache\r\n" <>
          "connection: close\r\n\r\n" <>
          body
      )

    :gen_tcp.close(socket)
    :gen_tcp.close(listen)
    send(caller, {:sse_served, ref})
  end

  defp drain_request(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      :ok
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> drain_request(socket, acc <> data)
        {:error, _reason} -> :ok
      end
    end
  end

  @doc """
  Blocks until the fixture has written its response, or the timeout elapses.

  A test that asserts on the return value of `stream/4` is already synchronised by it; this is for
  the tests that assert only on *events*, where nothing else proves the request completed.
  """
  @spec await(reference(), timeout()) :: :ok
  def await(ref, timeout \\ 5_000) do
    receive do
      {:sse_served, ^ref} -> :ok
    after
      timeout -> :ok
    end
  end
end
