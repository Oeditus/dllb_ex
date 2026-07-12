defmodule Dllb.MetaAST.Similarity do
  @moduledoc """
  Structural similarity comparison for MetaAST trees.

  Provides functions for comparing AST subtrees structurally (ignoring
  names and values), computing structural fingerprints for fast
  pre-filtering, and detecting code clones across a set of subtrees.

  Mirrors the Rust `dllb-code-intel::similarity` module, enabling
  client-side clone detection without a server round-trip.

  ## Usage

      sim = Dllb.MetaAST.Similarity.structural_similarity(tree_a, tree_b)
      # => 0.95

      clones = Dllb.MetaAST.Similarity.find_clones(trees, threshold: 0.8)
      # => [%{index_a: 0, index_b: 3, similarity: 0.92}, ...]
  """

  # credo:disable-for-this-file

  @doc """
  Compute structural similarity between two MetaAST subtrees.

  Returns a score in `0.0..1.0` comparing tree shape and node types,
  ignoring names, values, and metadata. Uses greedy best-match pairing
  of children weighted by subtree size.

  - Same node type, both leaves: 1.0
  - Same node type, both composite: recursive greedy child matching
  - Different node type: 0.0 base, with partial credit if children overlap
  """
  @spec structural_similarity(tuple(), tuple()) :: float()
  def structural_similarity({type_a, _meta_a, children_a}, {type_b, _meta_b, children_b}) do
    same_type = type_a == type_b

    cond do
      # Both leaves (non-list children)
      not is_list(children_a) and not is_list(children_b) ->
        if same_type, do: 1.0, else: 0.0

      # Both composite
      is_list(children_a) and is_list(children_b) ->
        if children_a == [] and children_b == [] do
          if same_type, do: 1.0, else: 0.0
        else
          children_sim = greedy_children_similarity(children_a, children_b)
          a_size = subtree_size({type_a, [], children_a})
          b_size = subtree_size({type_b, [], children_b})
          total_size = (a_size + b_size) / 2.0
          root_weight = 1.0 / total_size
          children_weight = 1.0 - root_weight

          if same_type do
            root_weight * 1.0 + children_weight * children_sim
          else
            children_weight * children_sim * 0.5
          end
        end

      # One leaf, one composite
      true ->
        if same_type, do: 0.3, else: 0.0
    end
  end

  def structural_similarity(_, _), do: 0.0

  @doc """
  Produce a structural fingerprint of a MetaAST tree.

  Returns a list of integer hashes representing the structural skeleton
  (node types + arity at each level). Useful for fast pre-filtering before
  expensive similarity comparison.
  """
  @spec tree_fingerprint(tuple()) :: [non_neg_integer()]
  def tree_fingerprint(node) do
    node
    |> collect_fingerprints([])
    |> Enum.reverse()
  end

  @doc """
  Compute a single hash of the entire subtree structure.

  Two structurally identical trees (same node types, same arity at each
  position) produce the same hash.
  """
  @spec subtree_hash(tuple()) :: non_neg_integer()
  def subtree_hash(node), do: node_structural_hash(node)

  @doc """
  Find pairs of subtrees with structural similarity above the given threshold.

  Uses fingerprints for fast pre-filtering: only pairs whose root hash matches
  (or that have >50% fingerprint overlap) are subjected to full comparison.

  ## Options

    * `:threshold` - minimum similarity (default 0.8)

  Returns a list of `%{index_a: i, index_b: j, similarity: score}` maps,
  sorted by descending similarity.
  """
  @spec find_clones([tuple()], keyword()) :: [map()]
  def find_clones(nodes, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.8)
    fingerprints = Enum.map(nodes, &tree_fingerprint/1)
    fingerprints_tuple = List.to_tuple(fingerprints)
    nodes_tuple = List.to_tuple(nodes)

    nodes
    |> Enum.with_index()
    |> pairs()
    |> Enum.reduce([], fn {{_node_a, i}, {_node_b, j}}, acc ->
      fp_a = elem(fingerprints_tuple, i)
      fp_b = elem(fingerprints_tuple, j)

      if should_compare?(fp_a, fp_b) do
        sim = structural_similarity(elem(nodes_tuple, i), elem(nodes_tuple, j))

        if sim >= threshold do
          [%{index_a: i, index_b: j, similarity: sim} | acc]
        else
          acc
        end
      else
        acc
      end
    end)
    |> Enum.sort_by(& &1.similarity, :desc)
  end

  # -- Private ----------------------------------------------------------------

  defp subtree_size({_type, _meta, children}) when is_list(children) do
    1 + Enum.sum(Enum.map(children, &subtree_size/1))
  end

  defp subtree_size({_type, _meta, _value}), do: 1
  defp subtree_size(_), do: 1

  defp greedy_children_similarity([], []), do: 1.0
  defp greedy_children_similarity([], _), do: 0.0
  defp greedy_children_similarity(_, []), do: 0.0

  defp greedy_children_similarity(a_children, b_children) do
    {smaller, larger} =
      if length(a_children) <= length(b_children),
        do: {a_children, b_children},
        else: {b_children, a_children}

    smaller_sizes = Enum.map(smaller, &subtree_size/1)
    larger_sizes = Enum.map(larger, &subtree_size/1)
    larger_sizes_tuple = List.to_tuple(larger_sizes)

    {total_weighted_sim, total_weight, used} =
      smaller
      |> Enum.zip(smaller_sizes)
      |> Enum.reduce({0.0, 0.0, MapSet.new()}, fn {s_child, s_size}, {tw_sim, tw, used} ->
        {best_sim, best_j} =
          larger
          |> Enum.with_index()
          |> Enum.reject(fn {_, j} -> MapSet.member?(used, j) end)
          |> Enum.reduce({0.0, nil}, fn {l_child, j}, {best, best_idx} ->
            sim = structural_similarity(s_child, l_child)
            if sim > best, do: {sim, j}, else: {best, best_idx}
          end)

        l_size = if best_j, do: elem(larger_sizes_tuple, best_j), else: 0
        weight = (s_size + l_size) / 2.0
        new_used = if best_j, do: MapSet.put(used, best_j), else: used

        {tw_sim + best_sim * weight, tw + weight, new_used}
      end)

    # Account for unmatched nodes in larger set
    unmatched_weight =
      larger_sizes
      |> Enum.with_index()
      |> Enum.reject(fn {_, j} -> MapSet.member?(used, j) end)
      |> Enum.reduce(0.0, fn {size, _}, acc -> acc + size end)

    total = total_weight + unmatched_weight
    if total == 0.0, do: 0.0, else: total_weighted_sim / total
  end

  defp node_structural_hash({type, _meta, children}) when is_list(children) do
    child_hashes = Enum.map(children, &node_structural_hash/1)
    :erlang.phash2({type, length(children), child_hashes})
  end

  defp node_structural_hash({type, _meta, _value}) do
    :erlang.phash2({type, 0, []})
  end

  defp node_structural_hash(_), do: 0

  defp collect_fingerprints({_type, _meta, children} = node, acc) when is_list(children) do
    acc = [node_structural_hash(node) | acc]
    Enum.reduce(children, acc, &collect_fingerprints/2)
  end

  defp collect_fingerprints(node, acc) when is_tuple(node) do
    [node_structural_hash(node) | acc]
  end

  defp collect_fingerprints(_, acc), do: acc

  defp should_compare?(fp_a, fp_b) do
    cond do
      # Root hashes match — likely very similar
      List.first(fp_a) == List.first(fp_b) ->
        true

      # Check fingerprint overlap
      true ->
        {smaller, larger} =
          if length(fp_a) <= length(fp_b), do: {fp_a, fp_b}, else: {fp_b, fp_a}

        if smaller == [] do
          false
        else
          larger_set = MapSet.new(larger)
          overlap = Enum.count(smaller, &MapSet.member?(larger_set, &1))
          overlap / length(smaller) > 0.5
        end
    end
  end

  defp pairs(indexed_list) do
    for {a, i} <- indexed_list,
        {b, j} <- indexed_list,
        i < j,
        do: {{a, i}, {b, j}}
  end
end
