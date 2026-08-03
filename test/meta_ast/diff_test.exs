defmodule Dllb.MetaAST.DiffTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST.Diff

  describe "diff_trees/2" do
    test "identical trees produce an empty diff" do
      tree =
        {:container, [name: "Mod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], [{:literal, [], 1}]}]}

      diff = Diff.diff_trees(tree, tree)

      assert diff.changes == []
      assert diff.added == 0
      assert diff.removed == 0
      assert diff.modified == 0
      assert diff.renamed == 0
    end

    test "a newly added function is reported as :added, and its container as :modified" do
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], []}]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []], []},
           {:function_def, [name: "bar", line: 5, params: []], []}
         ]}

      diff = Diff.diff_trees(old_tree, new_tree)

      assert diff.added == 1
      assert diff.modified == 1
      assert diff.removed == 0
      assert diff.renamed == 0

      assert Enum.find(diff.changes, &(&1.name == "fn::bar/0")).kind == :added
      assert Enum.find(diff.changes, &(&1.name == "container::MyMod")).kind == :modified
    end

    test "a removed function is reported as :removed, and its container as :modified" do
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []], []},
           {:function_def, [name: "bar", line: 5, params: []], []}
         ]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], []}]}

      diff = Diff.diff_trees(old_tree, new_tree)

      assert diff.removed == 1
      assert diff.modified == 1
      assert diff.added == 0

      assert Enum.find(diff.changes, &(&1.name == "fn::bar/0")).kind == :removed
    end

    test "a structurally changed function body is reported as :modified" do
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], [{:literal, [], 1}]}]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []],
            [
              {:literal, [], 1},
              {:literal, [], 2}
            ]}
         ]}

      diff = Diff.diff_trees(old_tree, new_tree)

      assert diff.modified == 2
      assert Enum.find(diff.changes, &(&1.name == "fn::foo/0")).kind == :modified
      assert Enum.find(diff.changes, &(&1.name == "container::MyMod")).kind == :modified
    end

    test "a function renamed with an unchanged body is detected via structural matching" do
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], [{:literal, [], 1}]}]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "baz", line: 2, params: []], [{:literal, [], 1}]}]}

      diff = Diff.diff_trees(old_tree, new_tree)

      assert diff.renamed == 1
      assert diff.added == 0
      assert diff.removed == 0

      change = Enum.find(diff.changes, &(&1.kind == :renamed))
      assert change.name == "fn::foo/0 -> fn::baz/0"
      # Renaming without a structural change leaves the container itself unaffected,
      # since comparison ignores node metadata (names) at every level.
      assert Enum.find(diff.changes, &(&1.name == "container::MyMod")) == nil
    end

    test "changes confined to node metadata (e.g. a call target's name) are not detected" do
      # NOTE: `diff_trees/2` compares node *type* and *children* recursively, but
      # never the `meta` keyword list. Since call targets, variable names, and
      # other identifiers live in `meta`, changing only those leaves the diff
      # empty -- this mirrors the current behavior of the underlying algorithm.
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []],
            [
              {:function_call, [name: "bar"], []}
            ]}
         ]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []],
            [
              {:function_call, [name: "baz"], []}
            ]}
         ]}

      assert Diff.diff_trees(old_tree, new_tree) |> Diff.empty?()
    end

    test "handles imports" do
      old_tree = {:container, [name: "MyMod", line: 1], [{:import, [source: "A"], []}]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [{:import, [source: "A"], []}, {:import, [source: "B"], []}]}

      diff = Diff.diff_trees(old_tree, new_tree)
      assert Enum.find(diff.changes, &(&1.name == "import::B")).kind == :added
    end
  end

  describe "empty?/1" do
    test "true when there are no changes" do
      assert Diff.empty?(%{changes: [], added: 0, removed: 0, modified: 0, renamed: 0})
    end

    test "false when there are changes" do
      summary = %{
        changes: [%{kind: :added, node_type: :function_def, name: "fn::foo/0", line: 1}],
        added: 1,
        removed: 0,
        modified: 0,
        renamed: 0
      }

      refute Diff.empty?(summary)
    end
  end

  describe "stale_entities/1 and removed_entities/1" do
    test "stale_entities returns the names of added, modified, and renamed changes" do
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], []}]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []], []},
           {:function_def, [name: "bar", line: 5, params: []], []}
         ]}

      diff = Diff.diff_trees(old_tree, new_tree)
      stale = Diff.stale_entities(diff)

      assert "container::MyMod" in stale
      assert "fn::bar/0" in stale
    end

    test "removed_entities returns only the names of removed changes" do
      old_tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "foo", line: 2, params: []], []},
           {:function_def, [name: "bar", line: 5, params: []], []}
         ]}

      new_tree =
        {:container, [name: "MyMod", line: 1],
         [{:function_def, [name: "foo", line: 2, params: []], []}]}

      diff = Diff.diff_trees(old_tree, new_tree)

      assert Diff.removed_entities(diff) == ["fn::bar/0"]
    end
  end
end
