defmodule Dllb.MetaAST.QueryTest do
  use ExUnit.Case, async: true

  alias Dllb.MetaAST.Query

  # ---------------------------------------------------------------------------
  # Node queries
  # ---------------------------------------------------------------------------

  describe "nodes_by_file/2" do
    test "builds SELECT with file_path filter" do
      q = Query.nodes_by_file("/app/lib/parser.ex")
      assert q =~ "SELECT * FROM ast_node"
      assert q =~ "file_path = '/app/lib/parser.ex'"
    end

    test "respects limit option" do
      q = Query.nodes_by_file("/app/lib/parser.ex", limit: 50)
      assert q =~ "LIMIT 50"
    end
  end

  describe "nodes_by_kind/2" do
    test "builds SELECT with kind filter" do
      q = Query.nodes_by_kind("function_def")
      assert q =~ "kind = 'function_def'"
    end
  end

  describe "functions_of_module/2" do
    test "builds SELECT with kind and module filter" do
      q = Query.functions_of_module("MyApp.Parser")
      assert q =~ "kind = 'function_def'"
      assert q =~ "module = 'MyApp.Parser'"
    end
  end

  describe "find_module/1" do
    test "builds SELECT with kind=container and name filter, limit 1" do
      q = Query.find_module("MyApp.Parser")
      assert q =~ "kind = 'container'"
      assert q =~ "name = 'MyApp.Parser'"
      assert q =~ "LIMIT 1"
    end
  end

  describe "find_function/3" do
    test "builds SELECT with composite filter" do
      q = Query.find_function("MyApp.Parser", "parse", 2)
      assert q =~ "kind = 'function_def'"
      assert q =~ "module = 'MyApp.Parser'"
      assert q =~ "name = 'parse'"
      assert q =~ "arity = 2"
      assert q =~ "LIMIT 1"
    end
  end

  describe "nodes_by_project/2" do
    test "builds SELECT with project_path filter" do
      q = Query.nodes_by_project("/opt/myproject")
      assert q =~ "project_path = '/opt/myproject'"
    end
  end

  # ---------------------------------------------------------------------------
  # Graph traversal queries
  # ---------------------------------------------------------------------------

  describe "callers_of/1" do
    test "builds incoming calls traversal" do
      q = Query.callers_of("ast_node:parser_parse_10")
      assert q == "SELECT <-calls<-ast_node FROM ast_node:parser_parse_10"
    end
  end

  describe "callees_of/1" do
    test "builds outgoing calls traversal" do
      q = Query.callees_of("ast_node:parser_parse_10")
      assert q == "SELECT ->calls->ast_node FROM ast_node:parser_parse_10"
    end
  end

  describe "importers_of/1" do
    test "builds incoming imports traversal" do
      q = Query.importers_of("ast_node:parser_Enum_0")
      assert q == "SELECT <-imports<-ast_node FROM ast_node:parser_Enum_0"
    end
  end

  describe "imports_of/1" do
    test "builds outgoing imports traversal" do
      q = Query.imports_of("ast_node:parser_MyMod_0")
      assert q == "SELECT ->imports->ast_node FROM ast_node:parser_MyMod_0"
    end
  end

  describe "call_chain/2" do
    test "builds single-hop chain" do
      q = Query.call_chain("ast_node:a", 1)
      assert q == "SELECT ->calls->ast_node FROM ast_node:a"
    end

    test "builds multi-hop chain" do
      q = Query.call_chain("ast_node:a", 3)
      assert q == "SELECT ->calls->ast_node->calls->ast_node->calls->ast_node FROM ast_node:a"
    end
  end

  # ---------------------------------------------------------------------------
  # Search queries
  # ---------------------------------------------------------------------------

  describe "similar_to/2" do
    test "builds a native VECTOR SEARCH query" do
      q = Query.similar_to([0.1, 0.2, 0.3], limit: 5)
      assert q == "VECTOR SEARCH ast_node source_embedding [0.1, 0.2, 0.3] K 5"
    end

    test "includes kind filter as a WHERE scope" do
      q = Query.similar_to([0.1, 0.2], kind: "function_def")
      assert q =~ "VECTOR SEARCH ast_node source_embedding [0.1, 0.2]"
      assert q =~ "WHERE kind = 'function_def'"
    end

    test "combines multiple scope filters with AND" do
      q = Query.similar_to([0.1], kind: "function_def", project_path: "/p")
      assert q =~ "kind = 'function_def'"
      assert q =~ "project_path = '/p'"
      assert q =~ " AND "
    end
  end

  describe "search_source/2" do
    test "builds a native full-text SEARCH on source_text" do
      q = Query.search_source("async fn")
      assert q == "SEARCH ast_node source_text 'async fn' LIMIT 20"
    end

    test "includes kind filter as a WHERE scope" do
      q = Query.search_source("async fn", kind: "function_def")
      assert q =~ "SEARCH ast_node source_text 'async fn'"
      assert q =~ "WHERE kind = 'function_def'"
    end
  end

  describe "search_docs/2" do
    test "builds a native full-text SEARCH on docstring" do
      q = Query.search_docs("parses input")
      assert q == "SEARCH ast_node docstring 'parses input' LIMIT 20"
    end
  end

  describe "hybrid_search/3" do
    test "builds a native HYBRID SEARCH statement" do
      q = Query.hybrid_search("async fn", [0.1, 0.2], limit: 5)
      assert q =~ "HYBRID SEARCH ast_node TEXT source_text 'async fn'"
      assert q =~ "VECTOR source_embedding [0.1, 0.2]"
      assert q =~ "ALPHA 0.5"
      assert q =~ "LIMIT 5"
    end

    test "honours a custom alpha and scope filter" do
      q = Query.hybrid_search("async fn", [0.1, 0.2], alpha: 0.7, kind: "function_def")
      assert q =~ "ALPHA 0.7"
      assert q =~ "WHERE kind = 'function_def'"
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle queries
  # ---------------------------------------------------------------------------

  describe "delete_by_file/1" do
    test "builds a native DELETE ... WHERE by file_path" do
      q = Query.delete_by_file("/app/lib/parser.ex")
      assert q == "DELETE ast_node WHERE file_path = '/app/lib/parser.ex'"
    end
  end

  describe "delete_by_project/1" do
    test "builds a native DELETE ... WHERE by project_path" do
      q = Query.delete_by_project("/opt/myproject")
      assert q == "DELETE ast_node WHERE project_path = '/opt/myproject'"
    end
  end

  describe "stats_query/0" do
    test "builds a COUNT ... GROUP BY kind" do
      assert Query.stats_query() == "COUNT ast_node GROUP BY kind"
    end
  end

  describe "exec_delete_by_file/2" do
    test "returns the deleted count from a DeletedMany result" do
      fun = fn q ->
        assert q == "DELETE ast_node WHERE file_path = '/a.ex'"
        {:ok, %Dllb.Result.DeletedMany{count: 3}}
      end

      assert {:ok, 3} = Query.exec_delete_by_file("/a.ex", fun)
    end

    test "propagates query errors" do
      fun = fn _q -> {:ok, %Dllb.Result.Error{message: "boom"}} end
      assert {:error, {:query_error, "boom"}} = Query.exec_delete_by_file("/a.ex", fun)
    end
  end

  describe "exec_delete_by_project/2" do
    test "returns the deleted count from a DeletedMany result" do
      fun = fn q ->
        assert q == "DELETE ast_node WHERE project_path = '/p'"
        {:ok, %Dllb.Result.DeletedMany{count: 12}}
      end

      assert {:ok, 12} = Query.exec_delete_by_project("/p", fun)
    end
  end

  describe "exec_stats/1" do
    test "aggregates grouped COUNT rows into total and by_kind" do
      fun = fn q ->
        assert q == "COUNT ast_node GROUP BY kind"

        rows = [
          %{"kind" => %{"String" => "function_def"}, "count" => %{"Int" => 5}},
          %{"kind" => %{"String" => "container"}, "count" => %{"Int" => 2}}
        ]

        {:ok, %Dllb.Result.Rows{count: 2, data: rows}}
      end

      assert {:ok, %{total: 7, by_kind: by_kind}} = Query.exec_stats(fun)
      assert by_kind["function_def"] == 5
      assert by_kind["container"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Embeddings
  # ---------------------------------------------------------------------------

  describe "set_source_embedding/2" do
    test "builds UPDATE ... WHERE targeting by attributes" do
      q =
        Query.set_source_embedding(
          %{kind: "function_def", module: "MyApp", name: "parse", arity: 2},
          [0.1, 0.2]
        )

      assert q =~ "UPDATE ast_node SET source_embedding = [0.1, 0.2]"
      assert q =~ "kind = 'function_def'"
      assert q =~ "module = 'MyApp'"
      assert q =~ "name = 'parse'"
      assert q =~ "arity = 2"
    end

    test "drops nil attributes" do
      q = Query.set_source_embedding(%{kind: "container", name: "MyApp", module: nil}, [0.5])
      assert q =~ "kind = 'container'"
      assert q =~ "name = 'MyApp'"
      refute q =~ "module"
    end
  end

  describe "count_embeddings_query/0" do
    test "counts rows with a source_embedding set" do
      assert Query.count_embeddings_query() ==
               "COUNT ast_node WHERE source_embedding IS NOT NONE"
    end
  end

  describe "exec_count/2" do
    test "returns the count from a Count result" do
      fun = fn _q -> {:ok, %Dllb.Result.Count{count: 7}} end
      assert {:ok, 7} = Query.exec_count("COUNT ast_node", fun)
    end

    test "propagates query errors" do
      fun = fn _q -> {:ok, %Dllb.Result.Error{message: "boom"}} end
      assert {:error, {:query_error, "boom"}} = Query.exec_count("COUNT ast_node", fun)
    end
  end

  describe "exec_count_embeddings/1" do
    test "runs the embeddings count query" do
      fun = fn q ->
        assert q == "COUNT ast_node WHERE source_embedding IS NOT NONE"
        {:ok, %Dllb.Result.Count{count: 3}}
      end

      assert {:ok, 3} = Query.exec_count_embeddings(fun)
    end
  end

  # ---------------------------------------------------------------------------
  # Schema / MetaAST enhancements
  # ---------------------------------------------------------------------------

  describe "schema has new fields" do
    test "ast_node_table includes module, arity, visibility, project_path, docstring_embedding, ast_serialized" do
      stmts = Dllb.Schema.ast_node_table()
      fields_str = Enum.join(stmts, " ")
      assert fields_str =~ "DEFINE FIELD module ON ast_node"
      assert fields_str =~ "DEFINE FIELD arity ON ast_node"
      assert fields_str =~ "DEFINE FIELD visibility ON ast_node"
      assert fields_str =~ "DEFINE FIELD project_path ON ast_node"
      assert fields_str =~ "DEFINE FIELD docstring_embedding ON ast_node"
      assert fields_str =~ "DEFINE FIELD ast_serialized ON ast_node"
    end

    test "ast_node_indexes includes new btree indexes" do
      stmts = Dllb.Schema.ast_node_indexes()
      idx_str = Enum.join(stmts, " ")
      assert idx_str =~ "idx_module"
      assert idx_str =~ "idx_project_path"
      assert idx_str =~ "idx_file_kind"
    end
  end

  describe "to_dllb_document populates new fields" do
    test "includes module from context and serializes AST" do
      node = {:function_def, [name: "parse", line: 10, params: [{:param, [], "x"}]], []}
      ctx = %{language: :elixir, file_path: "/app/lib/p.ex", module: "MyModule"}
      doc = Dllb.MetaAST.to_dllb_document(node, ctx)

      assert doc.module == "MyModule"
      assert doc.arity == 1
      assert is_binary(doc.ast_serialized)
      assert doc.ast_serialized =~ "\"node_type\":\"FunctionDef\""
    end

    test "includes visibility from meta" do
      node = {:function_def, [name: "helper", line: 5, visibility: :private, params: []], []}
      ctx = %{language: :elixir, file_path: "/app/lib/p.ex"}
      doc = Dllb.MetaAST.to_dllb_document(node, ctx)

      assert doc.visibility == "private"
    end

    test "includes project_path from context" do
      node = {:container, [name: "MyMod", line: 1], []}
      ctx = %{language: :elixir, file_path: "/app/lib/p.ex", project_path: "/app"}
      doc = Dllb.MetaAST.to_dllb_document(node, ctx)

      assert doc.project_path == "/app"
      assert is_binary(doc.ast_serialized)
      assert doc.ast_serialized =~ "\"node_type\":\"Container\""
    end
  end

  describe "from_dllb_row handles new fields" do
    test "parses module, arity, visibility, project_path, docstring_embedding, ast_serialized, and query projections" do
      row = %{
        "id" => "ast_node:p_parse_10",
        "kind" => "function_def",
        "name" => "parse",
        "language" => "elixir",
        "file_path" => "/app/lib/p.ex",
        "module" => "MyModule",
        "arity" => 2,
        "visibility" => "public",
        "project_path" => "/app",
        "docstring_embedding" => [0.1, 0.2, 0.3],
        "ast_serialized" => "{\"node_type\":\"FunctionDef\"}",
        "similarity" => 0.95,
        "complexity" => 12,
        "ast_hash" => 42_523_523,
        "count" => 3
      }

      parsed = Dllb.MetaAST.from_dllb_row(row)

      assert parsed.module == "MyModule"
      assert parsed.arity == 2
      assert parsed.visibility == :public
      assert parsed.project_path == "/app"
      assert parsed.docstring_embedding == [0.1, 0.2, 0.3]
      assert parsed.ast_serialized == "{\"node_type\":\"FunctionDef\"}"
      assert parsed.similarity == 0.95
      assert parsed.complexity == 12
      assert parsed.ast_hash == 42_523_523
      assert parsed.count == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Query.upsert
  # ---------------------------------------------------------------------------

  describe "Query.upsert/3" do
    test "builds CREATE ... ON CONFLICT UPDATE" do
      q = Dllb.Query.upsert("ast_node", "p_parse_10", %{name: "parse", kind: "function_def"})
      assert q =~ "CREATE ast_node:p_parse_10 SET"
      assert q =~ "ON CONFLICT UPDATE"
    end
  end

  # ---------------------------------------------------------------------------
  # ingest_tree_queries
  # ---------------------------------------------------------------------------

  describe "ingest_tree_queries/2" do
    test "returns separate create and relate query lists" do
      tree =
        {:container, [name: "MyMod", line: 1],
         [
           {:function_def, [name: "hello", line: 3, params: []], []}
         ]}

      ctx = %{language: :elixir, file_path: "/app/lib/my_mod.ex"}
      {creates, relates} = Dllb.MetaAST.ingest_tree_queries(tree, ctx)

      assert [_, _] = creates
      assert [_, _] = relates
      assert Enum.all?(creates, &String.starts_with?(&1, "CREATE"))

      assert Enum.any?(relates, &String.starts_with?(&1, "RELATE"))
      assert Enum.any?(relates, &String.starts_with?(&1, "CREATE _edge_idx"))
    end
  end

  # ---------------------------------------------------------------------------
  # AST structural queries (server-side complexity, hash, and similarity)
  # ---------------------------------------------------------------------------

  describe "AST structural queries" do
    test "similar_by_ast/2 generates correct SELECT with ast::similarity" do
      target_node = {:function_def, [name: "hello", line: 3], []}
      q = Query.similar_by_ast(target_node, limit: 5, threshold: 0.9, language: "elixir")
      assert q =~ "SELECT id, name, ast::similarity(ast_serialized,"
      assert q =~ "AS similarity FROM ast_node"
      assert q =~ "WHERE language = 'elixir' AND ast::similarity(ast_serialized,"
      assert q =~ ") >= 0.9"
      assert q =~ "ORDER BY similarity DESC LIMIT 5"
    end

    test "complex_functions/2 generates correct SELECT with ast::complexity" do
      q = Query.complex_functions(8, limit: 3, project_path: "/app")
      assert q =~ "SELECT id, name, ast::complexity(ast_serialized) AS complexity FROM ast_node"
      assert q =~ "WHERE project_path = '/app' AND ast::complexity(ast_serialized) > 8"
      assert q =~ "ORDER BY complexity DESC LIMIT 3"
    end

    test "duplicate_code/1 generates correct SELECT with ast::hash" do
      q = Query.duplicate_code(kind: "function_def")
      assert q =~ "SELECT ast::hash(ast_serialized) AS ast_hash, COUNT() AS count FROM ast_node"
      assert q =~ "WHERE kind = 'function_def'"
      assert q =~ "GROUP BY ast_hash HAVING count > 1 ORDER BY count DESC LIMIT 20"
    end
  end
end
