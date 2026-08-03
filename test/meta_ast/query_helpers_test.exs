defmodule Dllb.MetaAST.QueryHelpersTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST.QueryHelpers, as: QH

  # A small tree modeled after the QueryHelpers moduledoc example:
  #
  # Container "Mod" (lines 1-20)
  #   FunctionDef "process" (lines 2-15)
  #     Conditional (line 3)
  #       FunctionCall "validate"
  #       FunctionCall "transform"
  #     Loop (line 7)
  #       FunctionCall "step"
  #   FunctionDef "helper" (lines 16-19)
  #     Variable "x"
  defp tree do
    {:container, [name: "Mod", line: 1, end_line: 20],
     [
       {:function_def, [name: "process", line: 2, end_line: 15, params: []],
        [
          {:conditional, [line: 3],
           [{:function_call, [name: "validate"], []}, {:function_call, [name: "transform"], []}]},
          {:loop, [line: 7], [{:function_call, [name: "step"], []}]}
        ]},
       {:function_def, [name: "helper", line: 16, end_line: 19, params: []],
        [{:variable, [], "x"}]}
     ]}
  end

  defp process_fn, do: tree() |> elem(2) |> Enum.at(0)
  defp helper_fn, do: tree() |> elem(2) |> Enum.at(1)
  defp conditional_node, do: process_fn() |> elem(2) |> Enum.at(0)

  describe "find_by_type/2" do
    test "finds all nodes of a given type, depth-first" do
      names =
        QH.find_by_type(tree(), :function_def)
        |> Enum.map(fn {_, meta, _} -> Keyword.get(meta, :name) end)

      assert names == ["process", "helper"]
    end

    test "returns an empty list when no nodes match" do
      assert QH.find_by_type(tree(), :import) == []
    end
  end

  describe "find_by_name/2" do
    test "finds nodes whose :name metadata matches" do
      assert [{:function_def, _, _}] = QH.find_by_name(tree(), "process")
    end

    test "accepts an atom name and stringifies it" do
      assert [{:function_def, _, _}] = QH.find_by_name(tree(), :process)
    end
  end

  describe "find_parent/2 and find_siblings/2" do
    test "find_parent returns nil for the root" do
      assert QH.find_parent(tree(), tree()) == nil
    end

    test "find_parent returns the immediate parent of a nested node" do
      assert QH.find_parent(tree(), process_fn()) == tree()
    end

    test "find_siblings excludes the target itself" do
      siblings = QH.find_siblings(tree(), process_fn())
      assert [{:function_def, meta, _}] = siblings
      assert Keyword.get(meta, :name) == "helper"
    end

    test "find_siblings returns an empty list for the root" do
      assert QH.find_siblings(tree(), tree()) == []
    end
  end

  describe "ancestors/2" do
    test "returns the outermost-first ancestor path" do
      assert QH.ancestors(tree(), conditional_node()) == [tree(), process_fn()]
    end

    test "returns an empty list for the root" do
      assert QH.ancestors(tree(), tree()) == []
    end
  end

  describe "containing_function/2 and containing_container/2" do
    test "containing_function finds the nearest function_def ancestor" do
      assert QH.containing_function(tree(), conditional_node()) == process_fn()
    end

    test "containing_function returns nil when the node itself is the function" do
      assert QH.containing_function(tree(), process_fn()) == nil
    end

    test "containing_container finds the nearest container ancestor" do
      assert QH.containing_container(tree(), process_fn()) == tree()
    end
  end

  describe "scope_at/2" do
    test "returns nodes outermost-to-innermost whose range contains the line" do
      scopes = QH.scope_at(tree(), 3) |> Enum.map(&elem(&1, 0))
      assert scopes == [:container, :function_def, :conditional]
    end

    test "returns an empty list when no scope contains the line" do
      assert QH.scope_at(tree(), 100) == []
    end
  end

  describe "call_targets/1" do
    test "extracts all function call targets within a subtree" do
      assert QH.call_targets(process_fn()) == ["validate", "transform", "step"]
    end

    test "returns an empty list when there are no calls" do
      assert QH.call_targets(helper_fn()) == []
    end
  end

  describe "complexity_estimate/1" do
    test "counts branch points plus a base complexity of 1" do
      # process/0 has one Conditional and one Loop -> base 1 + 2 branches = 3
      assert QH.complexity_estimate(process_fn()) == 3
    end

    test "a straight-line function has a complexity of 1" do
      assert QH.complexity_estimate(helper_fn()) == 1
    end
  end
end
