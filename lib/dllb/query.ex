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
  Builds a `COUNT <table> [WHERE <clause>]` statement.

  ## Options

    * `:where` - optional WHERE clause string

  ## Examples

      iex> Dllb.Query.count("user")
      "COUNT user"

      iex> Dllb.Query.count("user", where: "age = 30")
      "COUNT user WHERE age = 30"

  """
  @spec count(String.t(), keyword()) :: String.t()
  def count(table, opts \\ []) do
    base = "COUNT #{table}"

    case Keyword.get(opts, :where) do
      nil -> base
      "" -> base
      where -> "#{base} WHERE #{where}"
    end
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
