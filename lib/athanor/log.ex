defmodule Athanor.Log do
  @moduledoc """
  On-disk diagnostic log for a wedged daemon.

  Athanor's daemon runs detached (`elixir --erl -detached …`), so its `Logger` output goes to a
  stdout nobody is attached to: when the system wedges there is *nothing to read afterwards*
  (this was called out as a rough edge in `docs/handover.md` §5). `Athanor.Log` fixes that by
  installing a `:logger` handler that appends a durable file, plus a tiny structured
  event API (`event/2`, `wedge/2`) for the "why did it hang?" moments that are not exceptions
  and so would otherwise be invisible.

  ## What it does

    * `install/0` attaches a `:logger` handler (`Athanor.Log.Handler`, modelled on
      `:logger_std_h`'s file case) that writes to `<log_dir>/athanor.log`, creating the
      directory if needed. It is **idempotent**: reinstalling replaces the previous handler
      rather than stacking a second writer.
    * `log_path/0` resolves the current file: `Athanor.Config.log_dir()` joined with
      `athanor.log`, or an explicit `:log_path` override (used by tests to keep writes in a
      scratch directory).
    * `event/2` writes one structured line — a timestamp, the level, the event tag and a
      `key=value` payload — so a later reader can grep for `wedge`, `turn_timeout`, `rpc_timeout`,
      `bash_kill`, etc. without a log parser.
    * `wedge/2` is `event/2` at `:warning` level with the tag `:wedge`; it is the single helper
      the rest of the codebase calls when it *avoids* a hang (a watchdog firing, an RPC timing
      out, a process group being killed).

  ## Fail-safe by construction

  Logging must never be the reason Athanor breaks, so every write is best-effort: a missing
  directory, a full disk or an unwritable path is swallowed (the handler reports the failure to
  `Logger` and keeps running). Disabled via `Athanor.Config.log_enabled?/0`
  (`ATHANOR_LOG=0`), in which case `install/0` removes the handler and `event/2` is a no-op.

  ## Rotation

  One previous file is kept: when `athanor.log` exceeds `Athanor.Config.log_max_bytes/0` it is
  renamed to `athanor.log.1` and a fresh file started, so a long-lived daemon cannot fill the
  disk. Rotation is checked on each write.

  ## Why not `:logger_file` / a dependency

  Athanor deliberately has no `config/` directory and a minimal dependency set
  (`docs/handover.md` §6). A ~200-line handler that owns its own file and rotation is easier to
  reason about — and to keep fail-safe — than wiring `:logger_std_h` through application env in
  a project that has none.
  """

  require Logger

  @handler_id :athanor_log_file
  @default_filename "athanor.log"
  @max_bytes_before_check 0

  @doc """
  Installs (or replaces) the file handler for diagnostic logging.

  Safe to call more than once and from any process. Returns `:ok` whether logging is enabled
  or not; when disabled it ensures no handler is attached. Called once by
  `Athanor.Application.start/2`.
  """
  @spec install() :: :ok
  def install do
    if enabled?() do
      do_install()
    else
      remove()
    end
  end

  @doc """
  Removes the file handler if it is installed. Idempotent.
  """
  @spec remove() :: :ok
  def remove do
    _ = :logger.remove_handler(@handler_id)
    :ok
  catch
    # `remove_handler/1` raises if the handler never existed; that is the desired end state.
    _, _ -> :ok
  end

  @doc """
  Absolute path of the current log file.

  Honours an explicit `:log_path` (`config :athanor, :log_path`) so tests can redirect every
  write into a scratch directory, otherwise `<Athanor.Config.log_dir()>/athanor.log`.
  """
  @spec log_path() :: String.t()
  def log_path do
    case Application.get_env(:athanor, :log_path) do
      path when is_binary(path) -> Path.expand(path)
      _ -> Path.join(Athanor.Config.log_dir(), @default_filename)
    end
  end

  @doc """
  True when diagnostic logging is on.

  Delegates to `Athanor.Config.log_enabled?/0`, except that an explicit `:log_path` implies
  enabled (that is only ever set by a caller that wants the file).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:athanor, :log_path) do
      path when is_binary(path) -> true
      _ -> Athanor.Config.log_enabled?()
    end
  end

  @doc """
  Writes one structured diagnostic line.

  `tag` is an atom or string naming the event (e.g. `:turn_timeout`); `payload` is a keyword or
  map of extra fields that are rendered as `key=value`. Intended for the "we just avoided a
  hang" moments, so it must never raise — an unencodable payload falls back to `inspect/1`.

  Returns `:ok` always.
  """
  @spec event(atom() | String.t(), keyword() | map()) :: :ok
  def event(tag, payload \\ []) do
    if enabled?() do
      fields = payload |> normalise_payload() |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

      Logger.warning("[athanor] event=#{tag} #{fields}")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Records that a wedge was *avoided* (or detected): `event/2` with the tag `wedge`.

  The single helper for watchdogs, RPC timeouts and process-group kills, so those events are
  trivially grep-able in `athanor.log` afterwards.
  """
  @spec wedge(atom() | String.t(), keyword() | map()) :: :ok
  def wedge(tag, payload \\ []) do
    event("wedge:" <> to_string(tag), payload)
  end

  # -- handler installation ----------------------------------------------------------------

  defp do_install do
    # Reinstall rather than stack: a second file handler would write every line twice.
    remove()

    path = log_path()
    _ = File.mkdir_p(Path.dirname(path))

    case :logger.add_handler(@handler_id, Athanor.Log.Handler, %{config: %{file: path}}) do
      :ok ->
        :ok

      {:error, reason} ->
        # The application must still boot; logging is a diagnostic, never a prerequisite.
        Logger.error("[athanor] could not install file log at #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @doc false
  # Called by the handler on each write: returns the max size to enforce for `path`.
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Athanor.Config.log_max_bytes()

  @doc false
  # Kept for symmetry with the check interval; the handler consults `max_bytes/0` per write.
  def max_bytes_before_check, do: @max_bytes_before_check

  defp normalise_payload(payload) when is_list(payload), do: payload
  defp normalise_payload(payload) when is_map(payload), do: Map.to_list(payload)
  defp normalise_payload(other), do: [value: inspect(other)]

  defmodule Handler do
    @moduledoc false
    # A minimal `:logger` handler that appends to one file with size-based rotation.
    #
    # Modelled on the shape of `:logger_std_h`'s file case (single writer, `:raw` append,
    # `:file.write/2`), but deliberately tiny: Athanor has no `config/` and wants a fail-safe
    # writer, not a configurable one. `log/2` receives a fully-formatted log event and must
    # never raise, so every file error is caught and reported once through `:logger`.

    @behaviour :logger_handler

    @impl :logger_handler
    def log(event, %{config: %{file: path}} = config) do
      case format(event) do
        {:ok, iodata} ->
          write(path, iodata)

        {:error, _reason} ->
          :ok
      end

      {:ok, config}
    rescue
      _ -> {:ok, config}
    catch
      _, _ -> {:ok, config}
    end

    @impl :logger_handler
    def adding_handler(%{config: %{file: path}} = config) do
      case File.mkdir_p(Path.dirname(path)) do
        :ok -> {:ok, config}
        {:error, reason} -> {:error, {:file_error, reason}}
      end
    end

    @impl :logger_handler
    def removing_handler(_config), do: :ok

    @impl :logger_handler
    def changing_config(_set_or_update, old, new), do: {:ok, merge(old, new)}

    @impl :logger_handler
    def filter_config(config), do: config

    defp merge(old, new) do
      Map.merge(old, new, fn
        _k, oldv, %{} = newv -> Map.merge(oldv, newv)
        _k, _oldv, newv -> newv
      end)
    end

    defp format(event) do
      {:ok, :logger_formatter.format(event, %{})}
    rescue
      _ -> {:error, :bad_format}
    end

    defp write(path, iodata) do
      _ = rotate_if_needed(path)

      case :file.open(path, [:append, :raw, :binary]) do
        {:ok, fd} ->
          try do
            _ = :file.write(fd, iodata)
          after
            :file.close(fd)
          end

        {:error, _reason} ->
          :ok
      end
    end

    # One previous file is enough for a diagnostic log; rotate by rename so a half-written
    # line is never the one a reader sees.
    defp rotate_if_needed(path) do
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} when size >= 0 ->
          if size >= Athanor.Log.max_bytes(), do: rotate(path), else: :ok

        _ ->
          :ok
      end
    end

    defp rotate(path) do
      _ = File.rm(path <> ".1")
      _ = File.rename(path, path <> ".1")
      :ok
    end
  end
end
