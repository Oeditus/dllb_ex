defmodule Dllb.MetaAST.QueryHelpers do
  @moduledoc """
  High-level AST query utilities for common code intelligence operations
  on MetaAST trees (Elixir 3-tuples).

  These functions provide structural queries: parent/sibling/ancestor lookups,
  type and name searches, scope resolution, call target extraction, and
  complexity estimation.

  Mirrors the Rust `dllb-code-intel::query_helpers` module, enabling
  client-side tree navigation without a dllb server round-trip.

  ## Usage

      tree = Metastatic.parse!(source)

      # Find all function definitions
      fns = Dllb.MetaAST.QueryHelpers.find_by_type(tree, :function_def)

      # Get complexity of a function
      complexity = Dllb.MetaAST.QueryHelpers.complexity_estimate(fn_node)

      # What's at line 42?
      scopes = Dllb.MetaAST.QueryHelpers.scope_at(tree, 42)
  """

  @doc """
  Find all nodes of a given type in the tree (depth-first).
  """
  @spec find_by_type(tuple(), atom()) :: [tuple()]
  def find_by_type(tree, node_type) do
    tree
    |> find_by_type_acc(node_type, [])
    |> Enum.reverse()
  end

  @doc """
  Find all nodes whose `:name` metadata matches the given string.
  """
  @spec find_by_name(tuple(), String.t() | atom()) :: [tuple()]
  def find_by_name(tree, name) do
    name_str = to_string(name)

    tree
    |> find_by_name_acc(name_str, [])
    |> Enum.reverse()
  end

  @doc """
  Find the immediate parent of a target node in the tree.

  Uses structural equality to locate the target. Returns `nil` if the
  target is the root or not found.
  """
  @spec find_parent(tuple(), tuple()) :: tuple() | nil
  def find_parent(root, target) do
    if root == target, do: nil, else: find_parent_inner(root, target)
  end

  @doc """
  Find all sibling nodes (same parent, excluding the target itself).
  """
  @spec find_siblings(tuple(), tuple()) :: [tuple()]
  def find_siblings(root, target) do
    case find_parent(root, target) do
      nil ->
        []

      {_type, _meta, children} when is_list(children) ->
        Enum.reject(children, &(&1 == target))

      _ ->
        []
    end
  end

  @doc """
  Return the ancestor path from root to target's parent (outermost first).

  Returns an empty list if the target is the root or not found.
  """
  @spec ancestors(tuple(), tuple()) :: [tuple()]
  def ancestors(root, target) do
    if root == target do
      []
    else
      case ancestors_inner(root, target, []) do
        {:found, path} -> Enum.reverse(path)
        :not_found -> []
      end
    end
  end

  @doc """
  Find the nearest `:function_def` ancestor of the target node.
  """
  @spec containing_function(tuple(), tuple()) :: tuple() | nil
  def containing_function(root, target) do
    root
    |> ancestors(target)
    |> Enum.reverse()
    |> Enum.find(&match?({:function_def, _, _}, &1))
  end

  @doc """
  Find the nearest `:container` ancestor (module/class) of the target node.
  """
  @spec containing_container(tuple(), tuple()) :: tuple() | nil
  def containing_container(root, target) do
    root
    |> ancestors(target)
    |> Enum.reverse()
    |> Enum.find(&match?({:container, _, _}, &1))
  end

  @doc """
  Find all nodes whose line range contains the given line number.

  Looks for `:line` (single line) or `:line`/`:end_line` in metadata.
  Returns nodes from outermost to innermost.
  """
  @spec scope_at(tuple(), non_neg_integer()) :: [tuple()]
  def scope_at(tree, line) do
    tree
    |> scope_at_acc(line, [])
    |> Enum.reverse()
  end

  @doc """
  Extract all function call target names within a subtree.
  """
  @spec call_targets(tuple()) :: [String.t()]
  def call_targets(tree) do
    tree
    |> call_targets_acc([])
    |> Enum.reverse()
  end

  @doc """
  Estimate cyclomatic complexity of a function body by counting branch points.

  Counts: `:conditional`, `:loop`, `:pattern_match`, `:match_arm`,
  `:exception_handling` nodes. Base complexity is 1.
  """
  @spec complexity_estimate(tuple()) :: non_neg_integer()
  def complexity_estimate(tree) do
    1 + count_branches(tree)
  end

  # -- Private ----------------------------------------------------------------

  defp find_by_type_acc({type, _meta, children} = node, target_type, acc)
       when is_list(children) do
    acc = if type == target_type, do: [node | acc], else: acc
    Enum.reduce(children, acc, &find_by_type_acc(&1, target_type, &2))
  end

  defp find_by_type_acc({type, _meta, _value} = node, target_type, acc) do
    if type == target_type, do: [node | acc], else: acc
  end

  defp find_by_type_acc(_, _, acc), do: acc

  defp find_by_name_acc({_type, meta, children} = node, name, acc) when is_list(children) do
    node_name = Keyword.get(meta, :name)
    acc = if to_string(node_name) == name, do: [node | acc], else: acc
    Enum.reduce(children, acc, &find_by_name_acc(&1, name, &2))
  end

  defp find_by_name_acc({_type, meta, _value} = node, name, acc) do
    node_name = Keyword.get(meta, :name)
    if to_string(node_name) == name, do: [node | acc], else: acc
  end

  defp find_by_name_acc(_, _, acc), do: acc

  defp find_parent_inner({_type, _meta, children} = node, target) when is_list(children) do
    if Enum.any?(children, &(&1 == target)) do
      node
    else
      Enum.find_value(children, &find_parent_inner(&1, target))
    end
  end

  defp find_parent_inner(_, _), do: nil

  defp ancestors_inner({_type, _meta, children} = node, target, path) when is_list(children) do
    if Enum.any?(children, &(&1 == target)) do
      {:found, [node | path]}
    else
      Enum.find_value(children, fn child ->
        ancestors_inner(child, target, [node | path])
      end) || :not_found
    end
  end

  defp ancestors_inner(_, _, _), do: :not_found

  defp scope_at_acc({_type, meta, children} = node, line, acc) when is_list(children) do
    contains =
      case {Keyword.get(meta, :line), Keyword.get(meta, :end_line)} do
        {start, end_line} when is_integer(start) and is_integer(end_line) ->
          line >= start and line <= end_line

        {l, _} when is_integer(l) ->
          line == l

        _ ->
          false
      end

    acc = if contains, do: [node | acc], else: acc
    Enum.reduce(children, acc, &scope_at_acc(&1, line, &2))
  end

  defp scope_at_acc({_type, meta, _value} = node, line, acc) do
    l = Keyword.get(meta, :line)
    if is_integer(l) and l == line, do: [node | acc], else: acc
  end

  defp scope_at_acc(_, _, acc), do: acc

  defp call_targets_acc({:function_call, meta, children}, acc) when is_list(children) do
    name = Keyword.get(meta, :name)
    acc = if name, do: [to_string(name) | acc], else: acc
    Enum.reduce(children, acc, &call_targets_acc/2)
  end

  defp call_targets_acc({_type, _meta, children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &call_targets_acc/2)
  end

  defp call_targets_acc(_, acc), do: acc

  @branch_types [:conditional, :loop, :pattern_match, :match_arm, :exception_handling]

  defp count_branches({type, _meta, children}) when is_list(children) do
    base = if type in @branch_types, do: 1, else: 0
    base + Enum.sum(Enum.map(children, &count_branches/1))
  end

  defp count_branches({type, _meta, _value}) do
    if type in @branch_types, do: 1, else: 0
  end

  defp count_branches(_), do: 0
end
