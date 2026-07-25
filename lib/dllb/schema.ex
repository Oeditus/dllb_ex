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
  Returns the list of query strings to define the `ast_node` table and its 18 fields.

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
    - `docstring_embedding` (array) - 768-dim docstring embedding
    - `ast_serialized` (string) - JSON-serialized AST subtree
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
      Query.define_field("ast_node", "structure_embedding", "array"),
      Query.define_field("ast_node", "docstring_embedding", "array"),
      Query.define_field("ast_node", "ast_serialized", "string")
    ]
  end

  @doc """
  Returns the list of query strings that define the secondary indexes on the
  `ast_node` table.

  These are persisted in the engine's index catalog and transparently
  accelerate equality and range predicates in `WHERE` clauses:

    - `idx_kind` on `kind`
    - `idx_language` on `language`
    - `idx_file_path` on `file_path`
    - `idx_module` on `module`
    - `idx_project_path` on `project_path`
    - `idx_file_kind` composite on `file_path, kind` (leftmost-prefix)

  Full-text (BM25) and vector (HNSW) search indexes over the embedding and
  text fields are defined separately by `ast_node_search_indexes/0`.
  """
  @spec ast_node_indexes() :: [String.t()]
  def ast_node_indexes do
    [
      Query.define_index("ast_node", "idx_kind", ["kind"]),
      Query.define_index("ast_node", "idx_language", ["language"]),
      Query.define_index("ast_node", "idx_file_path", ["file_path"]),
      Query.define_index("ast_node", "idx_module", ["module"]),
      Query.define_index("ast_node", "idx_project_path", ["project_path"]),
      Query.define_index("ast_node", "idx_file_kind", ["file_path", "kind"])
    ]
  end

  @doc """
  Returns the list of query strings that define the full-text and vector
  search indexes on the `ast_node` table.

  Created over the wire via the engine's `DEFINE FULLTEXT INDEX` /
  `DEFINE VECTOR INDEX` DDL. These require a dllb server with full-text/vector
  services enabled (the default server build):

    - `idx_source_text` - full-text (BM25) on `source_text`
    - `idx_docstring` - full-text (BM25) on `docstring`
    - `idx_source_embedding` - vector (HNSW) on `source_embedding`, 768-dim, cosine
    - `idx_structure_embedding` - vector (HNSW) on `structure_embedding`, 384-dim, cosine
  """
  @spec ast_node_search_indexes() :: [String.t()]
  def ast_node_search_indexes do
    [
      Query.define_fulltext_index("ast_node", "idx_source_text", "source_text"),
      Query.define_fulltext_index("ast_node", "idx_docstring", "docstring"),
      Query.define_vector_index("ast_node", "idx_source_embedding", "source_embedding", 768,
        metric: "cosine"
      ),
      Query.define_vector_index("ast_node", "idx_structure_embedding", "structure_embedding", 384,
        metric: "cosine"
      )
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
      Query.define_table("_edge_idx", :schemaless),
      Query.define_index("_edge_idx", "idx_edge_type", ["edge_type"]),
      Query.define_index("_edge_idx", "idx_from_id", ["from_id"]),
      Query.define_index("_edge_idx", "idx_to_id", ["to_id"])
    ]
  end

  @doc """
  Returns all schema statements (table, secondary index, full-text/vector
  search index, and edge-index definitions) in order.
  """
  @spec all_statements() :: [String.t()]
  def all_statements do
    ast_node_table() ++
      ast_node_indexes() ++ ast_node_search_indexes() ++ edge_idx_table()
  end
end
