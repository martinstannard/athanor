defmodule Athanor.SkillsConfigTest do
  @moduledoc """
  `Athanor.Config` skill accessors (issue #23).

  `async: false` because these mutate process-wide environment variables — the same constraint
  `MemoryConfigTest` has. `test_helper.exs` pins `ATHANOR_SKILL_PATHS` to a non-existent root for
  the whole suite; this module deletes that pin so it can assert the real defaults, and restores it
  on exit so no later module sees an unpinned environment.
  """
  use ExUnit.Case, async: false

  alias Athanor.Config

  @moduletag :tmp_dir

  @vars ["ATHANOR_SKILLS", "ATHANOR_SKILL_PATHS", "ATHANOR_SKILL_MAX_BYTES"]

  setup do
    saved = Map.new(@vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(@vars, &System.delete_env/1)
    on_exit(fn -> Enum.each(saved, fn {var, value} -> restore(var, value) end) end)
    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  test "defaults" do
    assert Config.skills_enabled?()
    assert Config.skill_paths() == ["~/.agents/skills", "~/work/skills/.agents/skills"]
    assert Config.default_skill_paths() == Config.skill_paths()
    assert Config.skill_max_bytes() == 32_768
  end

  test "ATHANOR_SKILLS=0 disables the layer" do
    System.put_env("ATHANOR_SKILLS", "0")
    refute Config.skills_enabled?()
  end

  test "ATHANOR_SKILLS accepts the usual truthy and falsy spellings" do
    for value <- ["1", "true", "yes", "on", "TRUE"] do
      System.put_env("ATHANOR_SKILLS", value)
      assert Config.skills_enabled?(), "expected #{value} to enable skills"
    end

    for value <- ["0", "false", "no", "off"] do
      System.put_env("ATHANOR_SKILLS", value)
      refute Config.skills_enabled?(), "expected #{value} to disable skills"
    end
  end

  test "ATHANOR_SKILL_PATHS is colon-separated, PATH-style" do
    System.put_env("ATHANOR_SKILL_PATHS", "/a/skills:/b/skills")
    assert Config.skill_paths() == ["/a/skills", "/b/skills"]
  end

  test "blank path entries are dropped, so a trailing colon is harmless" do
    System.put_env("ATHANOR_SKILL_PATHS", "/a/skills::/b/skills:")
    assert Config.skill_paths() == ["/a/skills", "/b/skills"]
  end

  test "an explicitly empty ATHANOR_SKILL_PATHS falls back to the defaults" do
    System.put_env("ATHANOR_SKILL_PATHS", "")
    assert Config.skill_paths() == Config.default_skill_paths()
  end

  test "ATHANOR_SKILL_MAX_BYTES overrides, and nonsense falls back" do
    System.put_env("ATHANOR_SKILL_MAX_BYTES", "4096")
    assert Config.skill_max_bytes() == 4_096

    System.put_env("ATHANOR_SKILL_MAX_BYTES", "not-a-number")
    assert Config.skill_max_bytes() == 32_768

    System.put_env("ATHANOR_SKILL_MAX_BYTES", "0")
    assert Config.skill_max_bytes() == 32_768
  end

  test "the app-config form works too, as a list or a string" do
    previous = Application.get_env(:athanor, :skill_paths)
    on_exit(fn -> Application.put_env(:athanor, :skill_paths, previous) end)

    Application.put_env(:athanor, :skill_paths, ["/from/config"])
    assert Config.skill_paths() == ["/from/config"]

    Application.put_env(:athanor, :skill_paths, "/x:/y")
    assert Config.skill_paths() == ["/x", "/y"]
  end

  test "the default roots are the verified global and workspace ones" do
    home = System.user_home!()

    assert Enum.map(Config.default_skill_paths(), &Path.expand/1) == [
             Path.join(home, ".agents/skills"),
             Path.join(home, "work/skills/.agents/skills")
           ]
  end
end
