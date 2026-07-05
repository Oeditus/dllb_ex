defmodule Dllb.MetaAST.Ingest do
  @moduledoc """
  Enhanced batch ingestion pipeline for loading MetaAST data into dllb.

  Bridges MetaAST analysis output to dllb's storage layer by producing
  batches of document and edge operations ready for bulk insertion.
  Supports incremental re-indexing via `Dllb.MetaAST.Diff`.

  Mirrors the Rust `dllb-code-intel::ingest` module with the same
  deterministic ID scheme, enabling cross-language ID compatibility.

  ## Usage

      # Full ingest
      batch = Dllb.MetaAST.Ingest.prepare_batch(tree, "lib/app.ex", "elixir")
      queries = Dllb.MetaAST.Ingest.to_queries(batch)
      Dllb.batch_transaction(queries)

      # Incremental ingest (only changed entities)
      diff = Dllb.MetaAST.Diff.diff_trees(old_tree, new_tree)
      queries = Dllb.MetaAST.Ingest.incremental_queries(new_tree, diff, "lib/app.ex", "elixir")
      Dllb.batch_transaction(queries)
  """

  alias Dllb.MetaAST.Diff

  defstruct [
    :file_path,
    :language,
    documents: [],
    edges: [],
    stats: %{containers: 0, functions: 0, imports: 0, calls: 0, edges: 0}
  ]

  @type t :: %__MODULE__{
          file_path: String.t(),
          language: String.t(),
          documents: [map()],
          edges: [map()],
          stats: map()
        }

  @doc """
  Walk the MetaAST tree and produce a batch of dllb operations.

  Produces:
  - A document for each Container and FunctionDef node
  - Containment edges: container -> contains -> function
  - Import edges: container -> imports -> (stable ID)
  - Call edges: function -> calls -> (stable ID)
  """
  @spec prepare_batch(tuple(), String.t(), String.t()) :: t()
  def prepare_batch(root, file_path, language) do
    state = %{
      documents: [],
      edges: [],
      stats: %{containers: 0, functions: 0, imports: 0, calls: 0, edges: 0}
    }

    state = walk_for_batch(root, nil, file_path, language, state)

    %__MODULE__{
      file_path: file_path,
      language: language,
      documents: Enum.reverse(state.documents),
      edges: Enum.reverse(state.edges),
      stats: state.stats
    }
  end

  @doc """
  Convert a batch into dllb query strings wrapped in BEGIN/END BATCH.
  """
  @spec to_queries(t()) :: [String.t()]
  def to_queries(%__MODULE__{} = batch) do
    creates =
      Enum.map(batch.documents, fn doc ->
        sets = build_set_clause(doc)
        "CREATE ast_node:#{escape_id(doc.id)} SET #{sets}"
      end)

    relates =
      Enum.map(batch.edges, fn edge ->
        "RELATE ast_node:#{escape_id(edge.from_id)} -> #{edge.edge_type} -> ast_node:#{escape_id(edge.to_id)}"
      end)

    ["BEGIN BATCH"] ++ creates ++ relates ++ ["END BATCH"]
  end

  @doc """
  Merge multiple file batches into a single large batch for bulk loading.
  """
  @spec merge_batches([t()]) :: t()
  def merge_batches(batches) do
    Enum.reduce(batches, %__MODULE__{file_path: "", language: ""}, fn batch, acc ->
      %__MODULE__{
        file_path:
          case acc.file_path do
            "" -> batch.file_path
            _ -> "[#{length(batches)} files]"
          end,
        language: batch.language || acc.language,
        documents: acc.documents ++ batch.documents,
        edges: acc.edges ++ batch.edges,
        stats: merge_stats(acc.stats, batch.stats)
      }
    end)
  end

  @doc """
  Generate queries for incremental re-indexing based on a diff.

  Only produces operations for changed entities:
  - DELETE + CREATE for modified/added entities
  - DELETE for removed entities
  """
  @spec incremental_queries(tuple(), Diff.diff_summary(), String.t(), String.t()) :: [String.t()]
  def incremental_queries(new_tree, diff, file_path, language) do
    removed = Diff.removed_entities(diff)
    stale = Diff.stale_entities(diff)

    delete_queries =
      (removed ++ stale)
      |> Enum.flat_map(fn entity_key ->
        case parse_entity_key(entity_key) do
          {:fn, name, arity} ->
            id = function_id(file_path, name, arity)
            ["DELETE ast_node:#{escape_id(id)}"]

          {:container, name} ->
            id = container_id(file_path, "container", name)
            ["DELETE ast_node:#{escape_id(id)}"]

          {:import, source} ->
            ["DELETE ast_node:#{escape_id("import::#{source}")}"]

          _ ->
            []
        end
      end)

    # Re-create stale entities from the new tree
    batch = prepare_batch(new_tree, file_path, language)

    create_queries =
      batch.documents
      |> Enum.filter(fn doc ->
        Enum.any?(stale, fn key -> entity_matches_doc?(key, doc) end)
      end)
      |> Enum.map(fn doc ->
        sets = build_set_clause(doc)
        "CREATE ast_node:#{escape_id(doc.id)} SET #{sets}"
      end)

    relate_queries =
      batch.edges
      |> Enum.filter(fn edge ->
        Enum.any?(stale, fn key -> entity_matches_edge?(key, edge) end)
      end)
      |> Enum.map(fn edge ->
        "RELATE ast_node:#{escape_id(edge.from_id)} -> #{edge.edge_type} -> ast_node:#{escape_id(edge.to_id)}"
      end)

    if delete_queries == [] and create_queries == [] do
      []
    else
      ["BEGIN BATCH"] ++ delete_queries ++ create_queries ++ relate_queries ++ ["END BATCH"]
    end
  end

  # -- Private ----------------------------------------------------------------

  defp walk_for_batch({:container, meta, children}, _parent_id, file_path, language, state)
       when is_list(children) do
    name = Keyword.get(meta, :name, "anonymous")
    kind = to_string(Keyword.get(meta, :container_type, :container))
    cid = container_id(file_path, kind, name)

    doc = %{
      id: cid,
      name: name,
      kind: kind,
      language: language,
      file_path: file_path,
      line_start: Keyword.get(meta, :line),
      source_text: Keyword.get(meta, :source_text),
      docstring: Keyword.get(meta, :doc)
    }

    state = %{state | documents: [doc | state.documents]}
    state = deep_update(state, [:stats, :containers], &(&1 + 1))

    # Process children
    Enum.reduce(children, state, fn child, acc ->
      walk_for_batch(child, cid, file_path, language, acc)
    end)
  end

  defp walk_for_batch({:function_def, meta, children}, parent_id, file_path, language, state)
       when is_list(children) do
    name = to_string(Keyword.get(meta, :name, "anonymous"))
    params = Keyword.get(meta, :params, [])
    arity = length(params)
    fid = function_id(file_path, name, arity)
    visibility = Keyword.get(meta, :visibility, :public)

    param_names =
      Enum.map(params, fn
        {_, m, _} -> to_string(Keyword.get(m, :name, "?"))
        other -> to_string(other)
      end)

    doc = %{
      id: fid,
      name: name,
      kind: "function_def",
      language: language,
      file_path: file_path,
      line_start: Keyword.get(meta, :line),
      signature: "#{name}(#{Enum.join(param_names, ", ")}) [#{visibility}]"
    }

    state = %{state | documents: [doc | state.documents]}
    state = deep_update(state, [:stats, :functions], &(&1 + 1))

    # Containment edge
    state =
      if parent_id do
        edge = %{from_id: parent_id, edge_type: "contains", to_id: fid}
        state = %{state | edges: [edge | state.edges]}
        state = deep_update(state, [:stats, :edges], &(&1 + 1))
        state
      else
        state
      end

    # Extract calls from children
    calls = extract_call_names(children)

    state =
      Enum.reduce(calls, state, fn call_name, acc ->
        tid = "call_target::#{call_name}"
        edge = %{from_id: fid, edge_type: "calls", to_id: tid}
        acc = %{acc | edges: [edge | acc.edges]}
        acc = deep_update(acc, [:stats, :calls], &(&1 + 1))
        deep_update(acc, [:stats, :edges], &(&1 + 1))
      end)

    # Recurse into children for nested containers
    Enum.reduce(children, state, fn child, acc ->
      walk_for_batch(child, fid, file_path, language, acc)
    end)
  end

  defp walk_for_batch({:import, meta, _children}, parent_id, _file_path, _language, state) do
    source = to_string(Keyword.get(meta, :source) || Keyword.get(meta, :name, "unknown"))

    state =
      if parent_id do
        iid = "import::#{source}"
        edge = %{from_id: parent_id, edge_type: "imports", to_id: iid}
        state = %{state | edges: [edge | state.edges]}
        state = deep_update(state, [:stats, :imports], &(&1 + 1))
        deep_update(state, [:stats, :edges], &(&1 + 1))
      else
        state
      end

    state
  end

  defp walk_for_batch({_type, _meta, children}, parent_id, file_path, language, state)
       when is_list(children) do
    Enum.reduce(children, state, fn child, acc ->
      walk_for_batch(child, parent_id, file_path, language, acc)
    end)
  end

  defp walk_for_batch(_, _, _, _, state), do: state

  defp extract_call_names(children) when is_list(children) do
    Enum.flat_map(children, fn
      {:function_call, meta, inner_children} ->
        name = Keyword.get(meta, :name)
        rest = if is_list(inner_children), do: extract_call_names(inner_children), else: []
        if name, do: [to_string(name) | rest], else: rest

      {_type, _meta, inner_children} when is_list(inner_children) ->
        extract_call_names(inner_children)

      _ ->
        []
    end)
  end

  defp extract_call_names(_), do: []

  defp container_id(file_path, kind, name), do: "#{file_path}::#{kind}::#{name}"
  defp function_id(file_path, name, arity), do: "#{file_path}::#{name}/#{arity}"

  defp escape_id(id) do
    String.replace(id, "'", "''")
  end

  defp build_set_clause(doc) do
    doc
    |> Map.drop([:id])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k} = #{escape_value(v)}" end)
  end

  defp escape_value(v) when is_binary(v), do: "'#{String.replace(v, "'", "''")}'"
  defp escape_value(v) when is_integer(v), do: Integer.to_string(v)
  defp escape_value(v) when is_float(v), do: Float.to_string(v)
  defp escape_value(v) when is_atom(v), do: "'#{Atom.to_string(v)}'"
  defp escape_value(v), do: "'#{inspect(v)}'"

  # credo:disable-for-lines:9
  defp merge_stats(a, b) do
    %{
      containers: (a[:containers] || 0) + (b[:containers] || 0),
      functions: (a[:functions] || 0) + (b[:functions] || 0),
      imports: (a[:imports] || 0) + (b[:imports] || 0),
      calls: (a[:calls] || 0) + (b[:calls] || 0),
      edges: (a[:edges] || 0) + (b[:edges] || 0)
    }
  end

  defp parse_entity_key("fn::" <> rest) do
    case String.split(rest, "/") do
      [name, arity_str] ->
        case Integer.parse(arity_str) do
          {arity, ""} -> {:fn, name, arity}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_entity_key("container::" <> name), do: {:container, name}
  defp parse_entity_key("import::" <> source), do: {:import, source}
  defp parse_entity_key(_), do: nil

  defp entity_matches_doc?(key, doc) do
    case parse_entity_key(key) do
      {:fn, name, arity} ->
        doc.kind == "function_def" and doc.name == name and
          String.contains?(doc.id, "#{name}/#{arity}")

      {:container, name} ->
        doc.kind != "function_def" and doc.name == name

      _ ->
        false
    end
  end

  defp entity_matches_edge?(key, edge) do
    case parse_entity_key(key) do
      {:fn, name, arity} ->
        String.contains?(edge.from_id, "#{name}/#{arity}") or
          String.contains?(edge.to_id, "#{name}/#{arity}")

      {:container, name} ->
        String.contains?(edge.from_id, name) or String.contains?(edge.to_id, name)

      _ ->
        false
    end
  end

  defp deep_update(value, [], fun), do: fun.(value)

  defp deep_update(map, [key | rest], fun) when is_map(map) do
    value = Map.get(map, key)
    Map.put(map, key, deep_update(value, rest, fun))
  end
end
