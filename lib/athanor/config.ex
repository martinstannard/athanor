defmodule Athanor.Config do
  @moduledoc """
  Configuration helper for Athanor's LLM provider (OpenCode Go) and runtime settings.
  """

  @default_base_url "https://opencode.ai/zen/go/v1"
  @default_model "deepseek-v4.1-flash"
  @default_theme :default
  @default_search_max_results 200
  @default_search_max_file_bytes 1_048_576
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
end
