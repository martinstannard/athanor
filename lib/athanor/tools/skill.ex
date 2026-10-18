defmodule Athanor.Tools.Skill do
  @moduledoc """
  The `skill` tool: on-demand loading of a local Agent Skill (issue #23).

  The injected catalogue (`Athanor.Skills.catalogue/1`) carries **names and descriptions only**;
  this is how a skill's *body* enters the conversation, one skill at a time and only when the
  model asks for it. That split is the anti-pollution rule §7.5 states for memory, applied to
  instruction bundles: a machine with 45 installed skills must not pay for 45 bodies on every
  request.

  ## What the model gets back

  A short provenance header naming the skill's directory, then the `SKILL.md` body with its
  frontmatter stripped. The directory matters: a skill's assets (`scripts/`, `references/`,
  `agents/openai.yaml`) are *relative to it*, so without the path the model could not open them
  with `read_file`. The header is one line, not a wrapper — the body is prose the model should
  read as instructions, exactly like an `AGENTS.md` block.

  ## Boundaries

  This tool **reads a file and returns text**. It does not register a tool, does not start an MCP
  server (§7.6), does not write memory (§7.5), and cannot make a skill's `allowed-tools`
  frontmatter real. A skill's text is untrusted input with respect to the harness, and this module
  treats it as data: it is returned as a tool result, so it can never forge the
  `===ATHANOR_DONE===` sentinel (parsed from assistant messages only) or reach the system prompt.
  """

  alias Athanor.Skills

  @doc """
  Loads the named skill and renders the tool result, or an actionable error string.

  Options are `Athanor.Skills.load/2`'s (`:paths`, `:enabled`, `:max_bytes`). Failures are the
  model's to fix — a wrong name gets the list of available names, and a `SKILL.md` without
  frontmatter is named as such — so they are `{:error, message}` strings rather than atoms.
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(name, opts \\ []) when is_binary(name) do
    case Skills.find(name, opts) do
      nil -> Skills.load(name, opts)
      skill -> with {:ok, body} <- Skills.read(skill, opts), do: {:ok, render(skill, body)}
    end
  end

  defp render(skill, body) do
    """
    Skill: #{skill.name}
    Directory: #{skill.dir}
    (Assets referenced by this skill are relative to that directory.)

    #{body}\
    """
  end
end
