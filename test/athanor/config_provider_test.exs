defmodule Athanor.Config.ProviderTest do
  # `async: false` on purpose: `provider/0` and its neighbours are read from process-global
  # environment, so a test that sets `ATHANOR_PROVIDER` must not run beside one that does not.
  # ExUnit runs every async module before any sync module, so this cannot leak into a concurrent
  # test either.
  use ExUnit.Case, async: false

  alias Athanor.Config

  @env_vars [
    "ATHANOR_PROVIDER",
    "ATHANOR_CLAUDE_CLI",
    "ATHANOR_CLAUDE_CONFIG_DIR",
    "ATHANOR_CLAUDE_MODEL"
  ]

  setup do
    previous = Map.new(@env_vars, &{&1, System.get_env(&1)})
    application = Application.get_env(:athanor, :provider)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case application do
        nil -> Application.delete_env(:athanor, :provider)
        value -> Application.put_env(:athanor, :provider, value)
      end
    end)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:athanor, :provider)
    :ok
  end

  test "defaults to :opencode with nothing configured" do
    assert Config.provider() == :opencode
  end

  test "ATHANOR_PROVIDER selects the backend, case- and space-insensitively" do
    for value <- ["claude", "CLAUDE", "  Claude  ", "claude-oauth"] do
      System.put_env("ATHANOR_PROVIDER", value)
      assert Config.provider() == :claude, "expected #{inspect(value)} to select :claude"
    end

    for value <- ["opencode", "OpenCode", "opencode-go"] do
      System.put_env("ATHANOR_PROVIDER", value)
      assert Config.provider() == :opencode, "expected #{inspect(value)} to select :opencode"
    end
  end

  test "an unknown value falls back to :opencode and says so, rather than raising" do
    # Falling back is deliberate: this is read on the hot path of every session start, including
    # in a detached daemon where a raise would be a mystery start-up failure. The warning is the
    # contract, so it is asserted rather than assumed.
    System.put_env("ATHANOR_PROVIDER", "gpt5")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Config.provider() == :opencode
      end)

    assert log =~ "unknown ATHANOR_PROVIDER"
    assert log =~ "\"gpt5\""
  end

  test "an empty ATHANOR_PROVIDER is unknown, not a crash" do
    System.put_env("ATHANOR_PROVIDER", "")

    log = ExUnit.CaptureLog.capture_log(fn -> assert Config.provider() == :opencode end)
    assert log =~ "unknown ATHANOR_PROVIDER"
  end

  test "the :athanor application config is used when the environment is not set" do
    Application.put_env(:athanor, :provider, :claude)
    assert Config.provider() == :claude
  end

  test "the environment wins over application config" do
    Application.put_env(:athanor, :provider, :claude)
    System.put_env("ATHANOR_PROVIDER", "opencode")
    assert Config.provider() == :opencode
  end

  describe "claude settings" do
    test "the CLI path is a bare command by default, and expands only real paths" do
      assert Config.claude_cli_path() == "claude"

      System.put_env("ATHANOR_CLAUDE_CLI", "~/.local/bin/claude")
      assert Config.claude_cli_path() == Path.expand("~/.local/bin/claude")

      System.put_env("ATHANOR_CLAUDE_CLI", "my-claude")
      assert Config.claude_cli_path() == "my-claude"
    end

    test "the config dir is expanded, so a literal ~ never reaches the filesystem" do
      System.put_env("ATHANOR_CLAUDE_CONFIG_DIR", "~/.claude_personal")
      expanded = Config.claude_config_dir()

      assert expanded == Path.expand("~/.claude_personal")
      refute expanded =~ "~"
    end

    test "a default config dir exists so the CLI can be pointed somewhere explicit" do
      assert Config.claude_config_dir() == Path.expand("~/.claude")
    end

    test "the Claude model is nil unless set, and blank counts as unset" do
      assert Config.claude_model() == nil

      System.put_env("ATHANOR_CLAUDE_MODEL", "   ")
      assert Config.claude_model() == nil

      System.put_env("ATHANOR_CLAUDE_MODEL", " sonnet ")
      assert Config.claude_model() == "sonnet"
    end

    test "the Claude model is separate from the OpenCode model" do
      # Different namespaces: an OpenCode id must never be handed to `claude --model`.
      Application.put_env(:athanor, :model, "deepseek-v4.1-flash")

      on_exit(fn -> Application.delete_env(:athanor, :model) end)

      assert Config.model() == "deepseek-v4.1-flash"
      assert Config.claude_model() == nil
    end
  end
end
