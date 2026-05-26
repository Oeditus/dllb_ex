defmodule Mix.Tasks.Dllb.Ingest do
  @shortdoc "Ingest source code AST into dllb database"

  @moduledoc """
  Ingests source code files into the dllb database as MetaAST nodes and edges.

  Parses source files using Metastatic, converts them to dllb documents,
  and stores them as `ast_node` records with structural relationship edges
  (`contains`, `calls`, `imports`).

  ## Usage

      mix dllb.ingest PATH [PATH...] [OPTIONS]

  ## Arguments

  - `PATH` -- One or more files or directories to ingest. Directories are
    walked recursively. Only files with recognized extensions are selected.
    Defaults to `lib/` when no paths are given.

  ## Options

  - `--language LANG` -- Force a language for all files instead of
    auto-detecting from extensions. One of: elixir, erlang, python, ruby,
    haskell.
  - `--project-path NAME` -- Project identifier stored in the
    `project_path` field of every ingested node. Useful for multi-project
    indexes.
  - `--batch-size N` -- Number of queries per batch send (default 100).
  - `--bootstrap` -- Create the dllb schema (DEFINE TABLE / FIELD / INDEX)
    before ingesting. Safe to run repeatedly.
  - `--clean` -- Delete existing ast_node records for each file before
    re-ingesting. Use this for a full refresh of already-ingested files.
  - `--dry-run` -- Discover files and print a summary without executing
    any queries.
  - `--exclude PATTERN` -- Glob pattern to exclude. May be repeated.
    Directories `_build`, `.git`, `.elixir_ls`, `.lexical`, and
    `.dialyzer` are always excluded.

  ## Supported extensions

  | Extension | Language |
  |-----------|----------|
  | .ex .exs  | elixir   |
  | .erl .hrl | erlang   |
  | .py       | python   |
  | .rb       | ruby     |
  | .hs       | haskell  |

  ## Examples

  Ingest a project's lib directory:

      mix dllb.ingest lib/

  Ingest with schema bootstrap and project tag:

      mix dllb.ingest lib/ --bootstrap --project-path my_app

  Also ingest dependency source code:

      mix dllb.ingest lib/ deps/ --bootstrap --project-path my_app

  Re-ingest a single file, cleaning stale data first:

      mix dllb.ingest lib/my_app/parser.ex --clean

  Dry run to preview what would be ingested:

      mix dllb.ingest lib/ deps/ --dry-run

  Exclude test and support files:

      mix dllb.ingest . --exclude "test/**" --exclude "priv/**"
  """

  use Mix.Task

  alias Dllb.MetaAST

  @default_batch_size 100
  @default_exclude_dirs ~w(_build .git .elixir_ls .lexical .dialyzer)

  @extension_to_language %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".erl" => :erlang,
    ".hrl" => :erlang,
    ".py" => :python,
    ".rb" => :ruby,
    ".hs" => :haskell
  }

  @supported_languages ~w(elixir erlang python ruby haskell)a

  @switches [
    language: :string,
    project_path: :string,
    batch_size: :integer,
    bootstrap: :boolean,
    clean: :boolean,
    dry_run: :boolean,
    exclude: :keep
  ]

  # -- Public API ------------------------------------------------------------

  @impl Mix.Task
  def run(args) do
    ensure_metastatic!()
    Mix.Task.run("app.start")

    {opts, paths, _invalid} = OptionParser.parse(args, strict: @switches)
    config = build_config(opts, paths)
    files = discover_files(config)

    if files == [] do
      Mix.shell().info("No source files found in the given paths.")
      return_ok()
    else
      log("Discovered #{length(files)} source file(s)")

      if config.dry_run do
        print_dry_run(files)
      else
        if config.bootstrap, do: bootstrap_schema!()
        ensure_pool_running!()

        files
        |> ingest_all(config)
        |> print_summary()
      end
    end
  end

  # -- Configuration ---------------------------------------------------------

  defp build_config(opts, paths) do
    user_excludes =
      opts
      |> Keyword.get_values(:exclude)
      |> Enum.map(&compile_glob/1)

    %{
      paths: if(paths == [], do: ["lib"], else: paths),
      language: parse_language(opts[:language]),
      project_path: opts[:project_path],
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      bootstrap: Keyword.get(opts, :bootstrap, false),
      clean: Keyword.get(opts, :clean, false),
      dry_run: Keyword.get(opts, :dry_run, false),
      user_excludes: user_excludes
    }
  end

  defp parse_language(nil), do: nil

  defp parse_language(str) do
    atom = String.to_atom(str)

    if atom in @supported_languages do
      atom
    else
      names = Enum.map_join(@supported_languages, ", ", &Atom.to_string/1)
      Mix.raise("Unsupported language: #{str}. Supported: #{names}")
    end
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

  # -- File discovery --------------------------------------------------------

  defp discover_files(config) do
    config.paths
    |> Enum.flat_map(&expand_path(&1, config.language))
    |> Enum.reject(&excluded?(&1, config.user_excludes))
    |> Enum.uniq_by(fn {path, _lang} -> path end)
    |> Enum.sort_by(fn {path, _lang} -> path end)
  end

  defp expand_path(path, forced_lang) do
    abs = Path.expand(path)

    cond do
      File.regular?(abs) ->
        case forced_lang || language_for_ext(abs) do
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
        # Treat as glob
        path
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&expand_path(&1, forced_lang))
    end
  end

  defp language_for_ext(path), do: Map.get(@extension_to_language, Path.extname(path))

  defp excluded?({path, _lang}, user_patterns) do
    rel = Path.relative_to(path, File.cwd!())
    parts = Path.split(rel)

    Enum.any?(@default_exclude_dirs, &(&1 in parts)) or
      Enum.any?(user_patterns, &Regex.match?(&1, rel))
  end

  # -- Schema ----------------------------------------------------------------

  defp bootstrap_schema! do
    log("Bootstrapping schema...")

    case Dllb.Schema.bootstrap(&Dllb.query/1) do
      {:ok, :bootstrapped} -> log("Schema ready.")
      {:error, reason} -> Mix.raise("Schema bootstrap failed: #{inspect(reason)}")
    end
  end

  # -- Ingestion -------------------------------------------------------------

  defp ingest_all(files, config) do
    total = length(files)

    files
    |> Enum.with_index(1)
    |> Enum.reduce(empty_stats(), fn {{path, lang}, idx}, acc ->
      rel = Path.relative_to(path, File.cwd!())
      log("[#{idx}/#{total}] #{rel}")

      case ingest_one(path, lang, config) do
        {:ok, nodes, edges} ->
          %{acc | ok: acc.ok + 1, nodes: acc.nodes + nodes, edges: acc.edges + edges}

        {:error, reason} ->
          Mix.shell().error("  Failed: #{format_error(reason)}")
          %{acc | errors: acc.errors + 1, failed: [rel | acc.failed]}
      end
    end)
  end

  defp ingest_one(path, language, config) do
    context = %{
      language: language,
      file_path: path,
      project_path: config.project_path
    }

    with {:ok, doc} <- Metastatic.Builder.from_file(path, language) do
      {creates, relates} = MetaAST.ingest_tree_queries(doc.ast, context)

      if config.clean do
        MetaAST.Query.exec_delete_by_file(path, &Dllb.query/1)
      end

      upserts = Enum.map(creates, &(&1 <> " ON CONFLICT UPDATE"))
      all_queries = upserts ++ relates

      case Dllb.batch_transaction(all_queries) do
        {:ok, %Dllb.Result.Batch{created: created, updated: updated}} ->
          {:ok, created + updated, length(relates)}

        {:ok, %Dllb.Result.Error{message: msg}} ->
          Mix.shell().error("  Batch error: #{msg}")
          {:error, {:batch_error, msg}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # -- Output ----------------------------------------------------------------

  defp print_dry_run(files) do
    by_lang =
      files
      |> Enum.group_by(fn {_path, lang} -> lang end)
      |> Enum.sort_by(fn {lang, _} -> Atom.to_string(lang) end)

    Mix.shell().info("\nBy language:")

    for {lang, lang_files} <- by_lang do
      Mix.shell().info("  #{lang}: #{length(lang_files)}")
    end

    Mix.shell().info("")

    for {path, lang} <- files do
      Mix.shell().info("  [#{lang}] #{Path.relative_to(path, File.cwd!())}")
    end
  end

  defp print_summary(stats) do
    Mix.shell().info("")
    Mix.shell().info("Ingestion complete.")
    Mix.shell().info("  Files: #{stats.ok} succeeded, #{stats.errors} failed")
    Mix.shell().info("  Nodes: #{stats.nodes}")
    Mix.shell().info("  Edges: #{stats.edges}")

    if stats.failed != [] do
      Mix.shell().info("\nFailed files:")

      stats.failed
      |> Enum.reverse()
      |> Enum.each(&Mix.shell().error("  #{&1}"))
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp empty_stats, do: %{ok: 0, errors: 0, nodes: 0, edges: 0, failed: []}

  defp log(msg), do: Mix.shell().info(msg)

  defp return_ok, do: :ok

  defp format_error({:exception, msg}), do: msg
  defp format_error(reason), do: inspect(reason)

  defp ensure_metastatic! do
    unless Code.ensure_loaded?(Metastatic.Builder) do
      Mix.raise("""
      The :metastatic dependency is required for code ingestion.

      Add it to your mix.exs deps:

          {:metastatic, "~> 0.22"}

      Then run:

          mix deps.get
      """)
    end
  end

  defp ensure_pool_running! do
    case Process.whereis(Dllb.Pool) do
      nil ->
        Mix.raise("""
        dllb connection pool is not running.

        Make sure dllb is configured and the server is reachable:

            config :dllb,
              enabled: true,
              host: "127.0.0.1",
              port: 3009
        """)

      _pid ->
        :ok
    end
  end
end
