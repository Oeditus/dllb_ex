defmodule DllbTest do
  use ExUnit.Case, async: true

  describe "Dllb.Query" do
    test "create generates correct SQL" do
      result = Dllb.Query.create("ast_node", %{name: "parse", kind: "function_def"})
      assert result =~ "CREATE ast_node SET"
      assert result =~ "name = 'parse'"
      assert result =~ "kind = 'function_def'"
    end

    test "create_with_id includes record ID" do
      result = Dllb.Query.create_with_id("ast_node", "fn_1", %{name: "parse"})
      assert result =~ "CREATE ast_node:fn_1 SET"
      assert result =~ "name = 'parse'"
    end

    test "select with options" do
      result = Dllb.Query.select("ast_node", where: "kind = 'function_def'", limit: 10)
      assert result =~ "SELECT * FROM ast_node"
      assert result =~ "WHERE kind = 'function_def'"
      assert result =~ "LIMIT 10"
    end

    test "select with fields" do
      result = Dllb.Query.select("ast_node", fields: ["name", "kind"])
      assert result =~ "SELECT name, kind FROM ast_node"
    end

    test "relate generates edge" do
      result = Dllb.Query.relate("module:MyApp", "contains", "ast_node:parse_2", %{line: 10})
      assert result =~ "RELATE module:MyApp->contains->ast_node:parse_2"
      assert result =~ "SET line = 10"
    end

    test "relate without properties" do
      result = Dllb.Query.relate("a:1", "calls", "b:2")
      assert result == "RELATE a:1->calls->b:2"
    end

    test "update generates correct SQL" do
      result = Dllb.Query.update("ast_node:fn_1", %{name: "new_name"})
      assert result =~ "UPDATE ast_node:fn_1 SET"
      assert result =~ "name = 'new_name'"
    end

    test "delete generates correct SQL" do
      assert Dllb.Query.delete("ast_node:fn_1") == "DELETE ast_node:fn_1"
    end

    test "define_table generates correct SQL" do
      assert Dllb.Query.define_table("ast_node", :schemafull) =~
               "DEFINE TABLE ast_node SCHEMAFULL"
    end

    test "raw passthrough" do
      assert Dllb.Query.raw("SELECT * FROM foo") == "SELECT * FROM foo"
    end

    test "escape_value handles nil" do
      result = Dllb.Query.create("t", %{x: nil})
      assert result =~ "NONE"
    end

    test "escape_value handles booleans" do
      result = Dllb.Query.create("t", %{active: true})
      assert result =~ "active = true"
    end

    test "escape_value escapes single quotes in strings" do
      result = Dllb.Query.create("t", %{name: "it's"})
      assert result =~ "name = 'it''s'"
    end
  end

  describe "Dllb.Protocol" do
    test "encode appends newline" do
      assert IO.iodata_to_binary(Dllb.Protocol.encode("SELECT 1")) == "SELECT 1\n"
    end

    test "decode parses JSON response" do
      {:ok, result} = Dllb.Protocol.decode(~s|{"status":"ok"}|)
      assert result == %{"status" => "ok"}
    end

    test "decode handles malformed JSON" do
      assert {:error, _} = Dllb.Protocol.decode("not json")
    end

    test "outcome_command returns correct format" do
      assert Dllb.Protocol.outcome_command(:json) == "OUTCOME json\n"
      assert Dllb.Protocol.outcome_command(:toon) == "OUTCOME toon\n"
      assert Dllb.Protocol.outcome_command(:csv) == "OUTCOME csv\n"
    end
  end

  describe "Dllb.Result" do
    test "parses ok status" do
      assert {:ok, %Dllb.Result.Ok{}} = Dllb.Result.parse(%{"status" => "ok"})
    end

    test "parses created status" do
      assert {:ok, %Dllb.Result.Created{id: "ast_node:fn_1"}} =
               Dllb.Result.parse(%{"status" => "created", "id" => "ast_node:fn_1"})
    end

    test "parses deleted status" do
      assert {:ok, %Dllb.Result.Deleted{existed: true}} =
               Dllb.Result.parse(%{"status" => "deleted", "existed" => true})
    end

    test "parses rows status" do
      assert {:ok, %Dllb.Result.Rows{count: 2, data: [_, _]}} =
               Dllb.Result.parse(%{
                 "status" => "rows",
                 "count" => 2,
                 "data" => [%{"name" => "a"}, %{"name" => "b"}]
               })
    end

    test "parses error status" do
      assert {:ok, %Dllb.Result.Error{message: "bad query"}} =
               Dllb.Result.parse(%{"status" => "error", "message" => "bad query"})
    end
  end

  describe "Dllb.MetaAST.NodeTypes" do
    test "all returns 45 types" do
      all = Dllb.MetaAST.NodeTypes.all()
      assert length(all) == 45
    end

    test "core returns 19 types" do
      assert length(Dllb.MetaAST.NodeTypes.core()) == 19
    end

    test "extended returns 14 types" do
      assert length(Dllb.MetaAST.NodeTypes.extended()) == 14
    end

    test "structural returns 11 types" do
      assert length(Dllb.MetaAST.NodeTypes.structural()) == 11
    end

    test "native returns 1 type" do
      assert [_ | []] = Dllb.MetaAST.NodeTypes.native()
    end

    test "valid? accepts all 8 newly-added types" do
      assert Dllb.MetaAST.NodeTypes.valid?(:throw)
      assert Dllb.MetaAST.NodeTypes.valid?(:yield)
      assert Dllb.MetaAST.NodeTypes.valid?(:pipe)
      assert Dllb.MetaAST.NodeTypes.valid?(:pin)
      assert Dllb.MetaAST.NodeTypes.valid?(:assert_type)
      assert Dllb.MetaAST.NodeTypes.valid?(:decorator)
      assert Dllb.MetaAST.NodeTypes.valid?(:record_update)
      assert Dllb.MetaAST.NodeTypes.valid?(:child_spec)
    end

    test "valid? rejects unknown types" do
      refute Dllb.MetaAST.NodeTypes.valid?(:nonexistent)
      refute Dllb.MetaAST.NodeTypes.valid?(:foo)
    end

    test "layer returns correct layer for all groups" do
      assert Dllb.MetaAST.NodeTypes.layer(:literal) == :core
      assert Dllb.MetaAST.NodeTypes.layer(:throw) == :core
      assert Dllb.MetaAST.NodeTypes.layer(:loop) == :extended
      assert Dllb.MetaAST.NodeTypes.layer(:yield) == :extended
      assert Dllb.MetaAST.NodeTypes.layer(:pipe) == :extended
      assert Dllb.MetaAST.NodeTypes.layer(:container) == :structural
      assert Dllb.MetaAST.NodeTypes.layer(:decorator) == :structural
      assert Dllb.MetaAST.NodeTypes.layer(:child_spec) == :structural
      assert Dllb.MetaAST.NodeTypes.layer(:language_specific) == :native
    end

    test "to_dllb_kind and from_dllb_kind round-trip" do
      for type <- Dllb.MetaAST.NodeTypes.all() do
        kind = Dllb.MetaAST.NodeTypes.to_dllb_kind(type)
        assert {:ok, ^type} = Dllb.MetaAST.NodeTypes.from_dllb_kind(kind)
      end
    end
  end

  describe "Dllb.Schema" do
    test "all_statements returns table + index definitions" do
      stmts = Dllb.Schema.all_statements()
      assert is_list(stmts)
      assert length(stmts) > 0

      joined = Enum.join(stmts, " ")
      assert joined =~ "DEFINE TABLE ast_node"

      assert joined =~ "DEFINE FIELD name ON ast_node" or
               joined =~ "DEFINE FIELD kind ON ast_node"

      assert joined =~ "DEFINE INDEX"
    end

    test "bootstrap executes all statements" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      query_fn = fn stmt ->
        Agent.update(agent, &[stmt | &1])
        {:ok, %{}}
      end

      assert {:ok, :bootstrapped} = Dllb.Schema.bootstrap(query_fn)

      executed = Agent.get(agent, & &1)
      Agent.stop(agent)
      assert length(executed) == length(Dllb.Schema.all_statements())
    end
  end

  describe "Dllb.MetaAST" do
    test "to_dllb_document extracts fields from Metastatic tuple" do
      node = {:function_def, [name: "parse", arity: 2, visibility: :public, line: 5], []}
      ctx = %{language: :elixir, file_path: "lib/parser.ex"}

      doc = Dllb.MetaAST.to_dllb_document(node, ctx)

      assert doc.name == "parse"
      assert doc.kind == "function_def"
      assert doc.language == "elixir"
      assert doc.file_path == "lib/parser.ex"
      assert doc.line_start == 5
    end

    test "to_dllb_document handles container nodes" do
      node = {:container, [name: "MyApp", container_type: :module, line: 1], []}
      ctx = %{language: :elixir, file_path: "lib/my_app.ex"}

      doc = Dllb.MetaAST.to_dllb_document(node, ctx)
      assert doc.name == "MyApp"
      assert doc.kind == "container"
    end

    test "from_dllb_row converts string-keyed map to atom-keyed" do
      row = %{
        "name" => "parse",
        "kind" => "function_def",
        "language" => "elixir",
        "line_start" => 5
      }

      result = Dllb.MetaAST.from_dllb_row(row)
      assert result.name == "parse"
      assert result.kind == :function_def
      assert result.line_start == 5
    end
  end
end
