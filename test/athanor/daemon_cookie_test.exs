defmodule Athanor.DaemonCookieTest do
  use ExUnit.Case, async: false

  alias Athanor.Daemon

  # The cookie is persisted under `Athanor.Config.home/0`; every test points that at its own tmp
  # dir so nothing writes into the real `~/.athanor`.
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous_home = System.get_env("ATHANOR_HOME")
    previous_cookie = System.get_env("ATHANOR_COOKIE")
    previous_config = Application.get_env(:athanor, :cookie)

    System.put_env("ATHANOR_HOME", dir)
    System.delete_env("ATHANOR_COOKIE")
    Application.delete_env(:athanor, :cookie)

    on_exit(fn ->
      restore_env("ATHANOR_HOME", previous_home)
      restore_env("ATHANOR_COOKIE", previous_cookie)

      if previous_config do
        Application.put_env(:athanor, :cookie, previous_config)
      else
        Application.delete_env(:athanor, :cookie)
      end
    end)

    {:ok, home: dir}
  end

  test "generates and persists a cookie on first use, then reuses it", %{home: home} do
    path = Path.join(home, "cookie")
    refute File.exists?(path)

    first = Daemon.cookie()

    assert File.exists?(path), "expected the cookie to be written to #{path}"
    # 256 bits, hex encoded
    assert first |> Atom.to_string() |> String.length() == 64
    assert first |> Atom.to_string() |> String.match?(~r/^[0-9a-f]{64}$/)

    # persisted, and readable back verbatim
    assert File.read!(path) == Atom.to_string(first)
    assert Daemon.cookie() == first
  end

  test "writes the cookie file with 0600 permissions", %{home: home} do
    Daemon.cookie()

    mode = File.stat!(Path.join(home, "cookie")).mode
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "creates the home directory when it does not exist", %{home: home} do
    nested = Path.join(home, "fresh/nested")
    System.put_env("ATHANOR_HOME", nested)

    assert Daemon.cookie()
    assert File.exists?(Path.join(nested, "cookie"))
  end

  test "honours an existing cookie file" do
    home = System.get_env("ATHANOR_HOME")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "cookie"), "preexisting-cookie\n")

    assert Daemon.cookie() == :"preexisting-cookie"
  end

  test "ATHANOR_COOKIE takes precedence and writes no file", %{home: home} do
    System.put_env("ATHANOR_COOKIE", "from-env")

    assert Daemon.cookie() == :"from-env"
    refute File.exists?(Path.join(home, "cookie"))
  end

  test "application config is used when the env var is absent", %{home: home} do
    Application.put_env(:athanor, :cookie, :"from-config")

    assert Daemon.cookie() == :"from-config"
    refute File.exists?(Path.join(home, "cookie"))
  end

  test "no hardcoded default cookie remains in the source" do
    source = File.read!("lib/athanor/daemon.ex")

    # A published default is a publicly-known shared secret; the module must generate instead.
    refute source =~ "athanor_local_secret_cookie"
    assert source =~ ":crypto.strong_rand_bytes"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
