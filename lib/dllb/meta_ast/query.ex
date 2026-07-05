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
  Vector (HNSW) similarity search over `source_embedding`, built with the
  engine's native `VECTOR SEARCH` verb. Results come back nearest-first, each
  row carrying a `distance` field. Requires a vector index on
  `source_embedding` (see `Dllb.Schema.ast_node_search_indexes/0`).

  ## Options

    * `:limit` - max results (default 10)
    * `:kind` - optional kind filter (scopes results server-side)
    * `:file_path` - optional file filter
    * `:language` - optional language filter
    * `:project_path` - optional project filter (multi-project isolation)
  """
  @spec similar_to([number()], keyword()) :: String.t()
  def similar_to(embedding, opts \\ []) do
    k = Keyword.get(opts, :limit, 10)
    Query.vector_search(@table, "source_embedding", embedding, where: scope_where(opts), k: k)
  end

  @doc """
  Full-text BM25 search on `source_text`, built with the engine's native
  `SEARCH` verb. Each row carries a `score`. Requires a full-text index on
  `source_text`.

  ## Options

    * `:limit` - max results (default 20)
    * `:kind` / `:file_path` / `:language` / `:project_path` - optional scope
      filters
  """
  @spec search_source(String.t(), keyword()) :: String.t()
  def search_source(text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    Query.search(@table, "source_text", text, where: scope_where(opts), limit: limit)
  end

  @doc """
  Full-text BM25 search on `docstring`, built with the engine's native
  `SEARCH` verb. Each row carries a `score`.

  ## Options

    * `:limit` - max results (default 20)
  """
  @spec search_docs(String.t(), keyword()) :: String.t()
  def search_docs(text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    Query.search(@table, "docstring", text, limit: limit)
  end

  @doc """
  Combined full-text + vector hybrid search via the engine's native
  `HYBRID SEARCH` verb: BM25 on `source_text` fused with HNSW on
  `source_embedding`. Each row carries `score`, `text_score`, and
  `vector_score`.

  ## Options

    * `:limit` - max results (default 10)
    * `:alpha` - weight on the text score in `0.0..1.0` (default 0.5); the
      vector score gets `1 - alpha`
    * `:kind` / `:file_path` / `:language` / `:project_path` - optional scope
      filters
  """
  @spec hybrid_search(String.t(), [number()], keyword()) :: String.t()
  def hybrid_search(text, embedding, opts \\ []) do
    k = Keyword.get(opts, :limit, 10)
    alpha = Keyword.get(opts, :alpha, 0.5)

    Query.hybrid_search(@table, "source_text", text, "source_embedding", embedding,
      alpha: alpha,
      where: scope_where(opts),
      limit: k
    )
  end

  # ---------------------------------------------------------------------------
  # Structural similarity queries (server-side vector search)
  # ---------------------------------------------------------------------------

  @doc """
  Find structurally similar AST nodes using `structure_embedding` vector search.

  Requires a vector index on `structure_embedding` and that structure embeddings
  have been generated (via `Dllb.MetaAST.Similarity.subtree_hash/1` or a
  learned embedding).

  ## Options

    * `:limit` - max results (default 10)
    * `:kind` / `:file_path` / `:language` / `:project_path` - scope filters
  """
  @spec structurally_similar_to([number()], keyword()) :: String.t()
  def structurally_similar_to(structure_embedding, opts \\ []) do
    k = Keyword.get(opts, :limit, 10)

    Query.vector_search(@table, "structure_embedding", structure_embedding,
      where: scope_where(opts),
      k: k
    )
  end

  @doc """
  Sets the structure embedding for AST nodes matching the given attributes.

  `attrs` is a map of column => value used to identify the target rows.
  """
  @spec set_structure_embedding(map(), [number()]) :: String.t()
  def set_structure_embedding(attrs, embedding) when is_map(attrs) and is_list(embedding) do
    where =
      attrs
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(" AND ", fn {k, v} -> "#{k} = #{escape_attr(v)}" end)

    Query.update_where(@table, %{structure_embedding: embedding}, where)
  end

  # ---------------------------------------------------------------------------
  # HNSW snapshot commands
  # ---------------------------------------------------------------------------

  @doc """
  Trigger a snapshot of the source embedding HNSW index to persistent storage.
  """
  @spec snapshot_source_index() :: String.t()
  def snapshot_source_index, do: Query.vector_snapshot("vec_source_embedding")

  @doc """
  Trigger a snapshot of the structure embedding HNSW index to persistent storage.
  """
  @spec snapshot_structure_index() :: String.t()
  def snapshot_structure_index, do: Query.vector_snapshot("vec_structure_embedding")

  @doc """
  Restore the source embedding HNSW index from its latest snapshot.
  """
  @spec restore_source_index() :: String.t()
  def restore_source_index, do: Query.vector_restore("vec_source_embedding")

  @doc """
  Restore the structure embedding HNSW index from its latest snapshot.
  """
  @spec restore_structure_index() :: String.t()
  def restore_structure_index, do: Query.vector_restore("vec_structure_embedding")

  @doc """
  Get info about the source embedding HNSW index.
  """
  @spec source_index_info() :: String.t()
  def source_index_info, do: Query.vector_info("vec_source_embedding")

  @doc """
  Get info about the structure embedding HNSW index.
  """
  @spec structure_index_info() :: String.t()
  def structure_index_info, do: Query.vector_info("vec_structure_embedding")

  # ---------------------------------------------------------------------------
  # Lifecycle queries
  # ---------------------------------------------------------------------------

  @doc """
  Builds a single-statement `DELETE ast_node WHERE file_path = ...` that
  removes every node belonging to a file in one server-side operation
  (secondary, full-text, and vector indexes are maintained by the engine).
  Pair with `exec_delete_by_file/2`.
  """
  @spec delete_by_file(String.t()) :: String.t()
  def delete_by_file(file_path) do
    Query.delete_where(@table, "file_path = #{escape(file_path)}")
  end

  @doc """
  Builds a single-statement `DELETE ast_node WHERE project_path = ...` that
  removes every node of a project in one server-side operation. Pair with
  `exec_delete_by_project/2`.
  """
  @spec delete_by_project(String.t()) :: String.t()
  def delete_by_project(project_path) do
    Query.delete_where(@table, "project_path = #{escape(project_path)}")
  end

  @doc """
  Executes a native delete-by-file (`DELETE ... WHERE`) in a single
  round-trip, returning `{:ok, count}` (rows removed) or `{:error, reason}`.
  """
  @spec exec_delete_by_file(String.t(), MetaAST.query_fn()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def exec_delete_by_file(file_path, query_fn) do
    exec_delete_many(delete_by_file(file_path), query_fn)
  end

  @doc """
  Executes a native delete-by-project (`DELETE ... WHERE`) in a single
  round-trip, returning `{:ok, count}` or `{:error, reason}`.
  """
  @spec exec_delete_by_project(String.t(), MetaAST.query_fn()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def exec_delete_by_project(project_path, query_fn) do
    exec_delete_many(delete_by_project(project_path), query_fn)
  end

  @doc """
  Returns a `COUNT ast_node GROUP BY kind` query: one row per kind, each
  carrying a `count`, aggregated server-side.
  """
  @spec stats_query() :: String.t()
  def stats_query do
    Query.count(@table, group_by: "kind")
  end

  @doc """
  Executes the grouped stats query and returns
  `{:ok, %{total: n, by_kind: %{kind => count}}}`.

  The grouped rows carry serde-tagged values (e.g. `%{"String" => "..."}`),
  which are unwrapped here into plain kinds and integer counts.
  """
  @spec exec_stats(MetaAST.query_fn()) :: {:ok, map()} | {:error, term()}
  def exec_stats(query_fn) do
    with {:ok, rows} <- exec_rows(stats_query(), query_fn) do
      by_kind = Map.new(rows, fn row -> {unwrap(row["kind"]), unwrap(row["count"])} end)
      total = by_kind |> Map.values() |> Enum.sum()
      {:ok, %{total: total, by_kind: by_kind}}
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

  defp exec_delete_many(query_string, query_fn) do
    case query_fn.(query_string) do
      {:ok, %Dllb.Result.DeletedMany{count: count}} -> {:ok, count}
      {:ok, %Dllb.Result.Error{message: msg}} -> {:error, {:query_error, msg}}
      {:ok, other} -> {:error, {:unexpected_result, other}}
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

  # Builds an optional WHERE clause from scope options (kind/file_path/
  # language/project_path), ANDing the present filters. Returns `nil` when no
  # scope option is given so the search verb omits WHERE entirely.
  defp scope_where(opts) do
    []
    |> maybe_add_filter(:project_path, opts)
    |> maybe_add_filter(:language, opts)
    |> maybe_add_filter(:file_path, opts)
    |> maybe_add_filter(:kind, opts)
    |> case do
      [] -> nil
      filters -> Enum.join(filters, " AND ")
    end
  end

  # dllb serde-tags Values by variant: %{"String" => v}, %{"Int" => n}, ...
  # `Value::None` serializes to the bare string "None".
  defp unwrap(%{"String" => v}), do: v
  defp unwrap(%{"Int" => v}), do: v
  defp unwrap(%{"Float" => v}), do: v
  defp unwrap(%{"Bool" => v}), do: v
  defp unwrap("None"), do: nil
  defp unwrap(v), do: v
end
