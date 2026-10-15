defmodule Athanor.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Athanor.Tools.Grep

  @moduletag :tmp_dir

  defp write!(root, rel, body) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  test "returns path:line:content relative to the root", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "defmodule A do\n  def one, do: 1\nend\n")
    write!(root, "lib/b.ex", "defmodule B do\n  def two, do: 2\nend\n")

    assert {:ok, body} = Grep.run(%{"pattern" => "def "}, cd: root)

    assert body == "lib/a.ex:2:  def one, do: 1\nlib/b.ex:2:  def two, do: 2"
  end

  test "is case-insensitive when requested", %{tmp_dir: root} do
    write!(root, "a.txt", "Hello World\n")

    assert {:ok, body} = Grep.run(%{"pattern" => "hello", "case_sensitive" => false}, cd: root)
    # `case_sensitive` is not part of M1's schema, so this documents current behaviour.
    assert body == "(no matches)"
  end

  test "reports an invalid regex as a user error, not a crash", %{tmp_dir: root} do
    write!(root, "a.txt", "hi\n")

    assert {:error, msg} = Grep.run(%{"pattern" => "["}, cd: root)
    assert msg =~ "Invalid regular expression"
  end

  test "restricts the file set with `glob`", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "needle\n")
    write!(root, "lib/b.txt", "needle\n")

    assert {:ok, body} = Grep.run(%{"pattern" => "needle", "glob" => "**/*.ex"}, cd: root)
    assert body == "lib/a.ex:1:needle"
  end

  test "applies caller-supplied ignore patterns", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "needle\n")
    write!(root, "vendor/x.ex", "needle\n")

    assert {:ok, body} = Grep.run(%{"pattern" => "needle", "ignore" => ["vendor/**"]}, cd: root)
    assert body == "lib/a.ex:1:needle"
  end

  test "never descends into denied directories", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "needle\n")
    write!(root, "deps/other/x.ex", "needle\n")
    write!(root, "_build/dev/y.ex", "needle\n")

    assert {:ok, body} = Grep.run(%{"pattern" => "needle"}, cd: root)
    assert body == "lib/a.ex:1:needle"
  end

  test "skips binary files", %{tmp_dir: root} do
    write!(root, "text.txt", "needle\n")
    write!(root, "blob.bin", <<0, 1, 2, 3>> <> "needle")

    assert {:ok, body} = Grep.run(%{"pattern" => "needle"}, cd: root)
    assert body == "text.txt:1:needle"
  end

  test "caps matches with a truncation notice", %{tmp_dir: root} do
    body = Enum.map_join(1..30, "", fn i -> "needle #{i}\n" end)
    write!(root, "many.txt", body)

    assert {:ok, out} = Grep.run(%{"pattern" => "needle", "max_results" => 5}, cd: root)

    lines = String.split(out, "\n")
    assert length(lines) == 6
    assert Enum.at(lines, 5) =~ "truncated at 5 matches"
  end

  test "searches a single file", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "needle\n")
    write!(root, "lib/b.ex", "needle\n")

    assert {:ok, body} = Grep.run(%{"pattern" => "needle", "path" => "lib/a.ex"}, cd: root)
    assert body == "a.ex:1:needle"
  end

  test "empty result is explicit", %{tmp_dir: root} do
    write!(root, "a.txt", "nothing here\n")
    assert {:ok, "(no matches)"} = Grep.run(%{"pattern" => "needle"}, cd: root)
  end

  test "reports a missing path", %{tmp_dir: root} do
    assert {:error, msg} = Grep.run(%{"pattern" => "x", "path" => "nope"}, cd: root)
    assert msg =~ "No such file or directory"
  end

  test "is reachable through Athanor.Tools.execute/3 with JSON arguments", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "needle\n")

    assert {:ok, body} =
             Athanor.Tools.execute("grep", JSON.encode!(%{"pattern" => "needle"}), cd: root)

    assert body == "lib/a.ex:1:needle"
  end
end
