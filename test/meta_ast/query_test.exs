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
    test "builds HNSW KNN query" do
      q = Query.similar_to([0.1, 0.2, 0.3], limit: 5)
      assert q =~ "source_embedding <|5,100|>"
      assert q =~ "LIMIT 5"
      assert q =~ "vector::distance::knn() AS score"
    end

    test "includes kind filter" do
      q = Query.similar_to([0.1, 0.2], kind: "function_def")
      assert q =~ "kind = 'function_def'"
    end
  end

  describe "search_source/2" do
    test "builds full-text query on source_text" do
      q = Query.search_source("async fn")
      assert q =~ "source_text @@ 'async fn'"
      assert q =~ "search::score(1) AS score"
    end

    test "includes kind filter" do
      q = Query.search_source("async fn", kind: "function_def")
      assert q =~ "kind = 'function_def'"
    end
  end

  describe "search_docs/2" do
    test "builds full-text query on docstring" do
      q = Query.search_docs("parses input")
      assert q =~ "docstring @@ 'parses input'"
    end
  end

  describe "hybrid_search/3" do
    test "builds combined vector + full-text query" do
      q = Query.hybrid_search("async fn", [0.1, 0.2], limit: 5)
      assert q =~ "source_embedding <|"
      assert q =~ "source_text @@ 'async fn'"
      assert q =~ "vec_score"
      assert q =~ "ft_score"
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle queries
  # ---------------------------------------------------------------------------

  describe "delete_by_file_select/1" do
    test "builds SELECT for ids by file_path" do
      q = Query.delete_by_file_select("/app/lib/parser.ex")
      assert q =~ "SELECT id FROM ast_node"
      assert q =~ "file_path = '/app/lib/parser.ex'"
    end
  end

  describe "stats_query/0" do
    test "builds SELECT for id and kind" do
      q = Query.stats_query()
      assert q =~ "SELECT id, kind FROM ast_node"
    end
  end

  # ---------------------------------------------------------------------------
  # Schema / MetaAST enhancements
  # ---------------------------------------------------------------------------

  describe "schema has new fields" do
    test "ast_node_table includes module, arity, visibility, project_path" do
      stmts = Dllb.Schema.ast_node_table()
      fields_str = Enum.join(stmts, " ")
      assert fields_str =~ "DEFINE FIELD module ON ast_node"
      assert fields_str =~ "DEFINE FIELD arity ON ast_node"
      assert fields_str =~ "DEFINE FIELD visibility ON ast_node"
      assert fields_str =~ "DEFINE FIELD project_path ON ast_node"
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
    test "includes module from context" do
      node = {:function_def, [name: "parse", line: 10, params: [{:param, [], "x"}]], []}
      ctx = %{language: :elixir, file_path: "/app/lib/p.ex", module: "MyModule"}
      doc = Dllb.MetaAST.to_dllb_document(node, ctx)

      assert doc.module == "MyModule"
      assert doc.arity == 1
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
    end
  end

  describe "from_dllb_row handles new fields" do
    test "parses module, arity, visibility, project_path" do
      row = %{
        "id" => "ast_node:p_parse_10",
        "kind" => "function_def",
        "name" => "parse",
        "language" => "elixir",
        "file_path" => "/app/lib/p.ex",
        "module" => "MyModule",
        "arity" => 2,
        "visibility" => "public",
        "project_path" => "/app"
      }

      parsed = Dllb.MetaAST.from_dllb_row(row)

      assert parsed.module == "MyModule"
      assert parsed.arity == 2
      assert parsed.visibility == :public
      assert parsed.project_path == "/app"
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
end
