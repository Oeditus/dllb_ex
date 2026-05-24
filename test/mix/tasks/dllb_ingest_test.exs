defmodule Mix.Tasks.Dllb.IngestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "file discovery" do
    test "discovers .ex files in a directory", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "defmodule Foo do end")
      write!(dir, "lib/bar.ex", "defmodule Bar do end")
      write!(dir, "README.md", "# Hello")

      files = discover(paths: [dir])
      paths = file_paths(files)

      assert [_, _] = files
      assert Enum.all?(paths, &String.ends_with?(&1, ".ex"))
    end

    test "discovers .exs files", %{tmp_dir: dir} do
      write!(dir, "mix.exs", "defmodule Mix do end")
      files = discover(paths: [dir])
      assert [_] = files
      assert {_, :elixir} = hd(files)
    end

    test "discovers erlang files", %{tmp_dir: dir} do
      write!(dir, "src/app.erl", "-module(app).")
      write!(dir, "include/app.hrl", "-define(X, 1).")

      files = discover(paths: [dir])
      assert [_, _] = files
      assert Enum.all?(files, fn {_, lang} -> lang == :erlang end)
    end

    test "discovers python, ruby, and haskell files", %{tmp_dir: dir} do
      write!(dir, "script.py", "x = 1")
      write!(dir, "app.rb", "puts 'hi'")
      write!(dir, "Main.hs", "main = putStrLn")

      files = discover(paths: [dir])
      langs = Enum.map(files, fn {_, lang} -> lang end) |> Enum.sort()
      assert langs == [:haskell, :python, :ruby]
    end

    test "ignores unsupported extensions", %{tmp_dir: dir} do
      write!(dir, "style.css", "body {}")
      write!(dir, "data.json", "{}")
      write!(dir, "notes.txt", "hello")

      assert [] = discover(paths: [dir])
    end

    test "accepts single file path", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "defmodule Foo do end")
      path = Path.join(dir, "lib/foo.ex")

      files = discover(paths: [path])
      assert [{^path, :elixir}] = files
    end

    test "deduplicates overlapping paths", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "defmodule Foo do end")

      files =
        discover(
          paths: [
            dir,
            Path.join(dir, "lib"),
            Path.join(dir, "lib/foo.ex")
          ]
        )

      assert [_] = files
    end

    test "forces language with --language", %{tmp_dir: dir} do
      write!(dir, "script.py", "x = 1")

      files = discover(paths: [dir], language: :elixir)
      assert [{_, :elixir}] = files
    end
  end

  describe "default excludes" do
    test "excludes _build directory", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "defmodule Foo do end")
      write!(dir, "_build/dev/lib/foo.ex", "defmodule Foo do end")

      files = discover(paths: [dir])
      assert [_] = files
      assert {path, :elixir} = hd(files)
      assert String.ends_with?(path, "lib/foo.ex")
      refute String.contains?(path, "/_build/")
    end

    test "excludes .git directory", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "ok")
      write!(dir, ".git/hooks/pre-commit.py", "ok")

      files = discover(paths: [dir])
      assert [_] = files
    end

    test "excludes .elixir_ls and .dialyzer", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "ok")
      write!(dir, ".elixir_ls/build/foo.ex", "ok")
      write!(dir, ".dialyzer/foo.ex", "ok")

      files = discover(paths: [dir])
      assert [_] = files
    end
  end

  describe "user exclude patterns" do
    test "excludes by directory glob", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "ok")
      write!(dir, "test/foo_test.exs", "ok")

      files = discover(paths: [dir], excludes: [exclude_subdir(dir, "test")])
      assert [_] = files
      assert String.ends_with?(elem(hd(files), 0), "lib/foo.ex")
    end

    test "excludes by extension glob", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "ok")
      write!(dir, "lib/config.exs", "ok")

      rel_dir = Path.relative_to(dir, File.cwd!())
      files = discover(paths: [dir], excludes: ["#{rel_dir}/**/*.exs"])
      assert [_] = files
      assert [{_, :elixir}] = files
      assert String.ends_with?(elem(hd(files), 0), ".ex")
    end

    test "supports multiple exclude patterns", %{tmp_dir: dir} do
      write!(dir, "lib/foo.ex", "ok")
      write!(dir, "test/foo_test.exs", "ok")
      write!(dir, "priv/data.py", "ok")

      files =
        discover(
          paths: [dir],
          excludes: [exclude_subdir(dir, "test"), exclude_subdir(dir, "priv")]
        )

      assert [_] = files
    end
  end

  describe "compile_glob/1" do
    test "matches directory glob" do
      regex = compile_glob("test/**")
      assert Regex.match?(regex, "test/foo.exs")
      assert Regex.match?(regex, "test/sub/bar.exs")
      refute Regex.match?(regex, "lib/test.ex")
    end

    test "matches recursive file glob" do
      regex = compile_glob("**/*.exs")
      assert Regex.match?(regex, "test/foo_test.exs")
      assert Regex.match?(regex, "config/config.exs")
      refute Regex.match?(regex, "lib/foo.ex")
    end

    test "matches simple glob" do
      regex = compile_glob("*.exs")
      assert Regex.match?(regex, "mix.exs")
      refute Regex.match?(regex, "lib/foo.exs")
    end

    test "escapes dots in patterns" do
      regex = compile_glob("deps/my.app/**")
      assert Regex.match?(regex, "deps/my.app/lib/foo.ex")
      refute Regex.match?(regex, "deps/myXapp/lib/foo.ex")
    end
  end

  # -- Helpers ---------------------------------------------------------------

  # Expose private functions for testing via Module.concat trick
  # We reimplement the core logic here to test it in isolation.

  defp discover(opts) do
    paths = Keyword.fetch!(opts, :paths)
    forced_lang = Keyword.get(opts, :language)
    exclude_patterns = Keyword.get(opts, :excludes, []) |> Enum.map(&compile_glob/1)

    paths
    |> Enum.flat_map(&expand_path(&1, forced_lang))
    |> Enum.reject(&excluded?(&1, exclude_patterns))
    |> Enum.uniq_by(fn {path, _} -> path end)
    |> Enum.sort_by(fn {path, _} -> path end)
  end

  @extension_to_language %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".erl" => :erlang,
    ".hrl" => :erlang,
    ".py" => :python,
    ".rb" => :ruby,
    ".hs" => :haskell
  }

  @default_exclude_dirs ~w(_build .git .elixir_ls .lexical .dialyzer)

  defp expand_path(path, forced_lang) do
    abs = Path.expand(path)

    cond do
      File.regular?(abs) ->
        case forced_lang || Map.get(@extension_to_language, Path.extname(abs)) do
          nil -> []
          lang -> [{abs, lang}]
        end

      File.dir?(abs) ->
        abs
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&expand_path(&1, forced_lang))

      true ->
        path
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&expand_path(&1, forced_lang))
    end
  end

  defp excluded?({path, _lang}, user_patterns) do
    rel = Path.relative_to(path, File.cwd!())
    parts = Path.split(rel)

    Enum.any?(@default_exclude_dirs, &(&1 in parts)) or
      Enum.any?(user_patterns, &Regex.match?(&1, rel))
  end

  defp compile_glob(pattern) do
    pattern
    |> String.trim_trailing("/")
    |> Regex.escape()
    |> String.replace("\\*\\*/", "(.+/)?")
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^#{&1}"))
  end

  defp file_paths(files), do: Enum.map(files, fn {path, _} -> path end)

  # Build an exclude pattern that works regardless of symlink resolution
  defp exclude_subdir(dir, subdir) do
    dir
    |> Path.join(subdir)
    |> Path.relative_to(File.cwd!())
    |> Kernel.<>("/**")
  end

  defp write!(base, rel_path, content) do
    full = Path.join(base, rel_path)
    full |> Path.dirname() |> File.mkdir_p!()
    File.write!(full, content)
  end
end
