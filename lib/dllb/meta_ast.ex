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
  @type context :: %{
          required(:language) => atom(),
          required(:file_path) => String.t(),
          optional(:module) => String.t() | nil,
          optional(:project_path) => String.t() | nil
        }
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
  def to_dllb_document({type_atom, meta, children_or_value}, context) do
    params = Keyword.get(meta, :params, [])
    raw_name = Keyword.get(meta, :name)

    # Compute arity for both function_def (from params) and function_call (from args).
    arity =
      cond do
        type_atom == :function_def ->
          length(params)

        type_atom == :function_call and is_list(children_or_value) ->
          length(children_or_value)

        true ->
          nil
      end

    # For function_call, the name may be qualified ("Module.func").
    # Extract the callee module so every function node has a proper module field.
    # For local (unqualified) calls, fall back to the enclosing module from context.
    {module, name} =
      if type_atom == :function_call and is_binary(raw_name) do
        split_qualified_name(raw_name, context[:module])
      else
        {context[:module], raw_name}
      end

    %{
      kind: NodeTypes.to_dllb_kind(type_atom),
      name: name,
      language: to_string(context.language),
      file_path: context.file_path,
      module: module,
      arity: arity,
      visibility: visibility_string(Keyword.get(meta, :visibility)),
      project_path: context[:project_path],
      line_start: Keyword.get(meta, :line),
      line_end: Keyword.get(meta, :end_line),
      source_text: Keyword.get(meta, :source_text),
      signature: Keyword.get(meta, :signature),
      docstring: Keyword.get(meta, :doc)
    }
    |> reject_nil_values()
  end

  # Splits a potentially qualified name like "GenServer.call" into {module, func}.
  # For unqualified names like "handle_response", returns {fallback_module, name}.
  defp split_qualified_name(name, fallback_module) do
    case String.split(name, ".") do
      parts when length(parts) >= 2 ->
        func = List.last(parts)
        mod = parts |> Enum.drop(-1) |> Enum.join(".")
        {mod, func}

      _ ->
        {fallback_module, name}
    end
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
    kind_raw = unwrap_typed(row["kind"] || "")

    kind =
      case NodeTypes.from_dllb_kind(kind_raw) do
        {:ok, atom} -> atom
        :error -> kind_raw
      end

    %{
      id: unwrap_typed(row["id"]),
      kind: kind,
      name: unwrap_typed(row["name"]),
      language: safe_to_atom(unwrap_typed(row["language"])),
      file_path: unwrap_typed(row["file_path"]),
      module: unwrap_typed(row["module"]),
      arity: unwrap_typed(row["arity"]),
      visibility: safe_to_atom(unwrap_typed(row["visibility"])),
      project_path: unwrap_typed(row["project_path"]),
      line_start: unwrap_typed(row["line_start"]),
      line_end: unwrap_typed(row["line_end"]),
      source_text: unwrap_typed(row["source_text"]),
      signature: unwrap_typed(row["signature"]),
      docstring: unwrap_typed(row["docstring"]),
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
    {documents, edges} = walk_tree(tree, context, {[], []}, 0)

    with {:ok, node_count} <- execute_creates(documents, context, query_fn),
         {:ok, edge_count} <- execute_relates(edges, query_fn) do
      {:ok, %{nodes: node_count, edges: edge_count}}
    end
  end

  @doc """
  Like `ingest_tree/3` but collects all queries and returns them as a list
  of strings suitable for `Dllb.batch/1`.

  This avoids N pool checkouts by letting the caller send all statements
  in a single batch.

  Returns `{create_queries, relate_queries}` where each is a list of query strings.
  """
  @spec ingest_tree_queries(meta_ast_node(), context()) :: {[String.t()], [String.t()]}
  def ingest_tree_queries(tree, context) do
    {documents, edges} = walk_tree(tree, context, {[], []}, 0)

    create_queries =
      documents
      |> Enum.reverse()
      |> Enum.map(fn {record_id, fields} ->
        Query.create_with_id("ast_node", bare_id(record_id), fields)
      end)

    reversed_edges = Enum.reverse(edges)

    relate_queries =
      Enum.map(reversed_edges, fn {from_id, edge_type, to_id, props} ->
        Query.relate(from_id, edge_type, to_id, props)
      end)

    # Also create queryable index documents for each edge so that
    # SELECT * FROM _edge_idx WHERE edge_type = 'calls' works.
    edge_idx_queries =
      reversed_edges
      |> Enum.with_index()
      |> Enum.map(fn {{from_id, edge_type, to_id, _props}, idx} ->
        edge_id = "#{bare_id(from_id)}_#{edge_type}_#{bare_id(to_id)}_#{idx}"
        fields = %{from_id: from_id, to_id: to_id, edge_type: edge_type}
        Query.create_with_id("_edge_idx", edge_id, fields)
      end)

    {create_queries, relate_queries ++ edge_idx_queries}
  end

  # --- Private functions ---

  @max_depth 50

  defp walk_tree(_node, _context, acc, depth) when depth > @max_depth, do: acc

  defp walk_tree({type_atom, meta, children}, context, {docs_acc, edges_acc}, depth)
       when is_atom(type_atom) and is_list(children) do
    child_context =
      if type_atom == :container do
        Map.put(context, :module, Keyword.get(meta, :name))
      else
        context
      end

    doc = to_dllb_document({type_atom, meta, children}, context)
    current_id = node_id(type_atom, meta, context)

    docs_acc = [{current_id, doc} | docs_acc]

    {docs_acc, edges_acc} =
      Enum.reduce(children, {docs_acc, edges_acc}, fn child, {d_acc, e_acc} ->
        walk_child(child, type_atom, current_id, child_context, {d_acc, e_acc}, depth + 1)
      end)

    {docs_acc, edges_acc}
  end

  # Tuple-typed node (e.g. dynamic call where type is itself a 3-tuple).
  # Promote the original children directly under :language_specific to avoid
  # re-inserting the tuple-typed node as a child (which would loop forever).
  defp walk_tree({type_tuple, meta, children}, context, acc, depth)
       when is_tuple(type_tuple) do
    flat_children = if is_list(children), do: children, else: []
    walk_tree({:language_specific, meta, flat_children}, context, acc, depth)
  end

  defp walk_tree({type_atom, meta, value}, context, {docs_acc, edges_acc}, _depth)
       when is_atom(type_atom) do
    doc = to_dllb_document({type_atom, meta, value}, context)
    current_id = node_id(type_atom, meta, context)
    {[{current_id, doc} | docs_acc], edges_acc}
  end

  # Non-3-tuple values that appear in children lists -- skip
  defp walk_tree(_other, _context, acc, _depth), do: acc

  defp walk_child(
         {child_type, child_meta, _} = child,
         parent_type,
         parent_id,
         context,
         {d_acc, e_acc},
         depth
       )
       when is_atom(child_type) do
    child_id = node_id(child_type, child_meta, context)
    e_acc = maybe_add_edge(parent_type, parent_id, child_type, child_id, child_meta, e_acc)
    walk_tree(child, context, {d_acc, e_acc}, depth)
  end

  # Tuple-typed child node (dynamic/remote call producing non-atom type)
  defp walk_child(
         {type_tuple, _meta, _children} = child,
         _parent_type,
         _parent_id,
         context,
         {d_acc, e_acc},
         depth
       )
       when is_tuple(type_tuple) do
    walk_tree(child, context, {d_acc, e_acc}, depth)
  end

  # nil children (e.g. missing else branch) or other non-AST values -- skip
  defp walk_child(_child, _parent_type, _parent_id, _context, acc, _depth), do: acc

  defp node_id(type_atom, meta, context) when is_atom(type_atom) do
    name = Keyword.get(meta, :name, Atom.to_string(type_atom))
    line = Keyword.get(meta, :line, 0)

    sanitized_name =
      name
      |> safe_to_string()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    file_stem =
      context.file_path
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    "ast_node:#{file_stem}_#{sanitized_name}_#{line}"
  end

  defp bare_id("ast_node:" <> id), do: id
  defp bare_id(id), do: id

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
       when is_atom(type_atom) and is_list(children) do
    current_id = node_id(type_atom, meta, context)

    acc =
      if parent_id do
        maybe_add_collected_edge(parent_id, type_atom, current_id, meta, acc)
      else
        acc
      end

    Enum.reduce(children, acc, fn
      {child_type, _, _} = child, inner_acc when is_atom(child_type) ->
        collect_edges(child, current_id, context, inner_acc)

      _non_ast_child, inner_acc ->
        inner_acc
    end)
  end

  defp collect_edges({type_atom, meta, _value}, parent_id, context, acc)
       when is_atom(type_atom) do
    current_id = node_id(type_atom, meta, context)

    if parent_id do
      maybe_add_collected_edge(parent_id, type_atom, current_id, meta, acc)
    else
      acc
    end
  end

  # Non-standard nodes (tuple-typed, nil, etc.) -- skip
  defp collect_edges(_other, _parent_id, _context, acc), do: acc

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
      query = Query.create_with_id("ast_node", bare_id(record_id), fields)

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

  # dllb JSON wraps typed values: %{"String" => "value"}, %{"Int" => 42}, etc.
  defp unwrap_typed(%{"String" => v}), do: v
  defp unwrap_typed(%{"Int" => v}), do: v
  defp unwrap_typed(%{"Float" => v}), do: v
  defp unwrap_typed(%{"Bool" => v}), do: v
  defp unwrap_typed(v), do: v
  defp safe_to_string(v) when is_binary(v), do: v
  defp safe_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_to_string(v) when is_number(v), do: to_string(v)
  defp safe_to_string(v), do: inspect(v)

  defp visibility_string(:public), do: "public"
  defp visibility_string(:private), do: "private"
  defp visibility_string(_), do: nil
end
