defmodule Dllb.Schema do
  @moduledoc """
  Bootstraps the dllb database schema for code intelligence use.

  Provides functions that generate all DEFINE TABLE, DEFINE FIELD, and
  DEFINE INDEX statements needed for the ast_node table and its indexes.
  The `bootstrap/1` function accepts a query execution function, decoupling
  schema definition from the connection pool.
  """

  alias Dllb.Query

  @doc """
  Executes all schema DEFINE statements through the given query function.

  The `query_fn` must have the signature `(String.t() -> {:ok, any()} | {:error, any()})`.
  Returns `{:ok, :bootstrapped}` on success or `{:error, reason}` on the first failure.

  ## Examples

      iex> Dllb.Schema.bootstrap(fn query -> send(self(), {:query, query}); {:ok, %{}} end)
      {:ok, :bootstrapped}

  """
  @spec bootstrap((String.t() -> {:ok, any()} | {:error, any()})) ::
          {:ok, :bootstrapped} | {:error, any()}
  def bootstrap(query_fn) when is_function(query_fn, 1) do
    all_statements()
    |> Enum.reduce_while(:ok, fn stmt, :ok ->
      case query_fn.(stmt) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, :bootstrapped}
      error -> error
    end
  end

  @doc """
  Returns the list of query strings to define the `ast_node` table and its 15 fields.

  Fields:
    - `kind` (string, required) - the Metastatic node type
    - `name` (string) - symbol/identifier name
    - `language` (string, required) - source language
    - `file_path` (string, required) - absolute file path
    - `module` (string) - parent module/container name
    - `arity` (int) - function arity (for function_def nodes)
    - `visibility` (string) - "public" or "private"
    - `project_path` (string) - project root path (multi-project support)
    - `line_start` (int) - starting line number
    - `line_end` (int) - ending line number
    - `source_text` (string) - raw source text
    - `signature` (string) - function/method signature
    - `docstring` (string) - documentation string
    - `source_embedding` (array) - 768-dim source code embedding
    - `structure_embedding` (array) - 384-dim structural embedding
  """
  @spec ast_node_table() :: [String.t()]
  def ast_node_table do
    [
      Query.define_table("ast_node", :schemafull),
      Query.define_field("ast_node", "kind", "string", required: true),
      Query.define_field("ast_node", "name", "string"),
      Query.define_field("ast_node", "language", "string", required: true),
      Query.define_field("ast_node", "file_path", "string", required: true),
      Query.define_field("ast_node", "module", "string"),
      Query.define_field("ast_node", "arity", "int"),
      Query.define_field("ast_node", "visibility", "string"),
      Query.define_field("ast_node", "project_path", "string"),
      Query.define_field("ast_node", "line_start", "int"),
      Query.define_field("ast_node", "line_end", "int"),
      Query.define_field("ast_node", "source_text", "string"),
      Query.define_field("ast_node", "signature", "string"),
      Query.define_field("ast_node", "docstring", "string"),
      Query.define_field("ast_node", "source_embedding", "array"),
      Query.define_field("ast_node", "structure_embedding", "array")
    ]
  end

  @doc """
  Returns the list of query strings to define all indexes on the `ast_node` table.

  Indexes:
    - `idx_kind` - btree on `kind`
    - `idx_language` - btree on `language`
    - `idx_file_path` - btree on `file_path`
    - `idx_module` - btree on `module`
    - `idx_project_path` - btree on `project_path`
    - `idx_file_kind` - btree on `file_path, kind` (composite)
    - `idx_source_embedding` - HNSW 768-dim COSINE on `source_embedding`
    - `idx_structure_embedding` - HNSW 384-dim COSINE on `structure_embedding`
    - `idx_source_text` - fulltext on `source_text`
    - `idx_docstring` - fulltext on `docstring`
  """
  @spec ast_node_indexes() :: [String.t()]
  def ast_node_indexes do
    [
      Query.define_index("ast_node", "idx_kind", ["kind"], :btree),
      Query.define_index("ast_node", "idx_language", ["language"], :btree),
      Query.define_index("ast_node", "idx_file_path", ["file_path"], :btree),
      Query.define_index("ast_node", "idx_module", ["module"], :btree),
      Query.define_index("ast_node", "idx_project_path", ["project_path"], :btree),
      Query.define_index("ast_node", "idx_file_kind", ["file_path", "kind"], :btree),
      Query.define_index("ast_node", "idx_source_embedding", ["source_embedding"], :hnsw,
        dimension: 768,
        dist: "COSINE"
      ),
      Query.define_index("ast_node", "idx_structure_embedding", ["structure_embedding"], :hnsw,
        dimension: 384,
        dist: "COSINE"
      ),
      Query.define_index("ast_node", "idx_source_text", ["source_text"], :fulltext),
      Query.define_index("ast_node", "idx_docstring", ["docstring"], :fulltext)
    ]
  end

  @doc """
  Returns the list of query strings to define the `_edge_idx` table.

  This schemaless table mirrors graph RELATE edges as queryable documents
  so that `SELECT * FROM _edge_idx WHERE edge_type = 'calls'` works.
  """
  @spec edge_idx_table() :: [String.t()]
  def edge_idx_table do
    [
      Query.define_table("_edge_idx", :schemaless)
    ]
  end

  @doc """
  Returns all schema statements (table definitions + index definitions) in order.
  """
  @spec all_statements() :: [String.t()]
  def all_statements do
    ast_node_table() ++ ast_node_indexes() ++ edge_idx_table()
  end
end
