defmodule DllbTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST.NodeTypes

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

    test "update_where generates UPDATE ... WHERE" do
      result =
        Dllb.Query.update_where(
          "ast_node",
          %{source_embedding: [0.1, 0.2]},
          "kind = 'function_def'"
        )

      assert result =~ "UPDATE ast_node SET source_embedding = [0.1, 0.2]"
      assert result =~ "WHERE kind = 'function_def'"
    end

    test "count without where" do
      assert Dllb.Query.count("ast_node") == "COUNT ast_node"
    end

    test "count with where" do
      assert Dllb.Query.count("ast_node", where: "source_embedding IS NOT NONE") ==
               "COUNT ast_node WHERE source_embedding IS NOT NONE"
    end

    test "graph_components generates statement" do
      assert Dllb.Query.graph_components("calls") == "GRAPH COMPONENTS calls"
    end

    test "delete generates correct SQL" do
      assert Dllb.Query.delete("ast_node:fn_1") == "DELETE ast_node:fn_1"
    end

    test "define_table generates correct SQL" do
      assert Dllb.Query.define_table("ast_node", :schemafull) =~
               "DEFINE TABLE ast_node SCHEMAFULL"
    end

    test "define_index builds secondary index DDL" do
      assert Dllb.Query.define_index("user", "by_age", ["age"]) ==
               "DEFINE INDEX by_age ON TABLE user FIELDS age"
    end

    test "define_index supports composite (multi-field) indexes" do
      assert Dllb.Query.define_index("ast_node", "idx_file_kind", ["file_path", "kind"]) ==
               "DEFINE INDEX idx_file_kind ON TABLE ast_node FIELDS file_path, kind"
    end

    test "define_index supports the unique option" do
      assert Dllb.Query.define_index("user", "by_email", ["email"], unique: true) ==
               "DEFINE INDEX by_email ON TABLE user FIELDS email UNIQUE"
    end

    test "remove_index builds REMOVE INDEX DDL" do
      assert Dllb.Query.remove_index("user", "by_age") == "REMOVE INDEX by_age ON TABLE user"
    end

    test "upsert builds CREATE ... ON CONFLICT UPDATE" do
      assert Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30}) ==
               "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE"
    end

    test "upsert with explicit update fields builds ON CONFLICT UPDATE SET" do
      assert Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30}, %{age: 31}) ==
               "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE SET age = 31"
    end

    test "define_fulltext_index builds FULLTEXT INDEX DDL" do
      assert Dllb.Query.define_fulltext_index("article", "ft_body", "body") ==
               "DEFINE FULLTEXT INDEX ft_body ON TABLE article FIELDS body"
    end

    test "define_fulltext_index supports the analyzer option" do
      assert Dllb.Query.define_fulltext_index("article", "ft_body", "body", analyzer: "english") ==
               "DEFINE FULLTEXT INDEX ft_body ON TABLE article FIELDS body ANALYZER english"
    end

    test "define_vector_index builds VECTOR INDEX DDL" do
      assert Dllb.Query.define_vector_index("doc", "vec_emb", "embedding", 8) ==
               "DEFINE VECTOR INDEX vec_emb ON TABLE doc FIELDS embedding DIMENSION 8"
    end

    test "define_vector_index supports the metric option" do
      assert Dllb.Query.define_vector_index("doc", "vec_emb", "embedding", 8, metric: "euclidean") ==
               "DEFINE VECTOR INDEX vec_emb ON TABLE doc FIELDS embedding DIMENSION 8 METRIC euclidean"
    end

    test "search builds a BM25 SEARCH statement" do
      assert Dllb.Query.search("article", "body", "graph database") ==
               "SEARCH article body 'graph database'"
    end

    test "search escapes the query and appends LIMIT" do
      assert Dllb.Query.search("article", "body", "it's", limit: 5) ==
               "SEARCH article body 'it''s' LIMIT 5"
    end

    test "vector_search builds a VECTOR SEARCH statement" do
      assert Dllb.Query.vector_search("doc", "embedding", [0.1, 0.2, 0.3]) ==
               "VECTOR SEARCH doc embedding [0.1, 0.2, 0.3]"
    end

    test "vector_search appends K" do
      assert Dllb.Query.vector_search("doc", "embedding", [1, 2, 3], k: 5) ==
               "VECTOR SEARCH doc embedding [1, 2, 3] K 5"
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

    test "parses count status" do
      assert {:ok, %Dllb.Result.Count{count: 42}} =
               Dllb.Result.parse(%{"status" => "count", "count" => 42})
    end

    test "parses update status" do
      assert {:ok, %Dllb.Result.Update{matched: 3}} =
               Dllb.Result.parse(%{"status" => "update", "matched" => 3})
    end

    test "parses components status" do
      assert {:ok, %Dllb.Result.Components{component_count: 2, largest: 5, nodes: 8}} =
               Dllb.Result.parse(%{
                 "status" => "components",
                 "component_count" => 2,
                 "largest" => 5,
                 "nodes" => 8
               })
    end
  end

  describe "Dllb.MetaAST.NodeTypes" do
    test "all returns 45 types" do
      all = NodeTypes.all()
      assert length(all) == 45
    end

    test "core returns 19 types" do
      assert length(NodeTypes.core()) == 19
    end

    test "extended returns 14 types" do
      assert length(NodeTypes.extended()) == 14
    end

    test "structural returns 11 types" do
      assert length(NodeTypes.structural()) == 11
    end

    test "native returns 1 type" do
      assert [_ | []] = NodeTypes.native()
    end

    test "valid? accepts all 8 newly-added types" do
      assert NodeTypes.valid?(:throw)
      assert NodeTypes.valid?(:yield)
      assert NodeTypes.valid?(:pipe)
      assert NodeTypes.valid?(:pin)
      assert NodeTypes.valid?(:assert_type)
      assert NodeTypes.valid?(:decorator)
      assert NodeTypes.valid?(:record_update)
      assert NodeTypes.valid?(:child_spec)
    end

    test "valid? rejects unknown types" do
      refute NodeTypes.valid?(:nonexistent)
      refute NodeTypes.valid?(:foo)
    end

    test "layer returns correct layer for all groups" do
      assert NodeTypes.layer(:literal) == :core
      assert NodeTypes.layer(:throw) == :core
      assert NodeTypes.layer(:loop) == :extended
      assert NodeTypes.layer(:yield) == :extended
      assert NodeTypes.layer(:pipe) == :extended
      assert NodeTypes.layer(:container) == :structural
      assert NodeTypes.layer(:decorator) == :structural
      assert NodeTypes.layer(:child_spec) == :structural
      assert NodeTypes.layer(:language_specific) == :native
    end

    test "to_dllb_kind and from_dllb_kind round-trip" do
      for type <- NodeTypes.all() do
        kind = NodeTypes.to_dllb_kind(type)
        assert {:ok, ^type} = NodeTypes.from_dllb_kind(kind)
      end
    end
  end

  describe "Dllb.Schema" do
    test "all_statements returns table + index definitions" do
      stmts = Dllb.Schema.all_statements()
      assert [_ | _] = stmts

      joined = Enum.join(stmts, " ")
      assert joined =~ "DEFINE TABLE ast_node"

      assert joined =~ "DEFINE FIELD name ON ast_node" or
               joined =~ "DEFINE FIELD kind ON ast_node"

      assert joined =~ "DEFINE INDEX"
    end

    test "ast_node_indexes uses secondary-index DDL without HNSW/fulltext" do
      idx = Enum.join(Dllb.Schema.ast_node_indexes(), " ")
      assert idx =~ "DEFINE INDEX idx_file_kind ON TABLE ast_node FIELDS file_path, kind"
      refute idx =~ "HNSW"
      refute idx =~ "SEARCH ANALYZER"
      refute idx =~ "fulltext"
    end

    test "ast_node_search_indexes defines fulltext and vector indexes" do
      joined = Enum.join(Dllb.Schema.ast_node_search_indexes(), " ")

      assert joined =~
               "DEFINE FULLTEXT INDEX idx_source_text ON TABLE ast_node FIELDS source_text"

      assert joined =~ "DEFINE FULLTEXT INDEX idx_docstring ON TABLE ast_node FIELDS docstring"

      assert joined =~
               "DEFINE VECTOR INDEX idx_source_embedding ON TABLE ast_node FIELDS source_embedding DIMENSION 768 METRIC cosine"

      assert joined =~
               "DEFINE VECTOR INDEX idx_structure_embedding ON TABLE ast_node FIELDS structure_embedding DIMENSION 384 METRIC cosine"
    end

    test "all_statements includes full-text and vector search index DDL" do
      joined = Enum.join(Dllb.Schema.all_statements(), " ")
      assert joined =~ "DEFINE FULLTEXT INDEX"
      assert joined =~ "DEFINE VECTOR INDEX"
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
