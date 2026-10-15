defmodule Athanor.Tools.IgnoreTest do
  use ExUnit.Case, async: true

  alias Athanor.Tools.Ignore

  @moduletag :tmp_dir

  defp ctx(root, opts \\ []) do
    Ignore.new(root, Keyword.merge([denies: [".git", "_build", "deps"]], opts))
  end

  test "hard denials apply at any depth", %{tmp_dir: root} do
    c = ctx(root)

    assert Ignore.ignored?(c, Path.join(root, "deps/foo.ex"))
    assert Ignore.ignored?(c, Path.join(root, "_build/dev/lib/x/ebin/x.beam"))
    assert Ignore.ignored?(c, Path.join(root, "nested/deep/deps/y.ex"))
    assert Ignore.ignored?(c, Path.join(root, ".git/HEAD"))

    refute Ignore.ignored?(c, Path.join(root, "lib/athanor/tools.ex"))
  end

  test "beam files are always ignored", %{tmp_dir: root} do
    c = ctx(root)

    assert Ignore.ignored?(c, Path.join(root, "lib/foo.beam"))
    refute Ignore.ignored?(c, Path.join(root, "lib/foo.ex"))
  end

  test "honours .gitignore at the root", %{tmp_dir: root} do
    File.write!(Path.join(root, ".gitignore"), """
    # comment
    *.log
    build/
    /anchored.txt
    !keep.log
    """)

    c = ctx(root, denies: [])

    assert Ignore.ignored?(c, Path.join(root, "a.log"))
    assert Ignore.ignored?(c, Path.join(root, "sub/b.log"))
    # negation wins (last match)
    refute Ignore.ignored?(c, Path.join(root, "keep.log"))
    # directory-only rule matches contents but not the bare name
    assert Ignore.ignored?(c, Path.join(root, "build/out.txt"))
    refute Ignore.ignored?(c, Path.join(root, "build"))
    # anchored rule does not match nested files
    assert Ignore.ignored?(c, Path.join(root, "anchored.txt"))
    refute Ignore.ignored?(c, Path.join(root, "sub/anchored.txt"))
  end

  test "caller-supplied ignore patterns", %{tmp_dir: root} do
    c = ctx(root, denies: [], ignore: ["*.tmp", "vendor/**"])

    assert Ignore.ignored?(c, Path.join(root, "x.tmp"))
    assert Ignore.ignored?(c, Path.join(root, "vendor/lib/a.dart"))
    refute Ignore.ignored?(c, Path.join(root, "lib/a.ex"))
  end

  test "within?/2 bounds results to the root", %{tmp_dir: root} do
    c = ctx(root)

    assert Ignore.within?(c, Path.join(root, "a/b.txt"))
    refute Ignore.within?(c, Path.join(root, "../outside.txt"))
    refute Ignore.within?(c, "/etc/passwd")
  end

  test "regular_file?/1 rejects directories and symlinks", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "dir"))
    File.write!(Path.join(root, "file.txt"), "hi")
    File.ln_s!(Path.join(root, "file.txt"), Path.join(root, "link.txt"))

    assert Ignore.regular_file?(Path.join(root, "file.txt"))
    refute Ignore.regular_file?(Path.join(root, "dir"))
    refute Ignore.regular_file?(Path.join(root, "link.txt"))
  end

  test "symlink_ancestor?/1 detects a symlinked parent", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "real"))
    File.write!(Path.join(root, "real/f.txt"), "hi")
    File.ln_s!(Path.join(root, "real"), Path.join(root, "aliased"))

    c = ctx(root)

    refute Ignore.symlink_ancestor?(c, Path.join(root, "real/f.txt"))
    assert Ignore.symlink_ancestor?(c, Path.join(root, "aliased/f.txt"))
  end

  test "too_large?/2 and binary?/1", %{tmp_dir: root} do
    big = Path.join(root, "big.txt")
    small = Path.join(root, "small.txt")
    bin = Path.join(root, "blob.bin")

    File.write!(big, String.duplicate("x", 4096))
    File.write!(small, "hello")
    File.write!(bin, <<0, 1, 2, 3>>)

    assert Ignore.too_large?(big, 1024)
    refute Ignore.too_large?(small, 1024)
    assert Ignore.binary?(bin)
    refute Ignore.binary?(small)
  end
end
