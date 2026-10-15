defmodule Athanor.ThemeTest do
  # async: false — these tests mutate ATHANOR_THEME / ATHANOR_THEME_MODE globally.
  use ExUnit.Case, async: false

  alias Athanor.{Markdown, Theme}

  test "every built-in theme defines every role" do
    for theme <- Theme.themes() do
      for role <- Theme.roles() do
        assert Theme.colour(theme, role),
               "theme #{theme.key} is missing role #{inspect(role)}"
      end
    end
  end

  test "ships the default plus a dozen popular themes" do
    keys = Theme.keys()

    assert :default in keys
    assert length(keys) >= 13, "expected at least 13 themes, got #{length(keys)}"

    for key <- [
          :dracula,
          :nord,
          :gruvbox_dark,
          :gruvbox_light,
          :tokyo_night,
          :catppuccin_mocha,
          :one_dark,
          :solarized_dark,
          :solarized_light,
          :monokai,
          :everforest_dark,
          :kanagawa,
          :github_light
        ] do
      assert key in keys
    end

    assert Enum.any?(Theme.themes(), &(&1.dark? == false)), "expected at least one light theme"
  end

  test "get/1 accepts forgiving spellings and falls back to default" do
    assert Theme.get(:dracula).key == :dracula
    assert Theme.get("Dracula").key == :dracula
    assert Theme.get("tokyo-night").key == :tokyo_night
    assert Theme.get("Tokyo Night").key == :tokyo_night
    assert Theme.get("solarized_light").key == :solarized_light
    assert Theme.get("Solarized Light").key == :solarized_light
    assert Theme.get("gruvbox_dark").key == :gruvbox_dark
    assert Theme.get("gruvbox").key == :gruvbox_dark
    assert Theme.get("catppuccin").key == :catppuccin_mocha
    assert Theme.get("nonsense").key == :default
    assert Theme.get(nil).key == :default
  end

  test "every theme key resolves from its own label and key" do
    for theme <- Theme.themes() do
      assert Theme.get(theme.key).key == theme.key
      assert Theme.get(Atom.to_string(theme.key)).key == theme.key
      assert Theme.get(theme.label).key == theme.key
    end
  end

  test "fetch/1 distinguishes unknown names from the default theme" do
    assert {:ok, %Theme{key: :nord}} = Theme.fetch("nord")
    assert :error = Theme.fetch("definitely-not-a-theme")
  end

  test "resolve/1 uses ATHANOR_THEME when no name is given" do
    previous = System.get_env("ATHANOR_THEME")

    try do
      System.put_env("ATHANOR_THEME", "kanagawa")
      assert Theme.resolve(nil).key == :kanagawa
      assert Theme.resolve("nord").key == :nord
    after
      if previous,
        do: System.put_env("ATHANOR_THEME", previous),
        else: System.delete_env("ATHANOR_THEME")
    end
  end

  test "hex colours encode to truecolor tuples by default" do
    dracula = Theme.get(:dracula)

    assert Theme.colour(dracula, :heading_1) == {0xFF, 0x79, 0xC6}
    assert Theme.colour(dracula, :error) == {0xFF, 0x55, 0x55}
  end

  test "hex colours quantise to xterm-256 indices in :ansi256 mode" do
    theme = %{Theme.get(:dracula) | mode: :ansi256}

    assert Theme.colour(theme, :error) == Theme.hex_to_ansi256("#FF5555")

    for role <- Theme.roles() do
      assert is_integer(Theme.colour(theme, role))
    end
  end

  test "resolve/1 sets the mode from config and ATHANOR_THEME_MODE" do
    previous_theme = System.get_env("ATHANOR_THEME")
    previous_mode = System.get_env("ATHANOR_THEME_MODE")

    try do
      System.put_env("ATHANOR_THEME", "kanagawa")
      System.put_env("ATHANOR_THEME_MODE", "ansi256")

      assert Theme.resolve(nil).key == :kanagawa
      assert Theme.resolve(nil).mode == :ansi256

      System.delete_env("ATHANOR_THEME_MODE")
      assert Theme.resolve("dracula").mode == :truecolor

      # get/1 keeps the theme's declared mode, independent of config
      assert Theme.get("dracula").mode == :truecolor
      assert Theme.get("default").mode == :ansi256
    after
      if previous_theme,
        do: System.put_env("ATHANOR_THEME", previous_theme),
        else: System.delete_env("ATHANOR_THEME")

      if previous_mode,
        do: System.put_env("ATHANOR_THEME_MODE", previous_mode),
        else: System.delete_env("ATHANOR_THEME_MODE")
    end
  end

  test "hex_to_ansi256 matches the xterm palette for known colours" do
    assert Theme.hex_to_ansi256("#FFFFFF") == 231
    assert Theme.hex_to_ansi256("#000000") == 16
    assert Theme.hex_to_ansi256("#FF0000") == 196
    assert Theme.hex_to_ansi256("#808080") == 244
  end

  test "the default theme reproduces the original Athanor palette exactly" do
    theme = Theme.default()

    assert theme.mode == :ansi256
    assert Theme.colour(theme, :surface) == 236
    assert Theme.colour(theme, :accent) == 214
    assert Theme.colour(theme, :user) == 117
    assert Theme.colour(theme, :success) == 114
    assert Theme.colour(theme, :error) == 203
    assert Theme.colour(theme, :code_fg) == 81
    assert Theme.colour(theme, :code_bg) == 236
  end

  test "colour!/2 raises for an unknown role" do
    assert_raise ArgumentError, fn -> Theme.colour!(Theme.default(), :nope) end
  end

  describe "Markdown integration" do
    test "render/2 keeps the default legacy colours" do
      [line] = Markdown.render("`code`", 40)
      assert line =~ "38;5;81"
      assert line =~ "48;5;236"
    end

    test "render/3 colours headings with the supplied theme" do
      theme = Theme.get(:dracula)
      {r, g, b} = Theme.colour!(theme, :heading_1)

      [line] = Markdown.render("# Title", 40, theme)
      assert line =~ "38;2;#{r};#{g};#{b}"
    end

    test "the same markdown renders differently under different themes" do
      default = Markdown.render("> quoted", 40)
      dracula = Markdown.render("> quoted", 40, Theme.get(:dracula))

      refute default == dracula
    end

    test "tables, lists, rules and links all pick up the theme" do
      theme = Theme.get(:gruvbox_dark)
      {r, g, b} = Theme.colour!(theme, :link)

      [link_line] = Markdown.render("see [docs](https://example.com)", 60, theme)
      assert link_line =~ "38;2;#{r};#{g};#{b}"

      md = """
      - item
      ---
      """

      lines = Markdown.render(md, 40, theme)
      assert length(lines) >= 2
      assert Enum.any?(lines, &(&1 =~ "38;2;"))
      assert Enum.any?(lines, &(&1 =~ "•"))
    end
  end
end
