defmodule Dllb.MetaASTTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST

  @ctx %{language: :elixir, file_path: "/app/lib/my_mod.ex"}

  defp tree do
    {:container, [name: "MyMod", line: 1],
     [
       {:import, [name: "OtherMod", line: 2], []},
       {:function_def, [name: "foo", line: 3, params: []],
        [{:function_call, [name: "bar", line: 4], []}]}
     ]}
  end

  describe "to_dllb_edges/2" do
    test "extracts imports, contains, and calls edges with deterministic node IDs" do
      edges = MetaAST.to_dllb_edges(tree(), @ctx)

      assert {"ast_node:my_mod_MyMod_1", "imports", "ast_node:my_mod_OtherMod_2",
              %{module: "OtherMod"}} in edges

      assert {"ast_node:my_mod_MyMod_1", "contains", "ast_node:my_mod_foo_3", %{}} in edges

      assert {"ast_node:my_mod_foo_3", "calls", "ast_node:my_mod_bar_4", %{callee: "bar"}} in edges
    end

    test "returns an empty list for a tree with no edges" do
      leaf = {:literal, [line: 1], 42}
      assert MetaAST.to_dllb_edges(leaf, @ctx) == []
    end
  end

  describe "ingest_tree/3" do
    test "executes CREATE and RELATE queries via query_fn and tallies counts" do
      query_fn = fn q ->
        send(self(), {:query, q})
        {:ok, %Dllb.Result.Created{id: "ast_node:x"}}
      end

      assert {:ok, %{nodes: 4, edges: 3}} = MetaAST.ingest_tree(tree(), @ctx, query_fn)
      assert_received {:query, query} when is_binary(query)
    end

    test "stops and returns the error on the first failing create" do
      query_fn = fn _q -> {:error, :boom} end
      assert {:error, :boom} = MetaAST.ingest_tree(tree(), @ctx, query_fn)
    end
  end

  describe "to_json_string/1" do
    test "serializes node_type, meta, and a nested child node" do
      node = {:function_call, [name: "bar"], [{:literal, [], 42}]}

      assert MetaAST.to_json_string(node) ==
               ~s|{"children":{"Nodes":[{"children":{"Value":{"Int":42}},"meta":[],"node_type":"Literal"}]},"meta":[["name",{"String":"bar"}]],"node_type":"FunctionCall"}|
    end

    test "serializes nested composite children (list of AST nodes)" do
      node = {:map, [], [{:pair, [], [{:literal, [], "k"}, {:literal, [], 1}]}]}

      assert MetaAST.to_json_string(node) ==
               ~s|{"children":{"Nodes":[{"children":{"Nodes":[{"children":{"Value":{"String":"k"}},"meta":[],"node_type":"Literal"},{"children":{"Value":{"Int":1}},"meta":[],"node_type":"Literal"}]},"meta":[],"node_type":"Pair"}]},"meta":[],"node_type":"Map"}|
    end

    test "serializes bool, nil, atom, and float meta/leaf values" do
      node = {:literal, [flag: true, extra: nil, tag: :ok], 3.14}

      assert MetaAST.to_json_string(node) ==
               ~s|{"children":{"Value":{"Float":3.14}},"meta":[["flag",{"Bool":true}],["extra","Null"],["tag",{"Atom":"ok"}]],"node_type":"Literal"}|
    end

    test "falls back to a capitalized-underscore split for unmapped node types" do
      assert MetaAST.to_json_string({:custom_node_kind, [], []}) =~
               ~s|"node_type":"CustomNodeKind"|
    end
  end
end
