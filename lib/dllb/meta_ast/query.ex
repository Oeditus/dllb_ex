defmodule Dllb.MetaAST.Query do
  @moduledoc """
  Domain-aware query builders for MetaAST data stored in dllb.

  Every function returns a plain query string (or list of query strings)
  ready to be sent through `Dllb.query/1` or `Dllb.batch/1`. Higher-level
  `exec_*` variants accept a query function and return parsed results via
  `Dllb.MetaAST.from_dllb_row/1`.

  ## Query categories

    - **Node queries** -- find/list AST nodes by file, kind, module, or composite key
    - **Graph traversals** -- callers, callees, importers, imports, call chains
    - **Search** -- HNSW vector similarity, full-text BM25, hybrid
    - **Lifecycle** -- delete by file/project, stats
    - **Tree reconstruction** -- rebuild MetaAST 3-tuples from stored data
  """

  alias Dllb.{MetaAST, Query}

  @table "ast_node"

  # ---------------------------------------------------------------------------
  # Node queries
  # ---------------------------------------------------------------------------

  @doc """
  SELECT all AST nodes belonging to a file.
  """
  @spec nodes_by_file(String.t(), keyword()) :: String.t()
  def nodes_by_file(file_path, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    escaped = escape(file_path)
    Query.select(@table, where: "file_path = #{escaped}", limit: limit)
  end

  @doc """
  SELECT all AST nodes of a given kind (e.g. `"function_def"`, `"container"`).
  """
  @spec nodes_by_kind(String.t(), keyword()) :: String.t()
  def nodes_by_kind(kind, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    escaped = escape(kind)
    Query.select(@table, where: "kind = #{escaped}", limit: limit)
  end

  @doc """
  SELECT function nodes belonging to a module.

  Requires the `module` field to be populated during ingestion.
  """
  @spec functions_of_module(String.t(), keyword()) :: String.t()
  def functions_of_module(module_name, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    escaped = escape(module_name)
    Query.select(@table, where: "kind = 'function_def' AND module = #{escaped}", limit: limit)
  end

  @doc """
  SELECT a module (container) node by name.
  """
  @spec find_module(String.t()) :: String.t()
  def find_module(name) do
    escaped = escape(name)
    Query.select(@table, where: "kind = 'container' AND name = #{escaped}", limit: 1)
  end

  @doc """
  SELECT a function node by module, name, and arity.
  """
  @spec find_function(String.t(), String.t(), non_neg_integer()) :: String.t()
  def find_function(module_name, func_name, arity) do
    where =
      "kind = 'function_def' AND module = #{escape(module_name)} AND name = #{escape(func_name)} AND arity = #{arity}"

    Query.select(@table, where: where, limit: 1)
  end

  @doc """
  SELECT nodes filtered by project path.
  """
  @spec nodes_by_project(String.t(), keyword()) :: String.t()
  def nodes_by_project(project_path, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    escaped = escape(project_path)
    Query.select(@table, where: "project_path = #{escaped}", limit: limit)
  end

  # ---------------------------------------------------------------------------
  # Graph traversal queries
  # ---------------------------------------------------------------------------

  @doc """
  Graph traversal: find all callers of a node (incoming `calls` edges).

  Returns a SELECT with `<-calls<-ast_node` traversal syntax.
  """
  @spec callers_of(String.t()) :: String.t()
  def callers_of(record_id) do
    "SELECT <-calls<-ast_node FROM #{record_id}"
  end

  @doc """
  Graph traversal: find all callees of a node (outgoing `calls` edges).
  """
  @spec callees_of(String.t()) :: String.t()
  def callees_of(record_id) do
    "SELECT ->calls->ast_node FROM #{record_id}"
  end

  @doc """
  Graph traversal: find all modules that import a given node.
  """
  @spec importers_of(String.t()) :: String.t()
  def importers_of(record_id) do
    "SELECT <-imports<-ast_node FROM #{record_id}"
  end

  @doc """
  Graph traversal: find all imports of a node.
  """
  @spec imports_of(String.t()) :: String.t()
  def imports_of(record_id) do
    "SELECT ->imports->ast_node FROM #{record_id}"
  end

  @doc """
  Multi-hop call chain traversal from a starting node.

  Builds a chained `->calls->ast_node` traversal repeated `depth` times.
  """
  @spec call_chain(String.t(), pos_integer()) :: String.t()
  def call_chain(record_id, depth) when depth >= 1 do
    chain = String.duplicate("->calls->ast_node", depth)
    "SELECT #{chain} FROM #{record_id}"
  end

  # ---------------------------------------------------------------------------
  # Search queries
  # ---------------------------------------------------------------------------

  @doc """
  HNSW vector similarity search on `source_embedding`.

  ## Options

    * `:limit` - max results (default 10)
    * `:ef` - HNSW exploration factor (default 100)
    * `:kind` - optional kind filter
    * `:file_path` - optional file filter
    * `:language` - optional language filter
  """
  @spec similar_to([float()], keyword()) :: String.t()
  def similar_to(embedding, opts \\ []) do
    k = Keyword.get(opts, :limit, 10)
    ef = Keyword.get(opts, :ef, 100)

    vec_str = "[" <> Enum.map_join(embedding, ", ", &to_string/1) <> "]"
    knn_clause = "source_embedding <|#{k},#{ef}|> #{vec_str}"

    filters =
      []
      |> maybe_add_filter(:kind, opts)
      |> maybe_add_filter(:file_path, opts)
      |> maybe_add_filter(:language, opts)

    where_clause =
      case filters do
        [] -> knn_clause
        parts -> Enum.join(parts, " AND ") <> " AND " <> knn_clause
      end

    Query.select(@table,
      fields: [
        "id",
        "name",
        "kind",
        "file_path",
        "source_text",
        "vector::distance::knn() AS score"
      ],
      where: where_clause,
      order: "score",
      limit: k
    )
  end

  @doc """
  Full-text BM25 search on `source_text`.

  ## Options

    * `:limit` - max results (default 20)
    * `:kind` - optional kind filter
  """
  @spec search_source(String.t(), keyword()) :: String.t()
  def search_source(text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    escaped = escape(text)

    where =
      case Keyword.get(opts, :kind) do
        nil -> "source_text @@ #{escaped}"
        kind -> "kind = #{escape(kind)} AND source_text @@ #{escaped}"
      end

    Query.select(@table,
      fields: ["id", "name", "kind", "file_path", "source_text", "search::score(1) AS score"],
      where: where,
      order: "score DESC",
      limit: limit
    )
  end

  @doc """
  Full-text BM25 search on `docstring`.
  """
  @spec search_docs(String.t(), keyword()) :: String.t()
  def search_docs(text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    escaped = escape(text)

    Query.select(@table,
      fields: ["id", "name", "kind", "file_path", "docstring", "search::score(1) AS score"],
      where: "docstring @@ #{escaped}",
      order: "score DESC",
      limit: limit
    )
  end

  @doc """
  Combined vector + full-text hybrid search.

  Scores are combined as `vec_weight * vec_score + ft_weight * ft_score`.

  ## Options

    * `:limit` - max results (default 10)
    * `:ef` - HNSW exploration factor (default 100)
    * `:vec_weight` - weight for vector score (default 0.6)
    * `:ft_weight` - weight for full-text score (default 0.4)
  """
  @spec hybrid_search(String.t(), [float()], keyword()) :: String.t()
  def hybrid_search(text, embedding, opts \\ []) do
    k = Keyword.get(opts, :limit, 10)
    ef = Keyword.get(opts, :ef, 100)
    vec_w = Keyword.get(opts, :vec_weight, 0.6)
    ft_w = Keyword.get(opts, :ft_weight, 0.4)

    vec_str = "[" <> Enum.map_join(embedding, ", ", &to_string/1) <> "]"
    escaped_text = escape(text)

    where = "source_embedding <|#{k * 2},#{ef}|> #{vec_str} AND source_text @@ #{escaped_text}"

    order = "(1.0 - vector::distance::knn()) * #{vec_w} + search::score(1) * #{ft_w} DESC"

    Query.select(@table,
      fields: [
        "id",
        "name",
        "kind",
        "file_path",
        "source_text",
        "vector::distance::knn() AS vec_score",
        "search::score(1) AS ft_score"
      ],
      where: where,
      order: order,
      limit: k
    )
  end

  # ---------------------------------------------------------------------------
  # Lifecycle queries
  # ---------------------------------------------------------------------------

  @doc """
  Deletes all AST nodes belonging to a file.

  Since dllb currently supports `DELETE table:id` (point deletes) but not
  `DELETE ... WHERE`, this returns a two-step approach: a SELECT to find
  the ids, then point DELETEs for each. Use with `exec_delete_by_file/2`.
  """
  @spec delete_by_file_select(String.t()) :: String.t()
  def delete_by_file_select(file_path) do
    Query.select(@table, fields: ["id"], where: "file_path = #{escape(file_path)}")
  end

  @doc """
  Executes a two-step delete-by-file: SELECT ids, then batch DELETE.

  Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec exec_delete_by_file(String.t(), MetaAST.query_fn()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def exec_delete_by_file(file_path, query_fn) do
    select_q = delete_by_file_select(file_path)

    with {:ok, rows} <- exec_rows(select_q, query_fn) do
      ids = Enum.map(rows, & &1["id"])
      delete_queries = Enum.map(ids, &Query.delete/1)

      errors =
        delete_queries
        |> Enum.map(query_fn)
        |> Enum.filter(&match?({:error, _}, &1))

      case errors do
        [] -> {:ok, length(ids)}
        [first_error | _] -> first_error
      end
    end
  end

  @doc """
  Executes a two-step delete-by-project: SELECT ids, then batch DELETE.
  """
  @spec exec_delete_by_project(String.t(), MetaAST.query_fn()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def exec_delete_by_project(project_path, query_fn) do
    select_q =
      Query.select(@table, fields: ["id"], where: "project_path = #{escape(project_path)}")

    with {:ok, rows} <- exec_rows(select_q, query_fn) do
      ids = Enum.map(rows, & &1["id"])
      delete_queries = Enum.map(ids, &Query.delete/1)

      errors =
        delete_queries
        |> Enum.map(query_fn)
        |> Enum.filter(&match?({:error, _}, &1))

      case errors do
        [] -> {:ok, length(ids)}
        [first_error | _] -> first_error
      end
    end
  end

  @doc """
  Returns a SELECT for overall statistics (node count).

  Note: dllb does not yet support COUNT/GROUP BY, so this returns all ids
  and the caller aggregates client-side.
  """
  @spec stats_query() :: String.t()
  def stats_query do
    Query.select(@table, fields: ["id", "kind"])
  end

  @doc """
  Executes stats query and returns aggregated counts.
  """
  @spec exec_stats(MetaAST.query_fn()) :: {:ok, map()} | {:error, term()}
  def exec_stats(query_fn) do
    with {:ok, rows} <- exec_rows(stats_query(), query_fn) do
      by_kind =
        rows
        |> Enum.group_by(& &1["kind"])
        |> Map.new(fn {kind, items} -> {kind, length(items)} end)

      {:ok, %{total: length(rows), by_kind: by_kind}}
    end
  end

  # ---------------------------------------------------------------------------
  # Embeddings
  # ---------------------------------------------------------------------------

  @doc """
  Builds an `UPDATE ast_node SET source_embedding = [...] WHERE <attrs>`
  statement that attaches an embedding to the row(s) identified by `attrs`.

  `attrs` is a map of column => value (e.g. `%{kind: "function_def",
  module: "Foo", name: "bar", arity: 2}`). `nil` values are dropped and the
  remaining columns are ANDed together (sorted for determinism). Targeting by
  stable attributes avoids reconstructing synthetic record IDs.
  """
  @spec set_source_embedding(map(), [number()]) :: String.t()
  def set_source_embedding(attrs, embedding) when is_map(attrs) and is_list(embedding) do
    where =
      attrs
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(" AND ", fn {k, v} -> "#{k} = #{escape_attr(v)}" end)

    Query.update_where(@table, %{source_embedding: embedding}, where)
  end

  @doc """
  Returns a `COUNT` query for `ast_node` rows that have a `source_embedding`
  set -- i.e. the number of stored embedding vectors.
  """
  @spec count_embeddings_query() :: String.t()
  def count_embeddings_query do
    Query.count(@table, where: "source_embedding IS NOT NONE")
  end

  @doc """
  Executes a `COUNT` query and returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec exec_count(String.t(), MetaAST.query_fn()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def exec_count(query_string, query_fn) do
    case query_fn.(query_string) do
      {:ok, %Dllb.Result.Count{count: count}} -> {:ok, count}
      {:ok, %Dllb.Result.Error{message: msg}} -> {:error, {:query_error, msg}}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Counts stored embedding vectors (`ast_node` rows with `source_embedding`).
  """
  @spec exec_count_embeddings(MetaAST.query_fn()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def exec_count_embeddings(query_fn) do
    exec_count(count_embeddings_query(), query_fn)
  end

  # ---------------------------------------------------------------------------
  # Tree reconstruction
  # ---------------------------------------------------------------------------

  @doc """
  Loads all nodes for a file and returns them as parsed maps.
  """
  @spec exec_load_file_nodes(String.t(), MetaAST.query_fn()) :: {:ok, [map()]} | {:error, term()}
  def exec_load_file_nodes(file_path, query_fn) do
    q = nodes_by_file(file_path)

    with {:ok, rows} <- exec_rows(q, query_fn) do
      {:ok, Enum.map(rows, &MetaAST.from_dllb_row/1)}
    end
  end

  # ---------------------------------------------------------------------------
  # Generic execution helpers
  # ---------------------------------------------------------------------------

  @doc """
  Executes a query through `query_fn` and returns parsed result maps.
  """
  @spec exec(String.t(), MetaAST.query_fn()) :: {:ok, [map()]} | {:error, term()}
  def exec(query_string, query_fn) do
    with {:ok, rows} <- exec_rows(query_string, query_fn) do
      {:ok, Enum.map(rows, &MetaAST.from_dllb_row/1)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp exec_rows(query_string, query_fn) do
    case query_fn.(query_string) do
      {:ok, %Dllb.Result.Rows{data: data}} -> {:ok, data}
      {:ok, %Dllb.Result.Ok{}} -> {:ok, []}
      {:ok, %Dllb.Result.Error{message: msg}} -> {:error, {:query_error, msg}}
      {:ok, _other} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  defp escape(value) when is_binary(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  # Escapes a WHERE-clause value: integers stay bare, everything else is
  # treated as a quoted string.
  defp escape_attr(value) when is_integer(value), do: Integer.to_string(value)
  defp escape_attr(value) when is_binary(value), do: escape(value)
  defp escape_attr(value), do: escape(to_string(value))

  defp maybe_add_filter(filters, key, opts) do
    case Keyword.get(opts, key) do
      nil -> filters
      value -> ["#{key} = #{escape(to_string(value))}" | filters]
    end
  end
end
