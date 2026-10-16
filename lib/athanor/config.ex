defmodule Athanor.Config do
  @moduledoc """
  Configuration helper for Athanor's LLM provider (OpenCode Go) and runtime settings.
  """

  @default_base_url "https://opencode.ai/zen/go/v1"
  @default_model "deepseek-v4.1-flash"
  @default_theme :default
  @default_search_max_results 200
  @default_search_max_file_bytes 1_048_576
  @default_project_context_enabled true
  @default_project_context_max_bytes 1_048_576
  @default_home "~/.athanor"
  @default_store_enabled true
  @default_recorder_max_open_fds 64
  @default_compaction_threshold 0.8
  @default_context_limit_tokens 128_000
  @default_compaction_keep_fraction 0.4
  @default_compaction_max_messages 400
  @default_compaction_keep_messages 200
  @default_max_turns :infinity
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
  @default_log_enabled true
  @default_log_max_bytes 5_000_000
  @default_rpc_timeout_ms 15_000
  @default_turn_timeout_ms 900_000
  @default_worktree_root "~/.athanor/worktrees"
  @default_worktree_inside_repo false
  @default_worktree_allow_dirty false
  @default_worktree_git_timeout_ms 30_000
  @default_worktree_branch_prefix "athanor/"

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
  Message-count trigger threshold for pre-flight compaction (default
  `#{@default_compaction_max_messages}`).

  The OpenCode Go upstream enforces a hard ceiling of 512 messages per `/chat/completions`
  request, independent of token count (#37). Compacting at `#{@default_compaction_max_messages}`
  leaves headroom for a multi-step tool loop before the next pre-flight check.

  Overridable via `ATHANOR_COMPACTION_MAX_MESSAGES` or `:athanor, :compaction_max_messages`.
  """
  @spec compaction_max_messages() :: pos_integer()
  def compaction_max_messages do
    positive_int(
      "ATHANOR_COMPACTION_MAX_MESSAGES",
      :compaction_max_messages,
      @default_compaction_max_messages
    )
  end

  @doc """
  Target maximum number of recent messages kept when compacting (default
  `#{@default_compaction_keep_messages}`).

  Overridable via `ATHANOR_COMPACTION_KEEP_MESSAGES` or `:athanor, :compaction_keep_messages`.
  """
  @spec compaction_keep_messages() :: pos_integer()
  def compaction_keep_messages do
    positive_int(
      "ATHANOR_COMPACTION_KEEP_MESSAGES",
      :compaction_keep_messages,
      @default_compaction_keep_messages
    )
  end

  @doc """
  Maximum tool-call turns permitted in a single user prompt before `Athanor.Agent` stops with an
  error (default `#{inspect(@default_max_turns)}` — unbounded, #36).

  Overridable via `ATHANOR_MAX_TURNS` (positive integer, or `"infinity"`) or
  `:athanor, :max_turns`, or per-agent via the `max_turns:` init option.
  """
  @spec max_turns() :: pos_integer() | :infinity
  def max_turns do
    "ATHANOR_MAX_TURNS"
    |> System.get_env()
    |> Kernel.||(Application.get_env(:athanor, :max_turns, @default_max_turns))
    |> parse_max_turns()
  end

  defp parse_max_turns(n) when is_integer(n) and n > 0, do: n
  defp parse_max_turns(raw) when raw in [nil, "", :infinity, "infinity"], do: :infinity

  defp parse_max_turns(raw) do
    case Integer.parse(to_string(raw)) do
      {value, _rest} when value > 0 -> value
      _ -> @default_max_turns
    end
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

  # -- diagnostics & responsiveness (wedge fix) ------------------------------------------

  @doc """
  Whether Athanor writes a diagnostic log to disk (default `true`).

  When enabled, `Athanor.Log` installs a `Logger` handler that appends to
  `<home>/logs/athanor.log`, so a wedged daemon leaves evidence behind instead of vanishing
  into a detached VM's stdout. Disable with `ATHANOR_LOG=0` or `config :athanor, log_enabled:
  false` (tests do this by pointing the log at a scratch `:log_path`).
  """
  @spec log_enabled?() :: boolean()
  def log_enabled? do
    case System.get_env("ATHANOR_LOG") do
      nil ->
        Application.get_env(:athanor, :log_enabled, @default_log_enabled) != false

      value ->
        normalised = value |> String.trim() |> String.downcase()
        normalised not in ["0", "false", "no", "off"]
    end
  end

  @doc """
  Directory that holds Athanor's diagnostic logs (`<home>/logs`).

  Overridable via `:athanor, :log_dir`; resolved through `Athanor.Log` so every writer agrees.
  """
  @spec log_dir() :: String.t()
  def log_dir do
    case Application.get_env(:athanor, :log_dir) do
      dir when is_binary(dir) -> Path.expand(dir)
      _ -> Path.join(home(), "logs")
    end
  end

  @doc """
  Rotate the log file once it exceeds this many bytes (default `#{@default_log_max_bytes}`),
  keeping one previous file (`athanor.log.1`). Overridable via `ATHANOR_LOG_MAX_BYTES` or
  `:athanor, :log_max_bytes`.
  """
  @spec log_max_bytes() :: pos_integer()
  def log_max_bytes do
    positive_int("ATHANOR_LOG_MAX_BYTES", :log_max_bytes, @default_log_max_bytes)
  end

  @doc """
  Timeout, in milliseconds, for every TUI→daemon RPC (default `#{@default_rpc_timeout_ms}`).

  `Athanor.Daemon.rpc/4` passes this to `:erpc.call/5`; without it `:erpc.call/4`'s default
  is `:infinity`, so a wedged or unreachable-but-connected daemon would block the caller
  (the single TUI loop process) forever — one of the confirmed wedge causes. Overridable via
  `ATHANOR_RPC_TIMEOUT_MS` or `:athanor, :rpc_timeout_ms`. A non-positive value falls back to
  the default, so the timeout can never be disabled by accident.
  """
  @spec rpc_timeout_ms() :: pos_integer()
  def rpc_timeout_ms do
    positive_int("ATHANOR_RPC_TIMEOUT_MS", :rpc_timeout_ms, @default_rpc_timeout_ms)
  end

  @doc """
  Watchdog deadline, in milliseconds, for one agent turn (default `#{@default_turn_timeout_ms}`).

  `Athanor.Agent` arms a timer when it starts an LLM stream or tool-execution task; if no
  result arrives within this window the task is killed and the session transitions to `:error`
  with a logged reason, instead of staying `:streaming`/`:executing_tools` forever (the
  confirmed "stuck turn" state). It must comfortably exceed the transport's own timeouts
  (LLM `receive_timeout` 120 s, bash 30 s) so it only fires on a genuine hang. Overridable via
  `ATHANOR_TURN_TIMEOUT_MS` or `:athanor, :turn_timeout_ms`.
  """
  @spec turn_timeout_ms() :: pos_integer()
  def turn_timeout_ms do
    positive_int("ATHANOR_TURN_TIMEOUT_MS", :turn_timeout_ms, @default_turn_timeout_ms)
  end

  @doc """
  Root directory for sub-agent git worktrees (default `#{@default_worktree_root}`).

  `Athanor.Worktree.root_for/2` places each session at
  `<worktree_root>/<repo-slug>-<repo-hash>/<session_id>`. Always `Path.expand/1`ed so a literal
  `~` can never reach the filesystem. Overridable via `ATHANOR_WORKTREE_ROOT` or
  `:athanor, :worktree_root`.
  """
  @spec worktree_root() :: String.t()
  def worktree_root do
    (System.get_env("ATHANOR_WORKTREE_ROOT") ||
       Application.get_env(:athanor, :worktree_root, @default_worktree_root))
    |> Path.expand()
  end

  @doc """
  Whether session worktrees live inside the repository (`<repo>/.athanor/worktrees/<session_id>`)
  instead of under `worktree_root/0` (default `#{@default_worktree_inside_repo}`).

  Git permits a nested worktree, but the parent's `git status` then shows it as untracked and
  parent-relative searches walk into it, so the create path requires this location to be
  gitignored. Overridable via `ATHANOR_WORKTREE_INSIDE` or `:athanor, :worktree_inside_repo`.
  """
  @spec worktree_inside_repo?() :: boolean()
  def worktree_inside_repo? do
    boolean_env("ATHANOR_WORKTREE_INSIDE", :worktree_inside_repo, @default_worktree_inside_repo)
  end

  @doc """
  Whether a worktree may be created from a repository with uncommitted changes
  (default `#{@default_worktree_allow_dirty}`).

  A worktree branches from committed `HEAD`, so a dirty source repo means the worker silently
  cannot see the user's in-flight edits — refused by default. Overridable via
  `ATHANOR_WORKTREE_ALLOW_DIRTY` or `:athanor, :worktree_allow_dirty`.
  """
  @spec worktree_allow_dirty?() :: boolean()
  def worktree_allow_dirty? do
    boolean_env(
      "ATHANOR_WORKTREE_ALLOW_DIRTY",
      :worktree_allow_dirty,
      @default_worktree_allow_dirty
    )
  end

  @doc """
  Timeout, in milliseconds, for every `git` invocation made by `Athanor.Git`
  (default `#{@default_worktree_git_timeout_ms}`).

  Overridable via `ATHANOR_WORKTREE_GIT_TIMEOUT_MS` or `:athanor, :worktree_git_timeout_ms`.
  """
  @spec worktree_git_timeout_ms() :: pos_integer()
  def worktree_git_timeout_ms do
    positive_int(
      "ATHANOR_WORKTREE_GIT_TIMEOUT_MS",
      :worktree_git_timeout_ms,
      @default_worktree_git_timeout_ms
    )
  end

  @doc """
  Prefix for the branch a session's worktree is created on (default `"#{@default_worktree_branch_prefix}"`).

  Unique per session on purpose: `git worktree add -b` fails if the branch exists, and a branch
  already checked out elsewhere cannot be checked out again. Overridable via
  `ATHANOR_WORKTREE_BRANCH_PREFIX` or `:athanor, :worktree_branch_prefix`.
  """
  @spec worktree_branch_prefix() :: String.t()
  def worktree_branch_prefix do
    System.get_env("ATHANOR_WORKTREE_BRANCH_PREFIX") ||
      Application.get_env(:athanor, :worktree_branch_prefix, @default_worktree_branch_prefix)
  end

  # -- project context (AGENTS.md, #33) --------------------------------------------------

  @doc """
  Whether `Athanor.Agent` injects a project's `AGENTS.md` into the system prompt
  (default `#{@default_project_context_enabled}`).

  `ATHANOR_PROJECT_CONTEXT=0` (or `"false"`) disables injection, as does
  `config :athanor, project_context: false`. Mirrors `store_enabled?/0`'s toggle shape — the
  whole point is a single switch a user can throw when a repo's instructions are unhelpful or
  untrusted, without editing code. An explicit `:project_context` init option on the Agent wins
  over this value.
  """
  @spec project_context_enabled?() :: boolean()
  def project_context_enabled? do
    case System.get_env("ATHANOR_PROJECT_CONTEXT") do
      nil ->
        Application.get_env(:athanor, :project_context, @default_project_context_enabled) != false

      value ->
        normalised = value |> String.trim() |> String.downcase()
        normalised not in ["0", "false", "no", "off"]
    end
  end

  @doc """
  Maximum number of bytes of an `AGENTS.md` that `Athanor.ProjectContext` will inject
  (default `#{@default_project_context_max_bytes}`).

  Follows the `search_max_file_bytes/0` idiom — the file is human-authored and can hold the
  whole repo's conventions, but it is still bounded so a pathological file cannot blow the
  context window before compaction ever runs. Over-limit content is truncated with a visible
  marker, never silently. Overridable via `ATHANOR_PROJECT_CONTEXT_MAX_BYTES` or
  `:athanor, :project_context_max_bytes`.
  """
  @spec project_context_max_bytes() :: pos_integer()
  def project_context_max_bytes do
    positive_int(
      "ATHANOR_PROJECT_CONTEXT_MAX_BYTES",
      :project_context_max_bytes,
      @default_project_context_max_bytes
    )
  end

  defp boolean_env(env, key, default) do
    case System.get_env(env) || Application.get_env(:athanor, key, default) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(value) in ["1", "true", "yes", "on"]
      _ -> default
    end
  end
end
