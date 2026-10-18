defmodule Athanor.SkillsTest do
  @moduledoc """
  `Athanor.Skills` discovery, precedence and loading (issue #23).

  Every test builds its own tmp fixture tree and passes it as `paths:`; the suite pins
  `ATHANOR_SKILLS=0`/`ATHANOR_SKILL_PATHS` in `test_helper.exs`, so a developer's real skill roots
  can never leak in here (or anywhere else). `async: true` because nothing here touches process
  globals.
  """
  use ExUnit.Case, async: true

  alias Athanor.Skills

  @moduletag :tmp_dir

  describe "discover/1" do
    test "reads name and description from a SKILL.md's frontmatter", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "code-review", "code-review", "Review a diff along two axes.")

      assert [skill] = Skills.discover(paths: [root])
      assert skill.name == "code-review"
      assert skill.description == "Review a diff along two axes."
      assert skill.source_root == root
      assert skill.dir == Path.join(root, "code-review")
      assert skill.path == Path.join([root, "code-review", "SKILL.md"])
      assert skill.model_invocable?
      assert skill.shadowed == []
    end

    test "the frontmatter name wins over the directory name", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "dir-name", "declared-name", "…")

      assert [%{name: "declared-name"}] = Skills.discover(paths: [root])
    end

    test "a missing name falls back to the directory name", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_raw(root, "gh", "---\ndescription: GitHub CLI helpers.\n---\n\nbody\n")

      assert [%{name: "gh", description: "GitHub CLI helpers."}] = Skills.discover(paths: [root])
    end

    test "a missing description is nil, not an empty string", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_raw(root, "bare", "---\nname: bare\n---\n\nbody\n")

      assert [%{name: "bare", description: nil}] = Skills.discover(paths: [root])
    end

    test "parses the block scalars real skills use for long descriptions", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")

      write_raw(root, "folded", """
      ---
      name: folded
      description: >
        First line of the description
        and the second one.
      allowed-tools: Bash(gh:*)
      ---

      # Body
      """)

      write_raw(root, "literal", """
      ---
      name: literal
      description: |-
        Line one.
        Line two.
      ---

      # Body
      """)

      skills = Map.new(Skills.discover(paths: [root]), &{&1.name, &1.description})

      assert skills["folded"] == "First line of the description and the second one."
      assert skills["literal"] == "Line one.\nLine two."
    end

    test "ignores nested maps, block sequences and unknown keys", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")

      write_raw(root, "launchdarkly", """
      ---
      name: launchdarkly
      description: "Manage feature flags."
      license: Apache-2.0
      allowed-tools:
        - Bash
        - Read
      metadata:
        author: someone
        version: "1.0.0"
      mcpServers:
        jev:
          command: npx
          args: ["-y", "jev-mcp"]
      ---

      # Body
      """)

      assert [%{name: "launchdarkly", description: "Manage feature flags."}] =
               Skills.discover(paths: [root])
    end

    test "disable-model-invocation hides a skill from the catalogue but not from discovery",
         %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "teach", "teach", "Teach a concept.")

      write_raw(
        root,
        "grill",
        "---\nname: grill\ndescription: Interview me.\ndisable-model-invocation: true\n---\n\nbody\n"
      )

      discovered = Skills.discover(paths: [root])
      assert Enum.map(discovered, & &1.name) == ["grill", "teach"]
      refute Enum.find(discovered, &(&1.name == "grill")).model_invocable?

      catalogue = Skills.catalogue(paths: [root])
      assert catalogue =~ "teach"
      refute catalogue =~ "grill"
    end

    test "skips directories with no SKILL.md and files in the root", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "real", "real", "A real skill.")
      File.mkdir_p!(Path.join(root, "empty-dir"))
      File.write!(Path.join(root, "README.md"), "not a skill")
      File.mkdir_p!(Path.join(root, "assets-only"))
      File.write!(Path.join([root, "assets-only", "notes.md"]), "no SKILL.md here")

      assert [%{name: "real"}] = Skills.discover(paths: [root])
    end

    test "skips a SKILL.md with no frontmatter, an unterminated block, and an unreadable file",
         %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "good", "good", "Fine.")
      write_raw(root, "prose-only", "# Just markdown\n\nNo frontmatter at all.\n")
      write_raw(root, "unterminated", "---\nname: unterminated\ndescription: never closed\n")
      # A broken symlink: `File.dir?/1` follows it and fails, so the entry is not a skill.
      File.ln_s!(Path.join(dir, "does-not-exist"), Path.join(root, "broken-link"))

      assert [%{name: "good"}] = Skills.discover(paths: [root])
    end

    test "an empty or missing root is not an error", %{tmp_dir: dir} do
      empty = Path.join(dir, "empty")
      File.mkdir_p!(empty)

      assert Skills.discover(paths: []) == []
      assert Skills.discover(paths: [empty]) == []
      assert Skills.discover(paths: [Path.join(dir, "nope")]) == []
    end

    test "results are ordered by name", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "zeta", "zeta", "z")
      write_skill(root, "alpha", "alpha", "a")
      write_skill(root, "mid", "mid", "m")

      assert Enum.map(Skills.discover(paths: [root]), & &1.name) == ["alpha", "mid", "zeta"]
    end

    test "enabled: false short-circuits discovery", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "real", "real", "A real skill.")

      assert Skills.discover(paths: [root], enabled: false) == []
      assert Skills.catalogue(paths: [root], enabled: false) == nil

      assert Skills.load("real", paths: [root], enabled: false) ==
               {:error, "No skills are available (no configured root holds a SKILL.md)."}
    end
  end

  describe "symlinks and precedence" do
    test "a symlinked skill is discovered as its target", %{tmp_dir: dir} do
      global = Path.join(dir, "global")
      workspace = Path.join(dir, "workspace")
      write_skill(workspace, "pr-diagram", "pr-diagram", "Diagram a PR.")
      File.mkdir_p!(global)
      File.ln_s!(Path.join(workspace, "pr-diagram"), Path.join(global, "pr-diagram"))

      assert [skill] = Skills.discover(paths: [global])
      assert skill.name == "pr-diagram"
      assert skill.dir == Path.join(workspace, "pr-diagram")
      # The root it was *found* under is the global one, because that is the entry scanned.
      assert skill.source_root == global
    end

    test "the same skill reachable from two roots is de-duplicated, later root wins",
         %{tmp_dir: dir} do
      global = Path.join(dir, "global")
      workspace = Path.join(dir, "workspace")
      write_skill(workspace, "pr-diagram", "pr-diagram", "Diagram a PR.")
      File.mkdir_p!(global)
      File.ln_s!(Path.join(workspace, "pr-diagram"), Path.join(global, "pr-diagram"))

      assert [skill] = Skills.discover(paths: [global, workspace])
      assert skill.source_root == workspace
      # The loser is recorded by directory, and the symlink is resolved — both roots name the same
      # directory, so it is named once.
      assert skill.shadowed == [Path.join(workspace, "pr-diagram")]
    end

    test "two different directories declaring the same name collide, later root wins",
         %{tmp_dir: dir} do
      global = Path.join(dir, "global")
      workspace = Path.join(dir, "workspace")
      write_skill(global, "linear-cli", "linear-cli", "Global copy.")
      write_skill(workspace, "linear-cli", "linear-cli", "Workspace copy.")

      assert [skill] = Skills.discover(paths: [global, workspace])
      assert skill.description == "Workspace copy."
      assert skill.source_root == workspace
      assert skill.shadowed == [Path.join(global, "linear-cli")]

      # Reversed order flips the winner: precedence is "later root wins", not "workspace always".
      assert [flipped] = Skills.discover(paths: [workspace, global])
      assert flipped.description == "Global copy."
      assert flipped.source_root == global
    end

    test "a stale backup copy in the same root loses to the name it duplicates", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "linear-cli", "linear-cli", "The real one.")
      write_skill(root, "linear-cli.bak-20260101", "linear-cli", "The stale one.")

      # Entries are scanned in sorted order, so the backup (`…bak…`) is seen *after* the real
      # directory and therefore wins by the same later-root rule. Either way there is exactly one
      # `linear-cli`, and the loser is recorded — that is the invariant that matters.
      assert [skill] = Skills.discover(paths: [root])
      assert skill.name == "linear-cli"
      assert skill.description == "The stale one."
      assert skill.shadowed == [Path.join(root, "linear-cli")]
    end

    test "three roots keep the last and record both losers", %{tmp_dir: dir} do
      a = Path.join(dir, "a")
      b = Path.join(dir, "b")
      c = Path.join(dir, "c")
      write_skill(a, "dup", "dup", "from a")
      write_skill(b, "dup", "dup", "from b")
      write_skill(c, "dup", "dup", "from c")

      assert [skill] = Skills.discover(paths: [a, b, c])
      assert skill.description == "from c"
      assert skill.shadowed == [Path.join(a, "dup"), Path.join(b, "dup")]
    end

    test "a root may name the repository that holds the skills tree", %{tmp_dir: dir} do
      repo = Path.join(dir, "work-skills")
      write_skill(Path.join([repo, ".agents", "skills"]), "tdd", "tdd", "Test-first.")

      assert [skill] = Skills.discover(paths: [repo])
      assert skill.source_root == Path.join([repo, ".agents", "skills"])

      # …and naming the tree directly gives the same answer.
      assert [same] = Skills.discover(paths: [Path.join([repo, ".agents", "skills"])])
      assert same.source_root == skill.source_root
    end

    test "roots/1 expands ~ and drops blanks and duplicates", %{tmp_dir: dir} do
      home = System.user_home!()

      assert Skills.roots(paths: ["~/.agents/skills"]) == [Path.join(home, ".agents/skills")]
      assert Skills.roots(paths: [dir, "", dir]) == [dir]
    end
  end

  describe "load/2" do
    test "returns the body with frontmatter stripped", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")

      write_raw(root, "tdd", """
      ---
      name: tdd
      description: Test-driven development.
      ---

      # TDD

      Write the failing test first.
      """)

      assert {:ok, body} = Skills.load("tdd", paths: [root])
      assert body == "# TDD\n\nWrite the failing test first."
      refute body =~ "description:"
    end

    test "an unknown name lists what is available", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "alpha", "alpha", "a")
      write_skill(root, "beta", "beta", "b")

      assert {:error, message} = Skills.load("nope", paths: [root])
      assert message =~ "No skill named \"nope\""
      assert message =~ "alpha, beta"
    end

    test "truncates an oversized body with a visible marker", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_raw(root, "big", "---\nname: big\ndescription: big\n---\n\n" <> String.duplicate("x", 500))

      assert {:ok, body} = Skills.load("big", paths: [root], max_bytes: 100)
      assert byte_size(body) <= 100
      assert body =~ "[athanor: skill truncated at 100 bytes]"
    end

    test "truncation never splits a multi-byte codepoint", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      # Each `é` is two bytes, so a naive cut at an odd offset would land mid-codepoint.
      write_raw(root, "unicode", "---\nname: unicode\ndescription: unicode\n---\n\n" <> String.duplicate("é", 200))

      assert {:ok, body} = Skills.load("unicode", paths: [root], max_bytes: 101)
      assert String.valid?(body)
    end

    test "find/2 returns nil for an unknown name", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "real", "real", "A real skill.")

      assert Skills.find("real", paths: [root]).name == "real"
      assert Skills.find("nope", paths: [root]) == nil
    end
  end

  describe "catalogue/1" do
    test "is a name + description list wrapped in the sentinel", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.")

      catalogue = Skills.catalogue(paths: [root])
      assert catalogue =~ Skills.sentinel()
      assert catalogue =~ "- tdd: Test-driven development."
      # Bodies never appear in the catalogue.
      refute catalogue =~ "Write the failing test first."
    end

    test "a description spanning lines is folded onto one line", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")

      write_raw(root, "caveman", """
      ---
      name: caveman
      description: >
        Ultra-compressed communication.
        Cuts tokens by ~75%.
      ---

      body
      """)

      catalogue = Skills.catalogue(paths: [root])
      assert catalogue =~ "- caveman: Ultra-compressed communication. Cuts tokens by ~75%."
      refute catalogue =~ "Ultra-compressed communication.\n"
    end

    test "a skill with no description still appears", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_raw(root, "bare", "---\nname: bare\n---\n\nbody\n")

      assert Skills.catalogue(paths: [root]) =~ "- bare: (no description)"
    end

    test "is nil when there is nothing to inject", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      File.mkdir_p!(root)

      assert Skills.catalogue(paths: [root]) == nil
      assert Skills.catalogue(paths: []) == nil
    end

    test "the sentinel names the tool, not the skills", %{tmp_dir: dir} do
      root = Path.join(dir, "skills")
      write_skill(root, "tdd", "tdd", "Test-driven development.")

      assert Skills.catalogue(paths: [root]) =~ "`skill` tool"
    end
  end

  # -- fixtures ---------------------------------------------------------------------------

  defp write_skill(root, dir, name, description) do
    write_raw(root, dir, """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{name}

    Write the failing test first.
    """)
  end

  defp write_raw(root, dir, content) do
    path = Path.join([root, dir, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
