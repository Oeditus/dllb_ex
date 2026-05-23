defmodule Dllb.MetaAST do
  @moduledoc """
  Serialization bridge between Metastatic's Elixir 3-tuple format
  and dllb document/edge storage.

  Metastatic AST nodes are represented as `{type_atom, keyword_meta, children_or_value}`.
  This module converts them into maps suitable for `Dllb.Query` operations and
  handles bulk ingestion of full AST trees into the database.
  """

  alias Dllb.MetaAST.NodeTypes
  alias Dllb.Query

  @type meta_ast_node :: {atom(), keyword(), list() | term()}
  @type context :: %{language: atom(), file_path: String.t()}
  @type query_fn :: (String.t() -> {:ok, any()} | {:error, any()})
  @type edge :: {String.t(), String.t(), String.t(), map()}

  @doc """
  Converts a single Metastatic AST node into a map of fields suitable
  for `Dllb.Query.create/2`.

  Extracts metadata from the keyword list: `:name`, `:line`, `:end_line`,
  `:source_text`, `:signature`, `:doc`. The `kind` and contextual fields
  (`language`, `file_path`) are derived from the type atom and context map.

  ## Examples

      iex> node = {:function_def, [name: "parse", line: 10, end_line: 25], []}
      iex> ctx = %{language: :elixir, file_path: "/app/lib/parser.ex"}
      iex> doc = Dllb.MetaAST.to_dllb_document(node, ctx)
      iex> doc.kind
      "function_def"
      iex> doc.name
      "parse"

  """
  @spec to_dllb_document(meta_ast_node(), context()) :: map()
  def to_dllb_document({type_atom, meta, _children_or_value}, context) do
    %{
      kind: NodeTypes.to_dllb_kind(type_atom),
      name: Keyword.get(meta, :name),
      language: to_string(context.language),
      file_path: context.file_path,
      line_start: Keyword.get(meta, :line),
      line_end: Keyword.get(meta, :end_line),
      source_text: Keyword.get(meta, :source_text),
      signature: Keyword.get(meta, :signature),
      docstring: Keyword.get(meta, :doc)
    }
    |> reject_nil_values()
  end

  @doc """
  Walks a full MetaAST tree and extracts structural relationship edges.

  Returns a list of `{from_id, edge_type, to_id, properties}` tuples.

  Edge types extracted:
    - `"contains"` - container -> function_def relationships
    - `"calls"` - function_call edges (caller -> callee)
    - `"imports"` - import edges
  """
  @spec to_dllb_edges(meta_ast_node(), context()) :: [edge()]
  def to_dllb_edges(tree, context) do
    tree
    |> collect_edges(nil, context, [])
    |> Enum.reverse()
  end

  @doc """
  Returns an UPDATE query string to set embedding fields on an existing record.

  ## Examples

      iex> embeddings = %{source_embedding: [0.1, 0.2, 0.3]}
      iex> query = Dllb.MetaAST.to_dllb_embeddings("ast_node:MyMod_parse_2", embeddings)
      iex> String.starts_with?(query, "UPDATE ast_node:MyMod_parse_2 SET")
      true

  """
  @spec to_dllb_embeddings(String.t(), map()) :: String.t()
  def to_dllb_embeddings(record_id, embeddings_map) when is_map(embeddings_map) do
    Query.update(record_id, embeddings_map)
  end

  @doc """
  Converts a dllb result row (string-keyed map from JSON) into a
  ragex-compatible map with atom keys and proper types.

  The `kind` field is converted back to an atom via `NodeTypes.from_dllb_kind/1`.
  Unknown kinds are kept as the original string in the `:kind` field.
  """
  @spec from_dllb_row(map()) :: map()
  def from_dllb_row(row) when is_map(row) do
    kind =
      case NodeTypes.from_dllb_kind(row["kind"] || "") do
        {:ok, atom} -> atom
        :error -> row["kind"]
      end

    %{
      id: row["id"],
      kind: kind,
      name: row["name"],
      language: safe_to_atom(row["language"]),
      file_path: row["file_path"],
      line_start: row["line_start"],
      line_end: row["line_end"],
      source_text: row["source_text"],
      signature: row["signature"],
      docstring: row["docstring"],
      source_embedding: row["source_embedding"],
      structure_embedding: row["structure_embedding"]
    }
    |> reject_nil_values()
  end

  @doc """
  Walks a MetaAST tree, generates CREATE statements for structural nodes
  and RELATE statements for edges, and executes them via `query_fn`.

  Returns `{:ok, %{nodes: count, edges: count}}` on success or
  `{:error, reason}` on the first failure.
  """
  @spec ingest_tree(meta_ast_node(), context(), query_fn()) ::
          {:ok, %{nodes: non_neg_integer(), edges: non_neg_integer()}} | {:error, any()}
  def ingest_tree(tree, context, query_fn) when is_function(query_fn, 1) do
    {documents, edges} = walk_tree(tree, context, {[], []})

    with {:ok, node_count} <- execute_creates(documents, context, query_fn),
         {:ok, edge_count} <- execute_relates(edges, query_fn) do
      {:ok, %{nodes: node_count, edges: edge_count}}
    end
  end

  # --- Private functions ---

  defp walk_tree({type_atom, meta, children}, context, {docs_acc, edges_acc})
       when is_list(children) do
    doc = to_dllb_document({type_atom, meta, children}, context)
    current_id = node_id(type_atom, meta, context)

    docs_acc = [{current_id, doc} | docs_acc]

    {docs_acc, edges_acc} =
      Enum.reduce(children, {docs_acc, edges_acc}, fn child, {d_acc, e_acc} ->
        {child_type, child_meta, _} = child
        child_id = node_id(child_type, child_meta, context)

        e_acc = maybe_add_edge(type_atom, current_id, child_type, child_id, child_meta, e_acc)

        walk_tree(child, context, {d_acc, e_acc})
      end)

    {docs_acc, edges_acc}
  end

  defp walk_tree({type_atom, meta, value}, context, {docs_acc, edges_acc}) do
    doc = to_dllb_document({type_atom, meta, value}, context)
    current_id = node_id(type_atom, meta, context)
    {[{current_id, doc} | docs_acc], edges_acc}
  end

  defp node_id(type_atom, meta, context) do
    name = Keyword.get(meta, :name, Atom.to_string(type_atom))
    line = Keyword.get(meta, :line, 0)

    sanitized_name =
      name
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    file_stem =
      context.file_path
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    "ast_node:#{file_stem}_#{sanitized_name}_#{line}"
  end

  defp maybe_add_edge(:container, parent_id, :function_def, child_id, _child_meta, edges) do
    [{parent_id, "contains", child_id, %{}} | edges]
  end

  defp maybe_add_edge(_parent_type, parent_id, :function_call, child_id, child_meta, edges) do
    callee = Keyword.get(child_meta, :name, "unknown")
    [{parent_id, "calls", child_id, %{callee: callee}} | edges]
  end

  defp maybe_add_edge(_parent_type, parent_id, :import, child_id, child_meta, edges) do
    module = Keyword.get(child_meta, :name, "unknown")
    [{parent_id, "imports", child_id, %{module: module}} | edges]
  end

  defp maybe_add_edge(_parent_type, _parent_id, _child_type, _child_id, _child_meta, edges) do
    edges
  end

  defp collect_edges({type_atom, meta, children}, parent_id, context, acc)
       when is_list(children) do
    current_id = node_id(type_atom, meta, context)

    acc =
      if parent_id do
        maybe_add_collected_edge(parent_id, type_atom, current_id, meta, acc)
      else
        acc
      end

    Enum.reduce(children, acc, fn child, inner_acc ->
      collect_edges(child, current_id, context, inner_acc)
    end)
  end

  defp collect_edges({type_atom, meta, _value}, parent_id, context, acc) do
    current_id = node_id(type_atom, meta, context)

    if parent_id do
      maybe_add_collected_edge(parent_id, type_atom, current_id, meta, acc)
    else
      acc
    end
  end

  defp maybe_add_collected_edge(parent_id, :function_def, child_id, _meta, acc) do
    [{parent_id, "contains", child_id, %{}} | acc]
  end

  defp maybe_add_collected_edge(parent_id, :function_call, child_id, meta, acc) do
    callee = Keyword.get(meta, :name, "unknown")
    [{parent_id, "calls", child_id, %{callee: callee}} | acc]
  end

  defp maybe_add_collected_edge(parent_id, :import, child_id, meta, acc) do
    module = Keyword.get(meta, :name, "unknown")
    [{parent_id, "imports", child_id, %{module: module}} | acc]
  end

  defp maybe_add_collected_edge(_parent_id, _type, _child_id, _meta, acc), do: acc

  defp execute_creates(documents, _context, query_fn) do
    documents
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, 0}, fn {record_id, fields}, {:ok, count} ->
      query = Query.create_with_id("ast_node", record_id, fields)

      case query_fn.(query) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_relates(edges, query_fn) do
    edges
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, 0}, fn {from_id, edge_type, to_id, props}, {:ok, count} ->
      query = Query.relate(from_id, edge_type, to_id, props)

      case query_fn.(query) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(str) when is_binary(str), do: String.to_atom(str)
end
