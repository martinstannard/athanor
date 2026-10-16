defmodule Athanor.Config do
  @moduledoc """
  Configuration helper for Athanor's LLM provider (OpenCode Go) and runtime settings.
  """

  @default_base_url "https://opencode.ai/zen/go/v1"
  @default_model "deepseek-v4.1-flash"
  @default_theme :default
  @default_search_max_results 200
  @default_search_max_file_bytes 1_048_576
  @default_home "~/.athanor"
  @default_store_enabled true
  @default_recorder_max_open_fds 64
  @default_compaction_threshold 0.8
  @default_context_limit_tokens 128_000
  @default_compaction_keep_fraction 0.4
  @default_search_ignores [
    ".git",
    "_build",
    "deps",
    "node_modules",
    "cover",
    ".elixir_ls",
    ".athanor"
  ]
  @opencode_auth_path "~/.local/share/opencode/auth.json"

  @doc """
  Returns the OpenCode Go base URL.
  """
  @spec base_url() :: String.t()
  def base_url do
    System.get_env("OPENCODE_BASE_URL") ||
      Application.get_env(:athanor, :base_url, @default_base_url)
  end

  @doc """
  Returns the model identifier to use with OpenCode Go.
  Strips a leading `"opencode-go/"` prefix if present.
  """
  @spec model() :: String.t()
  def model do
    raw =
      System.get_env("ATHANOR_MODEL") ||
        Application.get_env(:athanor, :model, @default_model)

    String.replace_prefix(raw, "opencode-go/", "")
  end

  @doc """
  Returns the configured TUI theme name, resolved from:
  1. `ATHANOR_THEME` environment variable
  2. `:athanor, :theme` application config
  3. `:default`
  """
  @spec theme() :: atom() | String.t()
  def theme do
    System.get_env("ATHANOR_THEME") ||
      Application.get_env(:athanor, :theme, @default_theme)
  end

  @doc """
  Maximum number of results returned by `glob`/`grep` (default #{@default_search_max_results}).
  """
  @spec search_max_results() :: pos_integer()
  def search_max_results do
    positive_int("ATHANOR_SEARCH_MAX_RESULTS", :search_max_results, @default_search_max_results)
  end

  @doc """
  Maximum file size, in bytes, that `grep` will read (default #{@default_search_max_file_bytes}).
  """
  @spec search_max_file_bytes() :: pos_integer()
  def search_max_file_bytes do
    positive_int(
      "ATHANOR_SEARCH_MAX_FILE_BYTES",
      :search_max_file_bytes,
      @default_search_max_file_bytes
    )
  end

  @doc """
  Directory names that `glob`/`grep` never descend into.

  Overridable via `ATHANOR_SEARCH_IGNORES` (comma-separated) or `:athanor, :search_ignores`.
  """
  @spec search_ignores() :: [String.t()]
  def search_ignores do
    case System.get_env("ATHANOR_SEARCH_IGNORES") do
      nil ->
        Application.get_env(:athanor, :search_ignores, @default_search_ignores)

      "" ->
        @default_search_ignores

      csv ->
        csv
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp positive_int(env, key, default) do
    raw = System.get_env(env) || Application.get_env(:athanor, key, default)

    case Integer.parse(to_string(raw)) do
      {value, _rest} when value > 0 -> value
      _ -> default
    end
  end

  @doc """
  Returns the colour encoding for themes:

    * `:truecolor` (default) — 24-bit RGB
    * `:ansi256` — quantised to the xterm-256 palette

  Resolved from `ATHANOR_THEME_MODE`, then `:athanor, :theme_mode`.
  """
  @spec theme_mode() :: :truecolor | :ansi256
  def theme_mode do
    raw =
      System.get_env("ATHANOR_THEME_MODE") ||
        Application.get_env(:athanor, :theme_mode, :truecolor)

    case to_string(raw) do
      "ansi256" -> :ansi256
      _ -> :truecolor
    end
  end

  @doc """
  Resolves the OpenCode Go API key from:
  1. `OPENCODE_API_KEY` environment variable
  2. `:athanor, :api_key` application config
  3. `~/.local/share/opencode/auth.json` under `"opencode-go" -> "key"`
  """
  @spec api_key() :: {:ok, String.t()} | {:error, String.t()}
  def api_key do
    cond do
      key = non_empty_env("OPENCODE_API_KEY") ->
        {:ok, key}

      key = Application.get_env(:athanor, :api_key) ->
        {:ok, key}

      true ->
        case read_opencode_auth_key() do
          {:ok, key} ->
            {:ok, key}

          {:error, _} ->
            {:error,
             "Missing OpenCode Go API key. Set OPENCODE_API_KEY or configure ~/.local/share/opencode/auth.json."}
        end
    end
  end

  @doc """
  Reads the API key from a given `auth.json` file path.
  """
  @spec read_opencode_auth_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_opencode_auth_key(path \\ @opencode_auth_path) do
    expanded = Path.expand(path)

    with {:ok, content} <- File.read(expanded),
         {:ok, %{"opencode-go" => %{"key" => key}}} when is_binary(key) and key != "" <-
           JSON.decode(content) do
      {:ok, key}
    else
      _ -> {:error, :not_found}
    end
  end

  defp non_empty_env(var) do
    case System.get_env(var) do
      nil -> nil
      "" -> nil
      val -> val
    end
  end

  # -- Store (§7.4 / plan §8) ----------------------------------------------------

  @doc """
  Returns the Store root directory (design §7.4).

  Resolved from `ATHANOR_HOME`, then `:athanor, :home`, then `~/.athanor`, and always
  `Path.expand/1`ed. Every Store entry point also accepts a per-call `root:` option, which
  wins over this value (that is how tests avoid touching a real user's home directory).
  """
  @spec home() :: String.t()
  def home do
    raw =
      System.get_env("ATHANOR_HOME") ||
        Application.get_env(:athanor, :home, @default_home)

    Path.expand(raw)
  end

  @doc """
  Whether session persistence is enabled (default `true`).

  `ATHANOR_STORE=0` (or `"false"`) disables persistence entirely, as does
  `config :athanor, store_enabled: false`.
  """
  @spec store_enabled?() :: boolean()
  def store_enabled? do
    case System.get_env("ATHANOR_STORE") do
      nil ->
        Application.get_env(:athanor, :store_enabled, @default_store_enabled) != false

      value ->
        normalised = value |> String.trim() |> String.downcase()
        normalised not in ["0", "false", "no", "off"]
    end
  end

  @doc """
  Maximum number of transcript append handles `Athanor.Store.Recorder` keeps open at once
  (default `#{@default_recorder_max_open_fds}`).

  Each handle is one open `transcript.jsonl` file descriptor; a long-lived node writing many
  concurrent sessions would otherwise grow past the process's fd limit. When the cap is
  reached the Recorder closes its least-recently-used handle, and the session's next record
  reopens it lazily (appending still lands at EOF, so ordering is preserved).

  Overridable via `ATHANOR_RECORDER_MAX_OPEN_FDS` or `:athanor, :recorder_max_open_fds`.
  Non-positive or unparseable values fall back to the default.
  """
  @spec recorder_max_open_fds() :: pos_integer()
  def recorder_max_open_fds do
    positive_int(
      "ATHANOR_RECORDER_MAX_OPEN_FDS",
      :recorder_max_open_fds,
      @default_recorder_max_open_fds
    )
  end

  @doc """
  Fraction of the context window at which compaction is triggered (default
  `#{@default_compaction_threshold}`).

  Overridable via `ATHANOR_COMPACTION_THRESHOLD` or `:athanor, :compaction_threshold`.
  Values outside `0.0..1.0` fall back to the default.
  """
  @spec compaction_threshold() :: float()
  def compaction_threshold do
    ratio("ATHANOR_COMPACTION_THRESHOLD", :compaction_threshold, @default_compaction_threshold)
  end

  @doc """
  Model context window in tokens (default `#{@default_context_limit_tokens}`).

  Overridable via `ATHANOR_CONTEXT_LIMIT_TOKENS` or `:athanor, :context_limit_tokens`. The
  default is an estimate pending a real per-model limit (plan OQ4).
  """
  @spec context_limit_tokens() :: pos_integer()
  def context_limit_tokens do
    positive_int(
      "ATHANOR_CONTEXT_LIMIT_TOKENS",
      :context_limit_tokens,
      @default_context_limit_tokens
    )
  end

  @doc """
  Fraction of the context window kept as recent turns after compaction (default
  `#{@default_compaction_keep_fraction}`).

  Overridable via `ATHANOR_COMPACTION_KEEP_FRACTION` or `:athanor, :compaction_keep_fraction`.
  """
  @spec compaction_keep_fraction() :: float()
  def compaction_keep_fraction do
    ratio(
      "ATHANOR_COMPACTION_KEEP_FRACTION",
      :compaction_keep_fraction,
      @default_compaction_keep_fraction
    )
  end

  @doc """
  How aggressively transcript appends are synced to disk:

    * `:per_record` (default) — `:file.datasync/1` after every record
    * `:batched` — the writer may defer `datasync` until a batch boundary

  Resolved from `ATHANOR_TRANSCRIPT_SYNC`, then `:athanor, :transcript_sync`. Unknown values
  fall back to `:per_record`, which is the crash-safe default (plan §5.2).
  """
  @spec transcript_sync() :: :per_record | :batched
  def transcript_sync do
    raw =
      System.get_env("ATHANOR_TRANSCRIPT_SYNC") ||
        Application.get_env(:athanor, :transcript_sync, :per_record)

    case to_string(raw) |> String.trim() |> String.downcase() do
      "batched" -> :batched
      _other -> :per_record
    end
  end

  # Shared float parser for the ratio-shaped Store settings; rejects NaN-ish and
  # out-of-range input rather than propagating a nonsense threshold into compaction.
  defp ratio(env, key, default) do
    raw = System.get_env(env) || Application.get_env(:athanor, key, default)

    case Float.parse(to_string(raw)) do
      {value, _rest} when value > 0.0 and value <= 1.0 -> value
      _other -> default
    end
  end
end
