defmodule Dllb.Query do
  @moduledoc """
  Query builder that generates dllb SQL strings.

  Provides functions to construct CREATE, SELECT (with ORDER BY), UPDATE,
  DELETE (point and `DELETE ... WHERE`), RELATE, COUNT (with GROUP BY),
  DEFINE (secondary, full-text, and vector index), REMOVE INDEX, SEARCH /
  VECTOR SEARCH / HYBRID SEARCH (with optional WHERE scoping), and the graph
  analytics verbs (COMMUNITIES, COMPONENTS, PAGERANK, CENTRALITY, PATH, EDGES)
  for the dllb query language. All functions return plain query strings ready
  to be sent over the wire.
  """

  @type fields :: %{optional(atom()) => term()}
  @type select_opts :: [
          fields: [String.t()],
          where: String.t(),
          order: String.t(),
          limit: non_neg_integer(),
          fetch: String.t()
        ]

  @doc """
  Builds a CREATE statement for inserting a new record.

  ## Examples

      iex> Dllb.Query.create("user", %{name: "Alice", age: 30})
      "CREATE user SET age = 30, name = 'Alice'"

  """
  @spec create(String.t(), fields()) :: String.t()
  def create(table, fields) when is_map(fields) do
    "CREATE #{table} SET #{set_clause(fields)}"
  end

  @doc """
  Builds a CREATE statement with an explicit record ID.

  ## Examples

      iex> Dllb.Query.create_with_id("user", "u1", %{name: "Alice"})
      "CREATE user:u1 SET name = 'Alice'"

  """
  @spec create_with_id(String.t(), String.t(), fields()) :: String.t()
  def create_with_id(table, id, fields) when is_map(fields) do
    "CREATE #{table}:#{id} SET #{set_clause(fields)}"
  end

  @doc """
  Builds a SELECT statement with optional clauses.

  ## Options

    * `:fields` - list of field names to select (default `["*"]`)
    * `:where` - WHERE clause string
    * `:order` - ORDER BY clause string
    * `:limit` - LIMIT value
    * `:fetch` - graph traversal fetch clause (e.g. `"->calls->fn_node"`)

  ## Examples

      iex> Dllb.Query.select("user", where: "age > 25", limit: 10)
      "SELECT * FROM user WHERE age > 25 LIMIT 10"

  """
  @spec select(String.t(), select_opts()) :: String.t()
  def select(table, opts \\ []) do
    fields = opts |> Keyword.get(:fields, ["*"]) |> Enum.join(", ")

    query = "SELECT #{fields} FROM #{table}"

    query
    |> maybe_append("WHERE", Keyword.get(opts, :where))
    |> maybe_append("FETCH", Keyword.get(opts, :fetch))
    |> maybe_append("ORDER BY", Keyword.get(opts, :order))
    |> maybe_append_limit(Keyword.get(opts, :limit))
  end

  @doc """
  Builds an UPDATE statement for an existing record.

  ## Examples

      iex> Dllb.Query.update("user:u1", %{name: "Bob"})
      "UPDATE user:u1 SET name = 'Bob'"

  """
  @spec update(String.t(), fields()) :: String.t()
  def update(record_id, fields) when is_map(fields) do
    "UPDATE #{record_id} SET #{set_clause(fields)}"
  end

  @doc """
  Builds an `UPDATE <table> SET ... WHERE <clause>` statement that updates
  every row matching the (already-built) WHERE clause.

  Only the listed fields are changed (partial-update semantics). An empty
  WHERE string updates all rows in the table.

  ## Examples

      iex> Dllb.Query.update_where("ast_node", %{arity: 1}, "kind = 'function_def'")
      "UPDATE ast_node SET arity = 1 WHERE kind = 'function_def'"

  """
  @spec update_where(String.t(), fields(), String.t()) :: String.t()
  def update_where(table, fields, where) when is_map(fields) and is_binary(where) do
    base = "UPDATE #{table} SET #{set_clause(fields)}"

    case String.trim(where) do
      "" -> base
      clause -> "#{base} WHERE #{clause}"
    end
  end

  @doc """
  Builds a `COUNT <table> [WHERE <clause>] [GROUP BY <field>]` statement.

  Without `:group_by` the engine returns a single total count. With
  `:group_by`, it returns one row per distinct value of the field, each with a
  `count`, sorted by count descending (a `Dllb.Result.Rows`, not a
  `Dllb.Result.Count`).

  ## Options

    * `:where` - optional WHERE clause string
    * `:group_by` - optional field name to group counts by

  ## Examples

      iex> Dllb.Query.count("user")
      "COUNT user"

      iex> Dllb.Query.count("user", where: "age = 30")
      "COUNT user WHERE age = 30"

      iex> Dllb.Query.count("ast_node", group_by: "kind")
      "COUNT ast_node GROUP BY kind"

  """
  @spec count(String.t(), keyword()) :: String.t()
  def count(table, opts \\ []) do
    "COUNT #{table}"
    |> maybe_append("WHERE", Keyword.get(opts, :where))
    |> maybe_append("GROUP BY", Keyword.get(opts, :group_by))
  end

  @doc """
  Builds a DELETE statement for a single record.

  ## Examples

      iex> Dllb.Query.delete("user:u1")
      "DELETE user:u1"

  """
  @spec delete(String.t()) :: String.t()
  def delete(record_id) do
    "DELETE #{record_id}"
  end

  @doc """
  Builds a `DELETE <table> [WHERE <clause>]` statement that removes every row
  matching the (already-built) WHERE clause in a single server-side operation.

  Secondary, full-text, and vector indexes are maintained by the engine. The
  result is a `Dllb.Result.DeletedMany` reporting how many rows were removed.
  An empty (or omitted) WHERE deletes every row in the table.

  ## Examples

      iex> Dllb.Query.delete_where("ast_node", "file_path = '/a.ex'")
      "DELETE ast_node WHERE file_path = '/a.ex'"

      iex> Dllb.Query.delete_where("ast_node")
      "DELETE ast_node"

  """
  @spec delete_where(String.t(), String.t() | nil) :: String.t()
  def delete_where(table, where \\ nil) do
    maybe_append("DELETE #{table}", "WHERE", where)
  end

  @doc """
  Builds a `CREATE ... ON CONFLICT UPDATE` statement for idempotent upserts.

  If the record already exists (by table + id), the conflict is resolved by
  updating it instead of failing:

    * with no `update_fields` (or an empty map), the engine merges the same
      `fields` from the CREATE into the existing record (`ON CONFLICT UPDATE`);
    * with a non-empty `update_fields` map, the engine applies those explicit
      fields to the existing record instead (`ON CONFLICT UPDATE SET ...`).

  ## Examples

      iex> Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30})
      "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE"

      iex> Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30}, %{age: 31})
      "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE SET age = 31"

  """
  @spec upsert(String.t(), String.t(), fields(), fields()) :: String.t()
  def upsert(table, id, fields, update_fields \\ %{})
      when is_map(fields) and is_map(update_fields) do
    base = "CREATE #{table}:#{id} SET #{set_clause(fields)} ON CONFLICT UPDATE"

    case map_size(update_fields) do
      0 -> base
      _ -> "#{base} SET #{set_clause(update_fields)}"
    end
  end

  @doc """
  Builds a RELATE statement to create a graph edge between two records.

  ## Examples

      iex> Dllb.Query.relate("user:a", "follows", "user:b", %{since: "2024"})
      "RELATE user:a->follows->user:b SET since = '2024'"

  """
  @spec relate(String.t(), String.t(), String.t(), fields()) :: String.t()
  def relate(from_id, edge_type, to_id, properties \\ %{}) do
    base = "RELATE #{from_id}->#{edge_type}->#{to_id}"

    case map_size(properties) do
      0 -> base
      _ -> "#{base} SET #{set_clause(properties)}"
    end
  end

  @doc """
  Builds a DEFINE TABLE statement.

  Mode can be `:schemafull` or `:schemaless`.

  ## Examples

      iex> Dllb.Query.define_table("user", :schemafull)
      "DEFINE TABLE user SCHEMAFULL"

  """
  @spec define_table(String.t(), :schemafull | :schemaless) :: String.t()
  def define_table(name, mode) when mode in [:schemafull, :schemaless] do
    mode_str = mode |> Atom.to_string() |> String.upcase()
    "DEFINE TABLE #{name} #{mode_str}"
  end

  @doc """
  Builds a DEFINE FIELD statement.

  ## Options

    * `:required` - if `true`, appends ASSERT $value IS NOT NONE

  ## Examples

      iex> Dllb.Query.define_field("user", "name", "string", required: true)
      "DEFINE FIELD name ON user TYPE string ASSERT $value IS NOT NONE"

  """
  @spec define_field(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def define_field(table, name, type, opts \\ []) do
    base = "DEFINE FIELD #{name} ON #{table} TYPE #{type}"

    if Keyword.get(opts, :required, false) do
      "#{base} ASSERT $value IS NOT NONE"
    else
      base
    end
  end

  @doc """
  Builds a `DEFINE INDEX` statement that registers a persisted secondary
  index in the engine's catalog and backfills entries for existing rows.

  The index covers one or more `fields`. Composite (multi-field) indexes are
  matched by the engine using leftmost-prefix planning, so list the most
  selective leading field first. Once defined, equality and range
  (`>`, `>=`, `<`, `<=`) predicates on the indexed fields are transparently
  accelerated in `SELECT`/`COUNT`/`UPDATE` `WHERE` clauses — no change to the
  query strings is required.

  ## Options

    * `:unique` - when `true`, enforces uniqueness over the full indexed
      tuple; defining the index fails if existing rows already hold duplicate
      values (default `false`)

  ## Examples

      iex> Dllb.Query.define_index("user", "by_age", ["age"])
      "DEFINE INDEX by_age ON TABLE user FIELDS age"

      iex> Dllb.Query.define_index("user", "by_email", ["email"], unique: true)
      "DEFINE INDEX by_email ON TABLE user FIELDS email UNIQUE"

      iex> Dllb.Query.define_index("ast_node", "idx_file_kind", ["file_path", "kind"])
      "DEFINE INDEX idx_file_kind ON TABLE ast_node FIELDS file_path, kind"

  """
  @spec define_index(String.t(), String.t(), [String.t()], keyword()) :: String.t()
  def define_index(table, name, fields, opts \\ []) when is_list(fields) do
    base = "DEFINE INDEX #{name} ON TABLE #{table} FIELDS #{Enum.join(fields, ", ")}"

    if Keyword.get(opts, :unique, false) do
      "#{base} UNIQUE"
    else
      base
    end
  end

  @doc """
  Builds a `REMOVE INDEX` statement that drops a secondary index and all of
  its catalog entries. Subsequent queries fall back to full scans.

  ## Examples

      iex> Dllb.Query.remove_index("user", "by_age")
      "REMOVE INDEX by_age ON TABLE user"

  """
  @spec remove_index(String.t(), String.t()) :: String.t()
  def remove_index(table, name) do
    "REMOVE INDEX #{name} ON TABLE #{table}"
  end

  @doc """
  Builds a `DEFINE FULLTEXT INDEX` statement that registers a BM25 full-text
  (Tantivy) index over a single text `field`.

  Requires a dllb server with full-text/vector services enabled (the default
  server build).

  ## Options

    * `:analyzer` - tokenizer/stemmer to apply. One of `"default"`, `"simple"`,
      or a language (`"english"`, `"spanish"`, `"french"`, `"german"`,
      `"italian"`, `"portuguese"`, `"russian"`). Defaults to the engine's
      `default` analyzer when omitted.

  ## Examples

      iex> Dllb.Query.define_fulltext_index("article", "ft_body", "body")
      "DEFINE FULLTEXT INDEX ft_body ON TABLE article FIELDS body"

      iex> Dllb.Query.define_fulltext_index("article", "ft_body", "body", analyzer: "english")
      "DEFINE FULLTEXT INDEX ft_body ON TABLE article FIELDS body ANALYZER english"

  """
  @spec define_fulltext_index(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def define_fulltext_index(table, name, field, opts \\ []) do
    base = "DEFINE FULLTEXT INDEX #{name} ON TABLE #{table} FIELDS #{field}"

    case Keyword.get(opts, :analyzer) do
      nil -> base
      "" -> base
      analyzer -> "#{base} ANALYZER #{analyzer}"
    end
  end

  @doc """
  Builds a `DEFINE VECTOR INDEX` statement that registers an approximate
  nearest-neighbour (HNSW) index over a dense-embedding `field`.

  `dimension` is the (positive) length of the vectors to be indexed. Requires
  a dllb server with full-text/vector services enabled (the default server
  build).

  ## Options

    * `:metric` - distance metric: `"cosine"` (default), `"euclidean"` (alias
      `"l2"`), or `"dot"` (alias `"dotproduct"`/`"dot_product"`). Defaults to
      the engine's `cosine` metric when omitted.

  ## Examples

      iex> Dllb.Query.define_vector_index("ast_node", "vec_src", "source_embedding", 768)
      "DEFINE VECTOR INDEX vec_src ON TABLE ast_node FIELDS source_embedding DIMENSION 768"

      iex> Dllb.Query.define_vector_index("doc", "vec_emb", "embedding", 8, metric: "euclidean")
      "DEFINE VECTOR INDEX vec_emb ON TABLE doc FIELDS embedding DIMENSION 8 METRIC euclidean"

  """
  @spec define_vector_index(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          String.t()
  def define_vector_index(table, name, field, dimension, opts \\ [])
      when is_integer(dimension) and dimension > 0 do
    base =
      "DEFINE VECTOR INDEX #{name} ON TABLE #{table} FIELDS #{field} DIMENSION #{dimension}"

    case Keyword.get(opts, :metric) do
      nil -> base
      "" -> base
      metric -> "#{base} METRIC #{metric}"
    end
  end

  @doc """
  Builds a `SEARCH` statement: a BM25 full-text query against a `field` that
  has a full-text index. Results come back as rows ranked best-first, each
  carrying an extra `score` field.

  ## Options

    * `:where` - optional WHERE clause to scope results server-side (applied
      to the ranked hits before `:limit`)
    * `:limit` - maximum number of hits to return

  ## Examples

      iex> Dllb.Query.search("article", "body", "graph database")
      "SEARCH article body 'graph database'"

      iex> Dllb.Query.search("article", "body", "graph database", limit: 5)
      "SEARCH article body 'graph database' LIMIT 5"

      iex> Dllb.Query.search("article", "body", "graph", where: "lang = 'en'", limit: 5)
      "SEARCH article body 'graph' WHERE lang = 'en' LIMIT 5"

  """
  @spec search(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def search(table, field, query, opts \\ []) when is_binary(query) do
    "SEARCH #{table} #{field} #{escape_value(query)}"
    |> maybe_append("WHERE", Keyword.get(opts, :where))
    |> maybe_append_limit(Keyword.get(opts, :limit))
  end

  @doc """
  Builds a `VECTOR SEARCH` statement: an approximate nearest-neighbour query
  against a `field` that has a vector index. `vector` is the query embedding
  (a list of numbers). Results come back as rows ordered nearest-first, each
  carrying an extra `distance` field.

  ## Options

    * `:where` - optional WHERE clause to scope results server-side (applied
      to the ranked hits before `:k`)
    * `:k` - number of nearest neighbours to return

  ## Examples

      iex> Dllb.Query.vector_search("doc", "embedding", [0.1, 0.2, 0.3])
      "VECTOR SEARCH doc embedding [0.1, 0.2, 0.3]"

      iex> Dllb.Query.vector_search("doc", "embedding", [0.1, 0.2, 0.3], k: 5)
      "VECTOR SEARCH doc embedding [0.1, 0.2, 0.3] K 5"

      iex> Dllb.Query.vector_search("doc", "embedding", [0.1, 0.2], where: "project = 'p1'", k: 5)
      "VECTOR SEARCH doc embedding [0.1, 0.2] WHERE project = 'p1' K 5"

  """
  @spec vector_search(String.t(), String.t(), [number()], keyword()) :: String.t()
  def vector_search(table, field, vector, opts \\ []) when is_list(vector) do
    "VECTOR SEARCH #{table} #{field} #{escape_value(vector)}"
    |> maybe_append("WHERE", Keyword.get(opts, :where))
    |> maybe_append_int("K", Keyword.get(opts, :k))
  end

  @doc """
  Builds a `HYBRID SEARCH` statement that fuses a BM25 full-text query on
  `text_field` with an approximate nearest-neighbour query on `vector_field`.

  The engine normalises each modality's scores independently and blends them
  as `alpha * text_score + (1 - alpha) * vector_score`, then returns rows
  ranked best-first, each carrying `score`, `text_score`, and `vector_score`
  fields. Requires a full-text index on `text_field` and a vector index on
  `vector_field`.

  ## Options

    * `:alpha` - weight on the (normalised) text score, in `0.0..1.0`; the
      vector score gets `1 - alpha`. Defaults to the engine's `0.5`.
    * `:where` - optional WHERE clause to scope results server-side
    * `:limit` - maximum number of hits to return

  ## Examples

      iex> Dllb.Query.hybrid_search("doc", "body", "graph db", "embedding", [0.1, 0.2])
      "HYBRID SEARCH doc TEXT body 'graph db' VECTOR embedding [0.1, 0.2]"

      iex> Dllb.Query.hybrid_search("doc", "body", "graph", "embedding", [0.1, 0.2], alpha: 0.7, limit: 5)
      "HYBRID SEARCH doc TEXT body 'graph' VECTOR embedding [0.1, 0.2] ALPHA 0.7 LIMIT 5"

  """
  @spec hybrid_search(String.t(), String.t(), String.t(), String.t(), [number()], keyword()) ::
          String.t()
  def hybrid_search(table, text_field, query, vector_field, vector, opts \\ [])
      when is_binary(query) and is_list(vector) do
    "HYBRID SEARCH #{table} TEXT #{text_field} #{escape_value(query)} VECTOR #{vector_field} #{escape_value(vector)}"
    |> maybe_append_number("ALPHA", Keyword.get(opts, :alpha))
    |> maybe_append("WHERE", Keyword.get(opts, :where))
    |> maybe_append_limit(Keyword.get(opts, :limit))
  end

  @doc """
  Builds a `GRAPH COMMUNITIES` statement for native community detection.

  Delegates computation to the dllb engine (Rust Louvain / Label Propagation),
  which runs in O(E) per iteration — orders of magnitude faster than the
  equivalent pure-Elixir implementation on large graphs.

  ## Options

    * `:algorithm` - `:louvain` (default) or `:lp` (label propagation)
    * `:max_iter`  - maximum optimisation passes (default: 10)
    * `:resolution` - Louvain resolution γ; values < 1.0 → fewer, larger
      communities; > 1.0 → more, smaller communities (default: 1.0)

  ## Examples

      iex> Dllb.Query.graph_communities("calls")
      "GRAPH COMMUNITIES calls"

      iex> Dllb.Query.graph_communities("calls", algorithm: :lp, max_iter: 20)
      "GRAPH COMMUNITIES calls ALGORITHM lp MAX_ITER 20"

      iex> Dllb.Query.graph_communities("calls", algorithm: :louvain, resolution: 0.5)
      "GRAPH COMMUNITIES calls ALGORITHM louvain RESOLUTION 0.5"

  """
  @spec graph_communities(String.t(), keyword()) :: String.t()
  def graph_communities(edge_table, opts \\ []) do
    base = "GRAPH COMMUNITIES #{edge_table}"

    base
    |> maybe_append_algorithm(Keyword.get(opts, :algorithm))
    |> maybe_append_int("MAX_ITER", Keyword.get(opts, :max_iter))
    |> maybe_append_resolution(Keyword.get(opts, :resolution))
  end

  @doc """
  Builds a `GRAPH COMPONENTS <edge_table>` statement for native connected-
  components detection.

  Delegates computation to the dllb engine (Rust union-find over the edge
  table, treated as undirected). The server returns a compact summary
  (`component_count`, `largest`, `nodes`) rather than full membership.

  ## Examples

      iex> Dllb.Query.graph_components("calls")
      "GRAPH COMPONENTS calls"

  """
  @spec graph_components(String.t()) :: String.t()
  def graph_components(edge_table) do
    "GRAPH COMPONENTS #{edge_table}"
  end

  @doc """
  Builds a `GRAPH PAGERANK <edge_table>` statement: weighted PageRank over the
  edge table, returning `{id, score}` rows ranked by score descending.

  ## Options

    * `:damping` - damping factor (default the engine's `0.85`)
    * `:max_iter` - maximum power-iteration steps (default the engine's `100`)
    * `:limit` - return only the top-N nodes

  ## Examples

      iex> Dllb.Query.graph_pagerank("calls")
      "GRAPH PAGERANK calls"

      iex> Dllb.Query.graph_pagerank("calls", damping: 0.9, max_iter: 50, limit: 10)
      "GRAPH PAGERANK calls DAMPING 0.9 MAX_ITER 50 LIMIT 10"

  """
  @spec graph_pagerank(String.t(), keyword()) :: String.t()
  def graph_pagerank(edge_table, opts \\ []) do
    "GRAPH PAGERANK #{edge_table}"
    |> maybe_append_number("DAMPING", Keyword.get(opts, :damping))
    |> maybe_append_int("MAX_ITER", Keyword.get(opts, :max_iter))
    |> maybe_append_limit(Keyword.get(opts, :limit))
  end

  @doc """
  Builds a `GRAPH CENTRALITY <edge_table>` statement: degree centrality over
  the edge table, returning `{id, score}` rows ranked by score descending.

  ## Options

    * `:mode` - `:degree` (default, in + out), `:indegree`, or `:outdegree`
    * `:limit` - return only the top-N nodes

  ## Examples

      iex> Dllb.Query.graph_centrality("calls")
      "GRAPH CENTRALITY calls"

      iex> Dllb.Query.graph_centrality("calls", mode: :indegree, limit: 10)
      "GRAPH CENTRALITY calls INDEGREE LIMIT 10"

  """
  @spec graph_centrality(String.t(), keyword()) :: String.t()
  def graph_centrality(edge_table, opts \\ []) do
    "GRAPH CENTRALITY #{edge_table}"
    |> maybe_append_centrality_mode(Keyword.get(opts, :mode))
    |> maybe_append_limit(Keyword.get(opts, :limit))
  end

  @doc """
  Builds a `GRAPH PATH <src> -> <dst> ON <edge_table>` statement: the shortest
  directed path between two vertices. `src` and `dst` are bare vertex ids (the
  id part, not `table:id`). The result is a single row with `found`, `length`,
  and `path` fields.

  ## Options

    * `:max_depth` - bound the search to at most this many edges

  ## Examples

      iex> Dllb.Query.graph_path("a", "b", "calls")
      "GRAPH PATH a -> b ON calls"

      iex> Dllb.Query.graph_path("a", "b", "calls", max_depth: 4)
      "GRAPH PATH a -> b ON calls MAX_DEPTH 4"

  """
  @spec graph_path(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def graph_path(src, dst, edge_table, opts \\ []) do
    "GRAPH PATH #{src} -> #{dst} ON #{edge_table}"
    |> maybe_append_int("MAX_DEPTH", Keyword.get(opts, :max_depth))
  end

  @doc """
  Builds a `GRAPH EDGES <edge_table> [WHERE <clause>]` statement: lists the
  edges of an edge table as rows of `{src, dst, edge_type, weight, ...props}`,
  surfacing the real stored `weight` (default `1.0`). The optional WHERE
  filters the synthetic edge rows (e.g. by `src`, `dst`, or `weight`).

  ## Options

    * `:where` - optional WHERE clause string

  ## Examples

      iex> Dllb.Query.graph_edges("calls")
      "GRAPH EDGES calls"

      iex> Dllb.Query.graph_edges("calls", where: "weight > 0.5")
      "GRAPH EDGES calls WHERE weight > 0.5"

  """
  @spec graph_edges(String.t(), keyword()) :: String.t()
  def graph_edges(edge_table, opts \\ []) do
    maybe_append("GRAPH EDGES #{edge_table}", "WHERE", Keyword.get(opts, :where))
  end

  @doc """
  Passes through a raw query string without modification.

  ## Examples

      iex> Dllb.Query.raw("INFO FOR DB")
      "INFO FOR DB"

  """
  @spec raw(String.t()) :: String.t()
  def raw(query_string) when is_binary(query_string), do: query_string

  # --- Private helpers ---

  defp set_clause(fields) when map_size(fields) == 0, do: ""

  defp set_clause(fields) do
    fields
    |> Enum.sort_by(fn {k, _v} -> Atom.to_string(k) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k} = #{escape_value(v)}" end)
  end

  defp escape_value(nil), do: "NONE"
  defp escape_value(true), do: "true"
  defp escape_value(false), do: "false"
  defp escape_value(v) when is_integer(v), do: Integer.to_string(v)
  defp escape_value(v) when is_float(v), do: Float.to_string(v)

  defp escape_value(v) when is_binary(v) do
    escaped =
      v
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "''")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "'#{escaped}'"
  end

  defp escape_value(v) when is_atom(v), do: escape_value(Atom.to_string(v))

  defp escape_value(v) when is_list(v) do
    inner = Enum.map_join(v, ", ", &escape_value/1)
    "[#{inner}]"
  end

  defp escape_value(%mod{} = v) do
    vs =
      cond do
        function_exported?(mod, :to_iso8601, 1) -> mod.to_iso8601(v)
        String.Chars.impl_for(v) -> to_string(v)
        function_exported?(mod, :to_string, 1) -> mod.to_string(v)
        true -> inspect(v)
      end

    escape_value(vs)
  end

  defp escape_value(v) when is_map(v) do
    inner =
      v
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(", ", fn {k, val} -> "#{k}: #{escape_value(val)}" end)

    "{#{inner}}"
  end

  defp escape_value(v) when is_tuple(v), do: escape_value(inspect(v))

  defp maybe_append(query, _keyword, nil), do: query
  defp maybe_append(query, _keyword, ""), do: query
  defp maybe_append(query, keyword, value), do: "#{query} #{keyword} #{value}"

  defp maybe_append_limit(query, nil), do: query
  defp maybe_append_limit(query, limit) when is_integer(limit), do: "#{query} LIMIT #{limit}"

  defp maybe_append_algorithm(query, nil), do: query
  defp maybe_append_algorithm(query, :louvain), do: "#{query} ALGORITHM louvain"
  defp maybe_append_algorithm(query, :lp), do: "#{query} ALGORITHM lp"

  defp maybe_append_algorithm(query, algo) when is_atom(algo),
    do: "#{query} ALGORITHM #{Atom.to_string(algo)}"

  defp maybe_append_int(query, _kw, nil), do: query
  defp maybe_append_int(query, kw, n) when is_integer(n) and n > 0, do: "#{query} #{kw} #{n}"
  defp maybe_append_int(query, _kw, _), do: query

  defp maybe_append_resolution(query, nil), do: query
  defp maybe_append_resolution(query, r) when is_float(r), do: "#{query} RESOLUTION #{r}"
  defp maybe_append_resolution(query, r) when is_integer(r), do: "#{query} RESOLUTION #{r}.0"

  # Appends `KW <number>` for float or integer values (e.g. DAMPING, ALPHA).
  defp maybe_append_number(query, _kw, nil), do: query
  defp maybe_append_number(query, kw, v) when is_number(v), do: "#{query} #{kw} #{v}"
  defp maybe_append_number(query, _kw, _), do: query

  defp maybe_append_centrality_mode(query, nil), do: query
  defp maybe_append_centrality_mode(query, :degree), do: "#{query} DEGREE"
  defp maybe_append_centrality_mode(query, :indegree), do: "#{query} INDEGREE"
  defp maybe_append_centrality_mode(query, :outdegree), do: "#{query} OUTDEGREE"
end
