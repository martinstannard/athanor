defmodule Athanor.Theme do
  @moduledoc """
  Colour themes for the Athanor TUI and Markdown renderer.

  A theme maps a fixed set of **semantic roles** (`:text`, `:accent`, `:error`, …)
  to colours. Renderers never hard-code a colour: they ask the theme for a role, so
  swapping themes restyles the whole interface — deck sidebar, status bar, streaming
  output, and Markdown (headings, code, links, tables) — at once.

  Colours are declared as `#RRGGBB` hex (the authentic palettes of each popular
  theme) and encoded at render time:

    * `mode: :truecolor` (default) → a `{r, g, b}` tuple (24-bit SGR).
    * `mode: :ansi256` → the nearest xterm-256 palette index.

  The `:default` theme instead uses raw 256-colour indices and reproduces Athanor's
  original hard-coded palette exactly, so the out-of-the-box look is unchanged.

  ## Selecting a theme

      ATHANOR_THEME=dracula mix athanor
      mix athanor --theme "gruvbox dark"
      config :athanor, theme: :tokyo_night

  Inside the TUI, `/theme` lists the themes and `/theme <name>` switches live.
  """

  alias Athanor.Config

  @type role ::
          :bg
          | :surface
          | :selection_bg
          | :border
          | :text
          | :muted
          | :table_cell
          | :accent
          | :selected_fg
          | :user
          | :assistant
          | :tool
          | :system
          | :success
          | :warning
          | :error
          | :info
          | :code_fg
          | :code_bg
          | :link
          | :link_url
          | :bullet
          | :heading_1
          | :heading_2
          | :heading_3
          | :heading_4
          | :heading_5
          | :heading_6

  @type colour :: non_neg_integer() | {0..255, 0..255, 0..255}

  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          dark?: boolean(),
          mode: :truecolor | :ansi256,
          roles: %{role() => String.t() | non_neg_integer()}
        }

  @enforce_keys [:key, :label, :roles]
  defstruct [:key, :label, dark?: true, mode: :truecolor, roles: %{}]

  @roles [
    :bg,
    :surface,
    :selection_bg,
    :border,
    :text,
    :muted,
    :table_cell,
    :accent,
    :selected_fg,
    :user,
    :assistant,
    :tool,
    :system,
    :success,
    :warning,
    :error,
    :info,
    :code_fg,
    :code_bg,
    :link,
    :link_url,
    :bullet,
    :heading_1,
    :heading_2,
    :heading_3,
    :heading_4,
    :heading_5,
    :heading_6
  ]

  # Convenience aliases so `--theme gruvbox` and friends do the obvious thing.
  @aliases %{
    "gruvbox" => :gruvbox_dark,
    "gruvboxdark" => :gruvbox_dark,
    "gruvboxlight" => :gruvbox_light,
    "catppuccin" => :catppuccin_mocha,
    "mocha" => :catppuccin_mocha,
    "tokyo" => :tokyo_night,
    "tokyonight" => :tokyo_night,
    "onedark" => :one_dark,
    "solarized" => :solarized_dark,
    "everforest" => :everforest_dark,
    "github" => :github_light
  }

  @doc "All semantic roles a theme must define."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "All built-in themes, `:default` first."
  @spec themes() :: [t()]
  def themes do
    [
      default_theme(),
      dracula(),
      nord(),
      gruvbox_dark(),
      gruvbox_light(),
      tokyo_night(),
      catppuccin_mocha(),
      one_dark(),
      solarized_dark(),
      solarized_light(),
      monokai(),
      everforest_dark(),
      kanagawa(),
      github_light()
    ]
  end

  @doc "Returns `[{key, label, dark?}]` for menus and `/theme`."
  @spec list() :: [{atom(), String.t(), boolean()}]
  def list, do: Enum.map(themes(), &{&1.key, &1.label, &1.dark?})

  @doc "All valid theme keys."
  @spec keys() :: [atom()]
  def keys, do: Enum.map(themes(), & &1.key)

  @doc "The built-in default theme (original Athanor palette, unchanged)."
  @spec default() :: t()
  def default, do: default_theme()

  @doc """
  Looks a theme up by key, label, or a forgiving spelling (`"gruvbox dark"`,
  `"Tokyo-Night"`, `:onedark`). Falls back to the default theme for `nil` or an
  unknown name.
  """
  @spec get(atom() | String.t() | nil) :: t()
  def get(nil), do: default()

  def get(name) when is_atom(name) or is_binary(name) do
    case fetch(name) do
      {:ok, theme} -> theme
      :error -> default()
    end
  end

  @doc """
  Like `get/1` but distinguishes an unknown name from the default theme.
  """
  @spec fetch(atom() | String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_atom(name) or is_binary(name) do
    wanted = normalize(name)

    key =
      case Enum.find(themes(), &(&1.key == wanted)) do
        nil -> Map.get(@aliases, Atom.to_string(wanted))
        theme -> theme.key
      end

    case key && Enum.find(themes(), &(&1.key == key)) do
      nil -> :error
      theme -> {:ok, theme}
    end
  end

  @doc """
  Resolves a theme from an explicit name, otherwise `ATHANOR_THEME`, otherwise
  application config, otherwise the default theme.
  """
  @spec resolve(atom() | String.t() | nil) :: t()
  def resolve(nil), do: get(configured()) |> with_configured_mode()
  def resolve(name), do: get(name) |> with_configured_mode()

  defp with_configured_mode(theme), do: %{theme | mode: Config.theme_mode()}

  @doc "The theme name configured via env or application config."
  @spec configured() :: atom() | String.t()
  def configured, do: Config.theme()

  @doc """
  Returns the `{r, g, b}` tuple or 256-colour index for `role`, encoded for the
  theme's `:mode`. Integers pass through untouched (used by `:default`).
  """
  @spec colour(t(), role()) :: colour() | nil
  def colour(%__MODULE__{roles: roles} = theme, role) do
    case Map.get(roles, role) do
      nil -> nil
      value when is_integer(value) -> value
      "#" <> _ = hex -> encode(hex, theme.mode)
    end
  end

  @doc "Same as `colour/2` but raises if the role is missing."
  @spec colour!(t(), role()) :: colour()
  def colour!(theme, role) do
    colour(theme, role) ||
      raise ArgumentError, "theme #{theme.key} is missing role #{inspect(role)}"
  end

  @doc "Parses `#RRGGBB` into an `{r, g, b}` tuple."
  @spec hex_to_rgb(String.t()) :: {0..255, 0..255, 0..255}
  def hex_to_rgb("#" <> hex) do
    case hex do
      <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> ->
        {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}

      _ ->
        raise ArgumentError, "expected #RRGGBB, got: ##{hex}"
    end
  end

  @doc """
  Quantises `#RRGGBB` to the nearest xterm-256 index (greyscale ramp + 6×6×6 cube).
  """
  @spec hex_to_ansi256(String.t()) :: 0..255
  def hex_to_ansi256(hex), do: rgb_to_ansi256(hex_to_rgb(hex))

  @doc "Quantises an `{r, g, b}` tuple to the nearest xterm-256 index."
  @spec rgb_to_ansi256({0..255, 0..255, 0..255}) :: 0..255
  def rgb_to_ansi256({r, g, b}) when r == g and g == b do
    cond do
      r < 8 -> 16
      r > 248 -> 231
      true -> div(r - 8, 10) + 232
    end
  end

  def rgb_to_ansi256({r, g, b}) do
    16 + 36 * cube_index(r) + 6 * cube_index(g) + cube_index(b)
  end

  defp cube_index(value), do: round(value / 255 * 5)

  defp encode(hex, :truecolor), do: hex_to_rgb(hex)
  defp encode(hex, :ansi256), do: hex_to_ansi256(hex)

  defp normalize(name) when is_atom(name), do: name

  defp normalize(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end

  # -- Theme definitions -----------------------------------------------------

  # The original Athanor palette, expressed as roles. Uses raw 256-colour indices
  # so existing rendering is byte-for-byte identical.
  defp default_theme do
    %__MODULE__{
      key: :default,
      label: "Athanor (default)",
      dark?: true,
      mode: :ansi256,
      roles: %{
        bg: 235,
        surface: 236,
        selection_bg: 237,
        border: 238,
        text: 252,
        muted: 244,
        table_cell: 250,
        accent: 214,
        selected_fg: 214,
        user: 117,
        assistant: 214,
        tool: 245,
        system: 244,
        success: 114,
        warning: 214,
        error: 203,
        info: 81,
        code_fg: 81,
        code_bg: 236,
        link: 75,
        link_url: 244,
        bullet: 214,
        heading_1: 214,
        heading_2: 220,
        heading_3: 81,
        heading_4: 141,
        heading_5: 111,
        heading_6: 246
      }
    }
  end

  # Builds a theme from a compact palette: `:bg`, `:surface`, `:selection`,
  # `:comment`, `:fg`, plus the eight accent hues.
  defp from_palette(key, label, dark?, p) do
    roles = %{
      bg: p[:bg],
      surface: p[:surface],
      selection_bg: p[:selection],
      border: p[:border] || p[:selection],
      text: p[:fg],
      muted: p[:comment],
      table_cell: p[:dim] || p[:comment],
      accent: p[:blue],
      selected_fg: p[:bright] || p[:blue],
      user: p[:blue],
      assistant: p[:yellow],
      tool: p[:comment],
      system: p[:comment],
      success: p[:green],
      warning: p[:yellow],
      error: p[:red],
      info: p[:cyan],
      code_fg: p[:cyan],
      code_bg: p[:surface],
      link: p[:blue],
      link_url: p[:comment],
      bullet: p[:blue],
      heading_1: p[:purple],
      heading_2: p[:blue],
      heading_3: p[:cyan],
      heading_4: p[:yellow],
      heading_5: p[:green],
      heading_6: p[:comment]
    }

    %__MODULE__{key: key, label: label, dark?: dark?, mode: :truecolor, roles: roles}
  end

  defp dracula do
    from_palette(:dracula, "Dracula", true, %{
      bg: "#282A36",
      surface: "#343746",
      selection: "#44475A",
      comment: "#6272A4",
      dim: "#A9A9B3",
      fg: "#F8F8F2",
      bright: "#FFFFFF",
      red: "#FF5555",
      orange: "#FFB86C",
      yellow: "#F1FA8C",
      green: "#50FA7B",
      cyan: "#8BE9FD",
      blue: "#BD93F9",
      purple: "#FF79C6"
    })
  end

  defp nord do
    from_palette(:nord, "Nord", true, %{
      bg: "#2E3440",
      surface: "#3B4252",
      selection: "#434C5E",
      comment: "#616E88",
      dim: "#7B88A1",
      fg: "#D8DEE9",
      bright: "#ECEFF4",
      red: "#BF616A",
      orange: "#D08770",
      yellow: "#EBCB8B",
      green: "#A3BE8C",
      cyan: "#88C0D0",
      blue: "#81A1C1",
      purple: "#B48EAD"
    })
  end

  defp gruvbox_dark do
    from_palette(:gruvbox_dark, "Gruvbox Dark", true, %{
      bg: "#282828",
      surface: "#3C3836",
      selection: "#504945",
      comment: "#928374",
      dim: "#D5C4A1",
      fg: "#EBDBB2",
      bright: "#FBF1C7",
      red: "#FB4934",
      orange: "#FE8019",
      yellow: "#FABD2F",
      green: "#B8BB26",
      cyan: "#8EC07C",
      blue: "#83A598",
      purple: "#D3869B"
    })
  end

  defp gruvbox_light do
    from_palette(:gruvbox_light, "Gruvbox Light", false, %{
      bg: "#FBF1C7",
      surface: "#EBDBB2",
      selection: "#D5C4A1",
      comment: "#928374",
      dim: "#7C6F64",
      fg: "#3C3836",
      bright: "#282828",
      red: "#9D0006",
      orange: "#AF3A03",
      yellow: "#B57614",
      green: "#79740E",
      cyan: "#427B58",
      blue: "#076678",
      purple: "#8F3F71"
    })
  end

  defp tokyo_night do
    from_palette(:tokyo_night, "Tokyo Night", true, %{
      bg: "#1A1B26",
      surface: "#24283B",
      selection: "#292E42",
      comment: "#565F89",
      dim: "#737AA2",
      fg: "#C0CAF5",
      bright: "#FFFFFF",
      red: "#F7768E",
      orange: "#FF9E64",
      yellow: "#E0AF68",
      green: "#9ECE6A",
      cyan: "#7DCFFF",
      blue: "#7AA2F7",
      purple: "#BB9AF7"
    })
  end

  defp catppuccin_mocha do
    from_palette(:catppuccin_mocha, "Catppuccin Mocha", true, %{
      bg: "#1E1E2E",
      surface: "#313244",
      selection: "#45475A",
      comment: "#6C7086",
      dim: "#7F849C",
      fg: "#CDD6F4",
      bright: "#FFFFFF",
      red: "#F38BA8",
      orange: "#FAB387",
      yellow: "#F9E2AF",
      green: "#A6E3A1",
      cyan: "#94E2D5",
      blue: "#89B4FA",
      purple: "#CBA6F7"
    })
  end

  defp one_dark do
    from_palette(:one_dark, "One Dark", true, %{
      bg: "#282C34",
      surface: "#21252B",
      selection: "#3E4451",
      comment: "#5C6370",
      dim: "#828997",
      fg: "#ABB2BF",
      bright: "#FFFFFF",
      red: "#E06C75",
      orange: "#D19A66",
      yellow: "#E5C07B",
      green: "#98C379",
      cyan: "#56B6C2",
      blue: "#61AFEF",
      purple: "#C678DD"
    })
  end

  defp solarized_dark do
    from_palette(:solarized_dark, "Solarized Dark", true, %{
      bg: "#002B36",
      surface: "#073642",
      selection: "#0A4A5A",
      comment: "#586E75",
      dim: "#657B83",
      fg: "#839496",
      bright: "#FDF6E3",
      red: "#DC322F",
      orange: "#CB4B16",
      yellow: "#B58900",
      green: "#859900",
      cyan: "#2AA198",
      blue: "#268BD2",
      purple: "#6C71C4"
    })
  end

  defp solarized_light do
    from_palette(:solarized_light, "Solarized Light", false, %{
      bg: "#FDF6E3",
      surface: "#EEE8D5",
      selection: "#DDD6C1",
      comment: "#93A1A1",
      dim: "#839496",
      fg: "#657B83",
      bright: "#073642",
      red: "#DC322F",
      orange: "#CB4B16",
      yellow: "#B58900",
      green: "#859900",
      cyan: "#2AA198",
      blue: "#268BD2",
      purple: "#6C71C4"
    })
  end

  defp monokai do
    from_palette(:monokai, "Monokai", true, %{
      bg: "#272822",
      surface: "#383830",
      selection: "#49483E",
      comment: "#75715E",
      dim: "#A59F85",
      fg: "#F8F8F2",
      bright: "#FFFFFF",
      red: "#F92672",
      orange: "#FD971F",
      yellow: "#E6DB74",
      green: "#A6E22E",
      cyan: "#66D9EF",
      blue: "#66D9EF",
      purple: "#AE81FF"
    })
  end

  defp everforest_dark do
    from_palette(:everforest_dark, "Everforest Dark", true, %{
      bg: "#2B3339",
      surface: "#323C41",
      selection: "#3A454A",
      comment: "#7A8478",
      dim: "#859289",
      fg: "#D3C6AA",
      bright: "#FDF6E3",
      red: "#E67E80",
      orange: "#E69875",
      yellow: "#DBBC7F",
      green: "#A7C080",
      cyan: "#83C092",
      blue: "#7FBBB3",
      purple: "#D699B6"
    })
  end

  defp kanagawa do
    from_palette(:kanagawa, "Kanagawa", true, %{
      bg: "#1F1F28",
      surface: "#2A2A37",
      selection: "#363646",
      comment: "#727169",
      dim: "#C8C093",
      fg: "#DCD7BA",
      bright: "#FFFFF0",
      red: "#E82424",
      orange: "#FF9E3B",
      yellow: "#E6C384",
      green: "#98BB6C",
      cyan: "#6A9589",
      blue: "#7E9CD8",
      purple: "#957FB8"
    })
  end

  defp github_light do
    from_palette(:github_light, "GitHub Light", false, %{
      bg: "#FFFFFF",
      surface: "#F6F8FA",
      selection: "#EAEEF2",
      comment: "#6E7781",
      dim: "#57606A",
      fg: "#24292F",
      bright: "#000000",
      red: "#CF222E",
      orange: "#BC4C00",
      yellow: "#9A6700",
      green: "#116329",
      cyan: "#1B7C83",
      blue: "#0969DA",
      purple: "#8250DF"
    })
  end
end
