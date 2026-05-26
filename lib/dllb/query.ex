defmodule Dllb.Query do
  @moduledoc """
  Query builder that generates dllb SQL strings.

  Provides functions to construct CREATE, SELECT, UPDATE, DELETE, RELATE,
  and DEFINE statements for the dllb query language. All functions return
  plain query strings ready to be sent over the wire.
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
  Builds a DELETE statement for a record.

  ## Examples

      iex> Dllb.Query.delete("user:u1")
      "DELETE user:u1"

  """
  @spec delete(String.t()) :: String.t()
  def delete(record_id) do
    "DELETE #{record_id}"
  end

  @doc """
  Builds a CREATE ... ON CONFLICT UPDATE statement for idempotent upserts.

  If the record already exists (by table + id), updates the fields instead
  of failing.

  ## Examples

      iex> Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30})
      "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE"

  """
  @spec upsert(String.t(), String.t(), fields()) :: String.t()
  def upsert(table, id, fields) when is_map(fields) do
    "CREATE #{table}:#{id} SET #{set_clause(fields)} ON CONFLICT UPDATE"
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
  Builds a DEFINE INDEX statement.

  Supported index types: `:btree`, `:fulltext`, `:hnsw`.

  ## Options (for HNSW vector indexes)

    * `:dimension` - vector dimension
    * `:dist` - distance metric (e.g. `"COSINE"`, `"EUCLIDEAN"`)

  ## Examples

      iex> Dllb.Query.define_index("user", "idx_name", ["name"], :btree)
      "DEFINE INDEX idx_name ON user FIELDS name SEARCH ANALYZER btree"

      iex> Dllb.Query.define_index("ast_node", "idx_src_embed", ["source_embedding"], :hnsw, dimension: 768, dist: "COSINE")
      "DEFINE INDEX idx_src_embed ON ast_node FIELDS source_embedding HNSW DIMENSION 768 DIST COSINE"

  """
  @spec define_index(String.t(), String.t(), [String.t()], atom(), keyword()) :: String.t()
  def define_index(table, name, fields, index_type, opts \\ [])

  def define_index(table, name, fields, :btree, _opts) do
    "DEFINE INDEX #{name} ON #{table} FIELDS #{Enum.join(fields, ", ")} SEARCH ANALYZER btree"
  end

  def define_index(table, name, fields, :fulltext, _opts) do
    "DEFINE INDEX #{name} ON #{table} FIELDS #{Enum.join(fields, ", ")} SEARCH ANALYZER fulltext"
  end

  def define_index(table, name, fields, :hnsw, opts) do
    dimension = Keyword.fetch!(opts, :dimension)
    dist = Keyword.fetch!(opts, :dist)

    "DEFINE INDEX #{name} ON #{table} FIELDS #{Enum.join(fields, ", ")} HNSW DIMENSION #{dimension} DIST #{dist}"
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
end
