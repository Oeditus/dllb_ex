defmodule Dllb.MetaAST.IngestTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST.Diff
  alias Dllb.MetaAST.Ingest

  defp simple_tree do
    {:container, [name: "MyMod", line: 1],
     [
       {:import, [source: "OtherMod"], []},
       {:function_def, [name: "foo", line: 2, params: []], [{:function_call, [name: "bar"], []}]}
     ]}
  end

  describe "prepare_batch/3" do
    test "produces one document per container/function_def and tallies stats" do
      batch = Ingest.prepare_batch(simple_tree(), "lib/my_mod.ex", "elixir")

      assert batch.file_path == "lib/my_mod.ex"
      assert batch.language == "elixir"

      assert Enum.map(batch.documents, & &1.id) == [
               "lib/my_mod.ex::container::MyMod",
               "lib/my_mod.ex::foo/0"
             ]

      assert batch.stats == %{containers: 1, functions: 1, imports: 1, calls: 1, edges: 3}
    end

    test "produces contains, imports, and calls edges" do
      batch = Ingest.prepare_batch(simple_tree(), "lib/my_mod.ex", "elixir")

      assert %{
               from_id: "lib/my_mod.ex::container::MyMod",
               to_id: "import::OtherMod",
               edge_type: "imports"
             } in batch.edges

      assert %{
               from_id: "lib/my_mod.ex::container::MyMod",
               to_id: "lib/my_mod.ex::foo/0",
               edge_type: "contains"
             } in batch.edges

      assert %{
               from_id: "lib/my_mod.ex::foo/0",
               to_id: "call_target::bar",
               edge_type: "calls"
             } in batch.edges
    end

    test "an empty tree with no named entities produces no documents" do
      batch = Ingest.prepare_batch({:comment, [], "just a comment"}, "lib/x.ex", "elixir")
      assert batch.documents == []
      assert batch.edges == []
    end
  end

  describe "to_queries/1" do
    test "wraps CREATE and RELATE statements in BEGIN/END BATCH" do
      batch = Ingest.prepare_batch(simple_tree(), "lib/my_mod.ex", "elixir")
      queries = Ingest.to_queries(batch)

      assert List.first(queries) == "BEGIN BATCH"
      assert List.last(queries) == "END BATCH"

      assert Enum.any?(
               queries,
               &(&1 ==
                   "CREATE ast_node:lib/my_mod.ex::container::MyMod SET file_path = 'lib/my_mod.ex', kind = 'container', language = 'elixir', line_start = 1, name = 'MyMod'")
             )

      assert Enum.any?(
               queries,
               &(&1 ==
                   "RELATE ast_node:lib/my_mod.ex::container::MyMod -> contains -> ast_node:lib/my_mod.ex::foo/0")
             )
    end
  end

  describe "merge_batches/1" do
    test "concatenates documents/edges and sums stats across multiple files" do
      b1 = Ingest.prepare_batch(simple_tree(), "lib/a.ex", "elixir")
      b2 = Ingest.prepare_batch(simple_tree(), "lib/b.ex", "elixir")

      merged = Ingest.merge_batches([b1, b2])

      assert merged.file_path == "[2 files]"
      assert length(merged.documents) == 4
      assert merged.stats == %{containers: 2, functions: 2, imports: 2, calls: 2, edges: 6}
    end

    test "a single-batch list keeps that batch's file_path" do
      b1 = Ingest.prepare_batch(simple_tree(), "lib/a.ex", "elixir")
      merged = Ingest.merge_batches([b1])
      assert merged.file_path == "lib/a.ex"
    end
  end

  describe "incremental_queries/4" do
    test "returns an empty list when there is no diff" do
      diff = Diff.diff_trees(simple_tree(), simple_tree())
      assert Ingest.incremental_queries(simple_tree(), diff, "lib/my_mod.ex", "elixir") == []
    end

    test "emits DELETE + CREATE + RELATE for an added function" do
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
      queries = Ingest.incremental_queries(new_tree, diff, "lib/my_mod.ex", "elixir")

      assert List.first(queries) == "BEGIN BATCH"
      assert List.last(queries) == "END BATCH"
      assert "DELETE ast_node:lib/my_mod.ex::bar/0" in queries
      assert "DELETE ast_node:lib/my_mod.ex::container::MyMod" in queries

      assert Enum.any?(
               queries,
               &(&1 =~ "CREATE ast_node:lib/my_mod.ex::bar/0 SET" and &1 =~ "name = 'bar'")
             )

      # foo/0 did not change, so it is neither deleted nor re-created (though it is
      # still referenced by the container's own `contains` edge, which is re-emitted
      # because the container itself is stale).
      refute Enum.any?(queries, &(&1 =~ "DELETE ast_node:lib/my_mod.ex::foo/0"))
      refute Enum.any?(queries, &(&1 =~ "CREATE ast_node:lib/my_mod.ex::foo/0"))

      assert "RELATE ast_node:lib/my_mod.ex::container::MyMod -> contains -> ast_node:lib/my_mod.ex::foo/0" in queries
    end

    test "emits only DELETE for a removed function (no re-create)" do
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
      queries = Ingest.incremental_queries(new_tree, diff, "lib/my_mod.ex", "elixir")

      assert "DELETE ast_node:lib/my_mod.ex::bar/0" in queries
      refute Enum.any?(queries, &(&1 =~ "CREATE ast_node:lib/my_mod.ex::bar/0"))
    end
  end
end
