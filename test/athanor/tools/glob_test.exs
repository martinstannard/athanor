defmodule Athanor.Tools.GlobTest do
  use ExUnit.Case, async: true

  alias Athanor.Tools.Glob

  @moduletag :tmp_dir

  defp write!(root, rel, body \\ "# x\n") do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  test "finds files by pattern and returns root-relative sorted paths", %{tmp_dir: root} do
    write!(root, "lib/a.ex")
    write!(root, "lib/nested/b.ex")
    write!(root, "test/c_test.exs")

    assert {:ok, body} = Glob.run(%{"pattern" => "**/*.ex"}, cd: root)
    assert body == "lib/a.ex\nlib/nested/b.ex"
  end

  test "supports brace and question-mark patterns", %{tmp_dir: root} do
    write!(root, "a.exs")
    write!(root, "b.exs")
    write!(root, "c.ex")

    assert {:ok, body} = Glob.run(%{"pattern" => "*.{ex,exs}"}, cd: root)
    assert body == "a.exs\nb.exs\nc.ex"

    assert {:ok, one} = Glob.run(%{"pattern" => "?.ex"}, cd: root)
    assert one == "c.ex"
  end

  test "respects built-in denies and .gitignore", %{tmp_dir: root} do
    write!(root, "lib/a.ex")
    write!(root, "deps/dep/lib/x.ex")
    write!(root, "_build/dev/x.ex")
    write!(root, "tmp/scratch.ex")
    File.write!(Path.join(root, ".gitignore"), "tmp/\n")

    assert {:ok, body} = Glob.run(%{"pattern" => "**/*.ex"}, cd: root)
    assert body == "lib/a.ex"
  end

  test "searches a subdirectory via `path` and relativises to it", %{tmp_dir: root} do
    write!(root, "lib/a.ex")
    write!(root, "lib/nested/b.ex")
    write!(root, "other/c.ex")

    assert {:ok, body} = Glob.run(%{"pattern" => "**/*.ex", "path" => "lib"}, cd: root)
    assert body == "a.ex\nnested/b.ex"
  end

  test "empty result is explicit, never an empty string", %{tmp_dir: root} do
    write!(root, "a.txt")
    assert {:ok, "(no files matched)"} = Glob.run(%{"pattern" => "**/*.rs"}, cd: root)
  end

  test "caps results with a truncation notice including the total", %{tmp_dir: root} do
    for i <- 1..25, do: write!(root, "f#{String.pad_leading(to_string(i), 3, "0")}.txt")

    assert {:ok, body} = Glob.run(%{"pattern" => "*.txt", "max_results" => 10}, cd: root)

    lines = String.split(body, "\n")
    assert length(lines) == 11
    assert Enum.at(lines, 10) =~ "truncated: 10 of 25 matches"
    assert Enum.at(lines, 10) =~ "raise max_results"
  end

  test "does not escape the search root", %{tmp_dir: root} do
    write!(root, "inside.txt")
    write!(root, "../outside.txt")

    assert {:ok, body} = Glob.run(%{"pattern" => "../*.txt"}, cd: root)
    refute body =~ "outside.txt"
    assert body == "(no files matched)"
  end

  test "skips symlinked files", %{tmp_dir: root} do
    real = write!(root, "real/exists.txt")
    File.mkdir_p!(Path.join(root, "lib"))
    File.ln_s!(real, Path.join(root, "lib/linked.txt"))

    assert {:ok, body} = Glob.run(%{"pattern" => "lib/*"}, cd: root)
    assert body == "(no files matched)"
  end

  test "reports a missing directory", %{tmp_dir: root} do
    assert {:error, msg} = Glob.run(%{"pattern" => "*", "path" => "nope"}, cd: root)
    assert msg =~ "No such directory"
  end

  test "rejects an empty pattern", %{tmp_dir: root} do
    assert {:error, msg} = Glob.run(%{"pattern" => "   "}, cd: root)
    assert msg =~ "non-empty"
  end

  test "is reachable through Athanor.Tools.execute/3 with JSON arguments", %{tmp_dir: root} do
    write!(root, "lib/a.ex")

    assert {:ok, body} =
             Athanor.Tools.execute("glob", JSON.encode!(%{"pattern" => "**/*.ex"}), cd: root)

    assert body == "lib/a.ex"
  end
end
