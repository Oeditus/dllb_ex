defmodule Dllb.MetaAST.SimilarityTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST.Similarity

  defp make_binop(var, val) do
    {:binary_op, [operator: :+], [{:variable, [], var}, {:literal, [], val}]}
  end

  defp make_fn(name, body) do
    {:function_def, [name: name], [{:param, [], "arg"}, body]}
  end

  describe "structural_similarity/2" do
    test "identical trees score 1.0" do
      a = make_binop("x", 5)
      b = make_binop("y", 10)
      assert_in_delta Similarity.structural_similarity(a, b), 1.0, 1.0e-10
    end

    test "same structure with different leaf values/names scores high" do
      a = make_fn("add", make_binop("x", 1))
      b = make_fn("subtract", make_binop("y", 99))
      assert Similarity.structural_similarity(a, b) > 0.95
    end

    test "completely different trees score low" do
      a = {:literal, [], 42}

      b =
        {:container, [],
         [
           {:function_def, [],
            [
              {:param, [], "x"},
              {:block, [], [{:variable, [], "a"}, {:variable, [], "b"}]}
            ]}
         ]}

      assert Similarity.structural_similarity(a, b) < 0.2
    end

    test "two identical leaves score 1.0" do
      leaf = {:literal, [], 42}
      assert Similarity.structural_similarity(leaf, leaf) == 1.0
    end

    test "same leaf type but different value scores 1.0 (leaf value is ignored)" do
      assert Similarity.structural_similarity({:literal, [], 42}, {:literal, [], 43}) == 1.0
    end

    test "different leaf node types score 0.0" do
      assert Similarity.structural_similarity({:literal, [], 42}, {:variable, [], "x"}) == 0.0
    end

    test "one leaf vs one composite of the same type scores 0.3" do
      leaf = {:block, [], 1}
      composite = {:block, [], [{:literal, [], 1}]}
      assert Similarity.structural_similarity(leaf, composite) == 0.3
    end

    test "one leaf vs one composite of a different type scores 0.0" do
      leaf = {:literal, [], 1}
      composite = {:block, [], [{:literal, [], 1}]}
      assert Similarity.structural_similarity(leaf, composite) == 0.0
    end

    test "falls back to 0.0 for malformed (non-3-tuple) input" do
      assert Similarity.structural_similarity(:not_a_node, :also_not) == 0.0
    end
  end

  describe "tree_fingerprint/1 and subtree_hash/1" do
    test "structurally identical trees have equal fingerprints and hashes" do
      a = make_fn("foo", make_binop("a", 1))
      b = make_fn("bar", make_binop("b", 2))

      assert Similarity.tree_fingerprint(a) == Similarity.tree_fingerprint(b)
      assert Similarity.subtree_hash(a) == Similarity.subtree_hash(b)
    end

    test "structurally different trees have different fingerprints and hashes" do
      a = make_fn("foo", make_binop("a", 1))
      c = {:literal, [], 0}

      assert Similarity.tree_fingerprint(a) != Similarity.tree_fingerprint(c)
      assert Similarity.subtree_hash(a) != Similarity.subtree_hash(c)
    end

    test "tree_fingerprint returns a list of integers, root-first" do
      node = {:literal, [], 1}
      assert [hash] = Similarity.tree_fingerprint(node)
      assert is_integer(hash)
    end
  end

  describe "find_clones/2" do
    test "detects structurally similar pairs above the threshold" do
      fn1 = make_fn("alpha", make_binop("x", 1))
      fn2 = make_fn("beta", make_binop("y", 2))

      fn3 =
        {:loop, [],
         [
           {:variable, [], "i"},
           {:block, [], [{:literal, [], 0}, {:literal, [], 1}, {:literal, [], 2}]}
         ]}

      clones = Similarity.find_clones([fn1, fn2, fn3], threshold: 0.9)

      assert [%{index_a: 0, index_b: 1, similarity: sim}] = clones
      assert sim > 0.9
    end

    test "returns an empty list when nothing meets the threshold" do
      fn1 = make_fn("alpha", make_binop("x", 1))
      fn3 = {:loop, [], [{:variable, [], "i"}, {:block, [], [{:literal, [], 0}]}]}

      assert Similarity.find_clones([fn1, fn3], threshold: 0.99) == []
    end

    test "defaults the threshold to 0.8" do
      fn1 = make_fn("alpha", make_binop("x", 1))
      fn2 = make_fn("beta", make_binop("y", 2))

      assert [%{similarity: sim}] = Similarity.find_clones([fn1, fn2])
      assert sim >= 0.8
    end

    test "results are sorted by descending similarity" do
      fn1 = make_fn("alpha", make_binop("x", 1))
      fn2 = make_fn("beta", make_binop("y", 2))
      fn3 = make_fn("gamma", make_binop("z", 3))

      clones = Similarity.find_clones([fn1, fn2, fn3], threshold: 0.0)
      similarities = Enum.map(clones, & &1.similarity)

      assert similarities == Enum.sort(similarities, :desc)
    end

    test "an empty input list yields no clones" do
      assert Similarity.find_clones([]) == []
    end
  end
end
