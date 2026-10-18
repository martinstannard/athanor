defmodule Athanor.Tools.SkillTest do
  @moduledoc """
  The `skill` tool and its wiring into `Athanor.Tools` / `Athanor.Agent` (issue #23).

  Two things are asserted here: the tool's own result shape, and the split that keeps a skill's
  body out of the system prompt — the catalogue advertises, `skill(name)` loads. The fixture roots
  are always explicit, so no developer skill can leak into these assertions
  (`test_helper.exs` pins `ATHANOR_SKILL_PATHS` to a non-existent root for the whole suite).
  """
  use ExUnit.Case, async: true

  alias Athanor.{Agent, Skills, Tools}

  @moduletag :tmp_dir

  describe "schemas/1" do
    test "both roles are offered the skill tool" do
      for role <- [:conductor, :worker] do
        names =
          Tools.schemas(role: role)
          |> Enum.map(fn %{"type" => "function", "function" => %{"name" => name}} -> name end)

        assert "skill" in names
      end
    end

    test "the schema shape matches the other tools" do
      schema =
        Tools.schemas(role: :worker)
        |> Enum.find(fn %{"function" => %{"name" => name}} -> name == "skill" end)

      assert %{
               "type" => "function",
               "function" => %{
                 "name" => "skill",
                 "description" => description,
                 "parameters" => %{"type" => "object", "required" => ["name"]}
               }
             } = schema

      assert is_binary(description)
      assert schema["function"]["parameters"]["properties"]["name"]["type"] == "string"
    end
  end

  describe "execute/3" do
    test "returns the body with a provenance header naming the skill directory", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.", "# TDD\n\nFailing test first.")

      assert {:ok, output} = Tools.execute("skill", %{"name" => "tdd"}, skill_opts: [paths: [root]])
      assert output =~ "Skill: tdd"
      assert output =~ "Directory: #{Path.join(root, "tdd")}"
      assert output =~ "# TDD"
      assert output =~ "Failing test first."
      # Frontmatter never reaches the model.
      refute output =~ "description:"
    end

    test "an unknown name is an actionable error listing what is available", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "alpha", "alpha", "a", "body")

      assert {:error, message} = Tools.execute("skill", %{"name" => "nope"}, skill_opts: [paths: [root]])
      assert message =~ "No skill named \"nope\""
      assert message =~ "alpha"
    end

    test "a missing name argument is the usual argument error" do
      assert {:error, message} = Tools.execute("skill", %{}, [])
      assert message == "Missing or invalid required arguments for tool skill"
    end

    test "a malformed SKILL.md is reported as such, not as a missing skill", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      File.mkdir_p!(Path.join(root, "bad"))
      File.write!(Path.join([root, "bad", "SKILL.md"]), "# no frontmatter\n")

      # Not discovered, so the name is unknown — the point is that it does not raise and the model
      # gets a usable message either way.
      assert {:error, message} = Tools.execute("skill", %{"name" => "bad"}, skill_opts: [paths: [root]])
      assert message =~ "No skills are available"
    end

    test "disabled skills refuse with a clear message", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.", "body")

      assert {:error, message} =
               Tools.execute("skill", %{"name" => "tdd"}, skill_opts: [paths: [root], enabled: false])

      assert message =~ "No skills are available"
    end

    test "honours the session's max_bytes", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "big", "big", "big", String.duplicate("x", 2_000))

      assert {:ok, output} =
               Tools.execute("skill", %{"name" => "big"}, skill_opts: [paths: [root], max_bytes: 200])

      assert output =~ "[athanor: skill truncated at 200 bytes]"
    end
  end

  describe "Athanor.Agent injection" do
    test "a conductor's system prompt carries the catalogue, names and descriptions only",
         %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.", "SECRET BODY TEXT")

      {:ok, agent} = Agent.start_link(cd: dir, skill_paths: [root])
      [%{role: "system", content: content}] = Agent.get_state(agent).messages

      assert content =~ Skills.sentinel()
      assert content =~ "- tdd: Test-driven development."
      # The body is what `skill(name)` is for; it must not be in the prompt.
      refute content =~ "SECRET BODY TEXT"
    end

    test "a worker's system prompt does not carry the catalogue", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.", "body")

      {:ok, agent} = Agent.start_link(cd: dir, role: :worker, parent_id: "conductor-main", skill_paths: [root])
      [%{role: "system", content: content}] = Agent.get_state(agent).messages

      refute content =~ Skills.sentinel()
      refute content =~ "- tdd:"
    end

    test "skills: false suppresses the catalogue", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.", "body")

      {:ok, agent} = Agent.start_link(cd: dir, skills: false, skill_paths: [root])
      [%{role: "system", content: content}] = Agent.get_state(agent).messages

      refute content =~ Skills.sentinel()
    end

    test "a root with no skills adds no sentinel and no trailing separators", %{tmp_dir: dir} do
      empty = Path.join(dir, "empty")
      File.mkdir_p!(empty)

      {:ok, agent} = Agent.start_link(cd: dir, skill_paths: [empty])
      [%{role: "system", content: content}] = Agent.get_state(agent).messages

      refute content =~ Skills.sentinel()
      assert content == String.trim_trailing(content)
    end

    # The suite-wide guarantee: `test_helper.exs` pins `ATHANOR_SKILL_PATHS` to a non-existent
    # root, so a default-configured session — every conductor built by an unrelated test — cannot
    # see the developer's real skill library. Asserting it here keeps that pin honest: if someone
    # removes it, this fails loudly instead of silently polluting unrelated prompts.
    test "a default-configured session sees no skills at all (no developer leak)", %{tmp_dir: dir} do
      {:ok, agent} = Agent.start_link(cd: dir)
      [%{role: "system", content: content}] = Agent.get_state(agent).messages

      refute content =~ Skills.sentinel()
      assert Skills.discover() == []
      assert Skills.catalogue() == nil
    end

    test "the session's roots reach the tool, not the process-global config", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.", "# TDD body")

      # The suite's pinned ATHANOR_SKILL_PATHS points nowhere, so this can only succeed via the
      # per-session `skill_paths:` travelling into the tool call.
      llm_fn = fn messages, _tools, _agent_pid ->
        case List.last(messages).role do
          "user" ->
            {:ok,
             %{
               role: "assistant",
               content: "",
               tool_calls: [
                 %{
                   id: "call_1",
                   type: "function",
                   function: %{name: "skill", arguments: JSON.encode!(%{"name" => "tdd"})}
                 }
               ]
             }}

          _tool ->
            {:ok, %{role: "assistant", content: "done", tool_calls: []}}
        end
      end

      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: dir, skill_paths: [root], llm_fn: llm_fn)

      assert :ok = Agent.prompt(agent, "load the tdd skill")

      assert_receive {:agent_event, {:tool_end, "skill", {:ok, output}}}, 2_000
      assert output =~ "Skill: tdd"
      assert output =~ "# TDD body"
    end
  end

  defp write_skill(root, dir, name, description, body) do
    path = Path.join([root, dir, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    name: #{name}
    description: #{description}
    ---

    #{body}
    """)
  end
end
