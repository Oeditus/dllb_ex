defmodule Dllb.MetaAST.Diff do
  @moduledoc """
  AST-level diff between two versions of a MetaAST tree.

  Unlike text diffs (which report line changes), this module understands tree
  structure and reports semantic changes: added functions, removed imports,
  modified bodies, renamed containers.

  Primary use case: incremental re-indexing. When a file changes, only the
  entities that actually changed need re-embedding and re-insertion into dllb.

  ## Usage

      old_ast = Metastatic.parse!(old_source)
      new_ast = Metastatic.parse!(new_source)

      diff = Dllb.MetaAST.Diff.diff_trees(old_ast, new_ast)

      # Entities needing re-indexing
      diff.stale   # [{:function_def, "process/2"}, ...]

      # Entities to remove from index
      diff.removed # [{:function_def, "old_helper/1"}]
  """

  @type change_kind :: :added | :removed | :modified | :renamed

  @type ast_change :: %{
          kind: change_kind(),
          node_type: atom(),
          name: String.t(),
          line: non_neg_integer() | nil
        }

  @type diff_summary :: %{
          changes: [ast_change()],
          added: non_neg_integer(),
          removed: non_neg_integer(),
          modified: non_neg_integer(),
          renamed: non_neg_integer()
        }

  @doc """
  Compare two MetaAST trees and produce a summary of structural changes.

  Comparison is done at the "named entity" level — functions, containers,
  imports — matching the granularity at which dllb stores AST documents.
  """
  @spec diff_trees(tuple(), tuple()) :: diff_summary()
  def diff_trees(old_tree, new_tree) do
    old_entities = collect_named_entities(old_tree)
    new_entities = collect_named_entities(new_tree)

    {changes, rename_targets} = find_removals_and_modifications(old_entities, new_entities)
    additions = find_additions(old_entities, new_entities, rename_targets)

    all_changes = changes ++ additions

    %{
      changes: all_changes,
      added: Enum.count(all_changes, &(&1.kind == :added)),
      removed: Enum.count(all_changes, &(&1.kind == :removed)),
      modified: Enum.count(all_changes, &(&1.kind == :modified)),
      renamed: Enum.count(all_changes, &(&1.kind == :renamed))
    }
  end

  @doc """
  Returns names of entities that need re-indexing (added + modified + renamed).
  """
  @spec stale_entities(diff_summary()) :: [String.t()]
  def stale_entities(%{changes: changes}) do
    changes
    |> Enum.filter(&(&1.kind in [:added, :modified, :renamed]))
    |> Enum.map(& &1.name)
  end

  @doc """
  Returns names of entities that should be removed from the index.
  """
  @spec removed_entities(diff_summary()) :: [String.t()]
  def removed_entities(%{changes: changes}) do
    changes
    |> Enum.filter(&(&1.kind == :removed))
    |> Enum.map(& &1.name)
  end

  @doc """
  Returns true if the diff contains no changes.
  """
  @spec empty?(diff_summary()) :: boolean()
  def empty?(%{changes: []}), do: true
  def empty?(_), do: false

  # -- Private ----------------------------------------------------------------

  # credo:disable-for-lines:42
  defp find_removals_and_modifications(old_entities, new_entities) do
    Enum.reduce(old_entities, {[], []}, fn old_ent, {changes, rename_targets} ->
      case Enum.find(new_entities, &(&1.key == old_ent.key)) do
        nil ->
          case find_rename(old_ent, new_entities, old_entities) do
            {:renamed, new_key} ->
              change = %{
                kind: :renamed,
                node_type: old_ent.node_type,
                name: "#{old_ent.key} -> #{new_key}",
                line: nil
              }

              {[change | changes], [new_key | rename_targets]}

            nil ->
              change = %{
                kind: :removed,
                node_type: old_ent.node_type,
                name: old_ent.key,
                line: nil
              }

              {[change | changes], rename_targets}
          end

        new_ent ->
          if children_equal?(old_ent.node, new_ent.node) do
            {changes, rename_targets}
          else
            change = %{
              kind: :modified,
              node_type: new_ent.node_type,
              name: new_ent.key,
              line: new_ent.line
            }

            {[change | changes], rename_targets}
          end
      end
    end)
  end

  defp find_additions(old_entities, new_entities, rename_targets) do
    old_keys = MapSet.new(old_entities, & &1.key)
    rename_set = MapSet.new(rename_targets)

    new_entities
    |> Enum.reject(&(MapSet.member?(old_keys, &1.key) or MapSet.member?(rename_set, &1.key)))
    |> Enum.map(fn ent ->
      %{kind: :added, node_type: ent.node_type, name: ent.key, line: ent.line}
    end)
  end

  defp find_rename(%{node_type: node_type, node: node}, new_entities, old_entities)
       when node_type in [:function_def, :container] do
    old_keys = MapSet.new(old_entities, & &1.key)

    Enum.find_value(new_entities, fn new_ent ->
      not MapSet.member?(old_keys, new_ent.key) and new_ent.node_type == node_type and
        children_equal?(node, new_ent.node) and {:renamed, new_ent.key}
    end)
  end

  defp find_rename(_, _, _), do: nil

  defp collect_named_entities(tree) do
    tree
    |> collect_recursive([])
    |> Enum.reverse()
  end

  defp collect_recursive({:function_def, meta, children}, acc) do
    name = Keyword.get(meta, :name)
    params = Keyword.get(meta, :params, [])
    arity = length(params)
    line = Keyword.get(meta, :line)

    acc =
      if name do
        entity = %{
          key: "fn::#{name}/#{arity}",
          node_type: :function_def,
          node: {:function_def, meta, children},
          line: line
        }

        [entity | acc]
      else
        acc
      end

    recurse_children(children, acc)
  end

  defp collect_recursive({:container, meta, children}, acc) do
    name = Keyword.get(meta, :name)
    line = Keyword.get(meta, :line)

    acc =
      if name do
        entity = %{
          key: "container::#{name}",
          node_type: :container,
          node: {:container, meta, children},
          line: line
        }

        [entity | acc]
      else
        acc
      end

    recurse_children(children, acc)
  end

  defp collect_recursive({:import, meta, children}, acc) do
    source = Keyword.get(meta, :source) || Keyword.get(meta, :name)

    acc =
      if source do
        entity = %{
          key: "import::#{source}",
          node_type: :import,
          node: {:import, meta, children},
          line: Keyword.get(meta, :line)
        }

        [entity | acc]
      else
        acc
      end

    recurse_children(children, acc)
  end

  defp collect_recursive({_type, _meta, children}, acc) when is_list(children) do
    recurse_children(children, acc)
  end

  defp collect_recursive(_, acc), do: acc

  defp recurse_children(children, acc) when is_list(children) do
    Enum.reduce(children, acc, &collect_recursive/2)
  end

  defp recurse_children(_, acc), do: acc

  defp children_equal?({type_a, _meta_a, children_a}, {type_b, _meta_b, children_b}) do
    type_a == type_b and children_structurally_equal?(children_a, children_b)
  end

  defp children_equal?(a, b), do: a == b

  defp children_structurally_equal?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {ca, cb} -> children_equal?(ca, cb) end)
  end

  defp children_structurally_equal?(a, b), do: a == b
end
