<img src="https://raw.githubusercontent.com/Oeditus/dllb_ex/main/logo-128x128.png" alt="Dllb" width="128" align="right">

# dllb

**Elixir client for the [`dllb`](https://github.com/Oeditus/dllb) multi-model NoSQL database**

[![Hex.pm](https://img.shields.io/hexpm/v/dllb.svg)](https://hex.pm/packages/dllb)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/dllb)

Dllb provides a high-level Elixir API for communicating with the
[dllb](https://github.com/Oeditus/dllb) database over TCP. It manages a
`NimblePool`-based connection pool, speaks the dllb line-based wire protocol,
and exposes a query builder plus result parsing so your application can focus
on data rather than sockets.

## Features

- **Connection pooling**—NimblePool-managed TCP sockets with automatic reconnection on dead connections.
- **Wire protocol**—Line-based text over TCP; supports JSON, toon, and CSV response formats.
- **Query builder**—Composable functions for CREATE, SELECT (with `ORDER BY`), UPDATE, DELETE (point and `DELETE ... WHERE`), RELATE, COUNT (with `GROUP BY`), upsert (`ON CONFLICT UPDATE [SET ...]`), DEFINE TABLE/FIELD, DEFINE/REMOVE INDEX, full-text/vector/hybrid search, and graph analytics (COMMUNITIES, COMPONENTS, PAGERANK, CENTRALITY, PATH, EDGES) statements.
- **Result structs**—Typed structs (`Ok`, `Created`, `Deleted`, `DeletedMany`, `Rows`, `Count`, `Update`, `Batch`, `Communities`, `Components`, `Error`) parsed from server responses.
- **Secondary indexes**—Persisted single- and multi-field (composite) index definitions with optional `UNIQUE` constraints. Equality and range filters on indexed fields are transparently accelerated by the engine.
- **Full-text & vector search**—`DEFINE FULLTEXT INDEX` (BM25/Tantivy) and `DEFINE VECTOR INDEX` (HNSW) creation, plus `SEARCH`, `VECTOR SEARCH`, and `HYBRID SEARCH` query builders with optional server-side `WHERE` scoping.
- **MetaAST bridge**—Serialization between Metastatic AST 3-tuples and dllb documents/edges, including bulk tree ingestion and incremental (diff-based) re-indexing.
- **AST structural analysis**—Server-side (native Rust) `ast::similarity`, `ast::complexity`, `ast::hash`, `ast::diff`, `ast::scope`, and `ast::clones` SQL functions, each with pure-Elixir, round-trip-free client-side counterparts for offline/no-server use.
- **Schema bootstrap**—Declarative schema definitions executed through any query function.
- **OTP-ready**—Application supervision tree with opt-in pool startup via `config :dllb, enabled: true`.

## Installation

Add `dllb` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dllb, "~> 0.1.0"}
  ]
end
```

## Configuration

```elixir
# config/config.exs
config :dllb,
  enabled: true,
  host: "127.0.0.1",
  port: 3009,
  pool_size: 30,
  outcome: :json,
  timeout: 30_000
```

Setting `enabled: false` (the default) starts the application without the
connection pool, which is useful for compile-time or test environments where
no dllb server is available.

### Options

- `:host`—server hostname or IP (default `"127.0.0.1"`)
- `:port`—server port (default `3009`)
- `:pool_size`—number of persistent TCP connections (default `30`)
- `:outcome`—response format: `:json`, `:toon`, or `:csv` (default `:json`)
- `:timeout`—connection and receive timeout in milliseconds (default `30_000`)

## Usage

### Basic queries

```elixir
{:ok, %Dllb.Result.Rows{count: 3, data: rows}} = Dllb.query("SELECT * FROM users")

result = Dllb.query!("SELECT * FROM users WHERE age > 25")
```

### Query builder

```elixir
Dllb.Query.create("user", %{name: "Alice", age: 30})
# => "CREATE user SET age = 30, name = 'Alice'"

Dllb.Query.select("user", where: "age > 25", limit: 10)
# => "SELECT * FROM user WHERE age > 25 LIMIT 10"

Dllb.Query.relate("user:a", "follows", "user:b", %{since: "2024"})
# => "RELATE user:a->follows->user:b SET since = '2024'"
```

### Secondary indexes

```elixir
# Single-field secondary index.
Dllb.Query.define_index("user", "by_age", ["age"])
# => "DEFINE INDEX by_age ON TABLE user FIELDS age"

# Composite index (leftmost-prefix planning: list the leading field first).
Dllb.Query.define_index("ast_node", "idx_file_kind", ["file_path", "kind"])
# => "DEFINE INDEX idx_file_kind ON TABLE ast_node FIELDS file_path, kind"

# Unique constraint over the full indexed tuple.
Dllb.Query.define_index("user", "by_email", ["email"], unique: true)
# => "DEFINE INDEX by_email ON TABLE user FIELDS email UNIQUE"

# Drop an index (queries then fall back to full scans).
Dllb.Query.remove_index("user", "by_age")
# => "REMOVE INDEX by_age ON TABLE user"
```

Once an index exists, no query changes are required: `SELECT`, `COUNT`, and
`UPDATE` statements whose `WHERE` clause has equality or range predicates on
indexed fields are accelerated automatically.

### Full-text and vector search

Full-text (BM25) and vector (HNSW) indexes are created over the wire and
queried with the `SEARCH`, `VECTOR SEARCH`, and `HYBRID SEARCH` verbs, each
accepting an optional server-side `WHERE` scope. All require a dllb server
with search services enabled (the default server build).

```elixir
# Define a full-text index (optionally with a language analyzer).
Dllb.Query.define_fulltext_index("article", "ft_body", "body", analyzer: "english")
# => "DEFINE FULLTEXT INDEX ft_body ON TABLE article FIELDS body ANALYZER english"

# BM25 search; each row carries a "score" field, best-first.
Dllb.Query.search("article", "body", "graph database", limit: 5)
# => "SEARCH article body 'graph database' LIMIT 5"

# Define a vector (HNSW) index over a dense embedding field.
Dllb.Query.define_vector_index("ast_node", "vec_src", "source_embedding", 768, metric: "cosine")
# => "DEFINE VECTOR INDEX vec_src ON TABLE ast_node FIELDS source_embedding DIMENSION 768 METRIC cosine"

# Approximate nearest-neighbour search; each row carries a "distance" field.
Dllb.Query.vector_search("ast_node", "source_embedding", [0.12, 0.07, 0.91], k: 10)
# => "VECTOR SEARCH ast_node source_embedding [0.12, 0.07, 0.91] K 10"

# Scope results server-side (multi-project isolation, kind/language filters).
Dllb.Query.vector_search("ast_node", "source_embedding", [0.12, 0.07],
  where: "project_path = '/app'",
  k: 10
)
# => "VECTOR SEARCH ast_node source_embedding [0.12, 0.07] WHERE project_path = '/app' K 10"

# Hybrid search fuses BM25 and HNSW; rows carry score, text_score, vector_score.
Dllb.Query.hybrid_search("ast_node", "source_text", "parse tokens", "source_embedding", [0.12, 0.07],
  alpha: 0.6,
  limit: 10
)
# => "HYBRID SEARCH ast_node TEXT source_text 'parse tokens' VECTOR source_embedding [0.12, 0.07] ALPHA 0.6 LIMIT 10"
```

Valid analyzers: `default`, `simple`, `english`, `spanish`, `french`,
`german`, `italian`, `portuguese`, `russian`. Valid metrics: `cosine`,
`euclidean` (alias `l2`), `dot` (alias `dotproduct`/`dot_product`).

### Aggregation, deletion, and graph analytics

```elixir
# Grouped COUNT: one row per kind, each with a count (best-first).
Dllb.Query.count("ast_node", group_by: "kind")
# => "COUNT ast_node GROUP BY kind"

# Server-side delete-by-predicate (engine maintains all indexes).
Dllb.Query.delete_where("ast_node", "file_path = '/app/lib/old.ex'")
# => "DELETE ast_node WHERE file_path = '/app/lib/old.ex'"

# Weighted PageRank over an edge table, top-N by score.
Dllb.Query.graph_pagerank("calls", damping: 0.85, limit: 20)
# => "GRAPH PAGERANK calls DAMPING 0.85 LIMIT 20"

# Degree centrality (also :indegree / :outdegree).
Dllb.Query.graph_centrality("calls", mode: :indegree, limit: 20)
# => "GRAPH CENTRALITY calls INDEGREE LIMIT 20"

# Shortest directed path between two vertices.
Dllb.Query.graph_path("a", "b", "calls", max_depth: 6)
# => "GRAPH PATH a -> b ON calls MAX_DEPTH 6"

# List edges with their stored weights (default 1.0).
Dllb.Query.graph_edges("calls", where: "weight > 0.5")
# => "GRAPH EDGES calls WHERE weight > 0.5"
```

### Upserts

```elixir
# Insert, or merge the same fields on conflict.
Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30})
# => "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE"

# Insert, or apply explicit fields on conflict.
Dllb.Query.upsert("user", "u1", %{name: "Alice", age: 30}, %{age: 31})
# => "CREATE user:u1 SET age = 30, name = 'Alice' ON CONFLICT UPDATE SET age = 31"
```

### Schema bootstrap

```elixir
{:ok, :bootstrapped} = Dllb.Schema.bootstrap(&Dllb.query/1)
```

### MetaAST ingestion

```elixir
context = %{language: :elixir, file_path: "/app/lib/parser.ex"}
{:ok, %{nodes: 42, edges: 17}} = Dllb.MetaAST.ingest_tree(ast, context, &Dllb.query/1)
```

### AST structural queries (native code-intel)

`Dllb.MetaAST.Query` exposes the engine's native (Rust) structural AST SQL
functions -- `ast::similarity`, `ast::complexity`, `ast::hash`, `ast::diff`,
and `ast::scope` -- as query builders that scan and compare the
already-stored `ast_serialized` column, without fetching every tree back to
the client for comparison. `ast::clones` instead compares a list of ASTs you
supply directly (see its docs for the caveats this implies).

```elixir
alias Dllb.MetaAST.Query, as: ASTQuery

# Fuzzy structural similarity against a target AST (3-tuple or JSON string).
ASTQuery.similar_by_ast(target_node, threshold: 0.85, limit: 10)

# Cyclomatic complexity above a threshold.
ASTQuery.complex_functions(10, limit: 10)

# Exact structural (Zobrist-hash) duplicate groups.
ASTQuery.duplicate_code(kind: "function_def")

# Structural diff of every stored node against a target tree; each row's
# `diff` field is a JSON-encoded summary (changes/added/removed/modified/renamed).
ASTQuery.ast_diff(target_node, limit: 5)

# Scope path (outermost to innermost) containing a line, within one record.
ASTQuery.ast_scope("ast_node:MyMod_parse_2", 42)

# Fuzzy clone pairs across a list of ASTs (requires at least one `ast_node` row
# to anchor the query's mandatory FROM clause).
ASTQuery.ast_clones([ast_a, ast_b, ast_c], threshold: 0.9)
```

Each native function has a purely client-side, round-trip-free Elixir
counterpart, useful when no server is available or when comparing ASTs that
aren't (yet) persisted:

| Native (server-side)                  | Client-side (pure Elixir)                |
| -------------------------------------- | ----------------------------------------- |
| `ast::similarity` / `similar_by_ast/2` | `Dllb.MetaAST.Similarity.structural_similarity/2` |
| `ast::hash` / `duplicate_code/1`       | `Dllb.MetaAST.Similarity.subtree_hash/1`  |
| `ast::clones` / `ast_clones/2`         | `Dllb.MetaAST.Similarity.find_clones/2`   |
| `ast::diff` / `ast_diff/2`             | `Dllb.MetaAST.Diff.diff_trees/2`          |
| `ast::scope` / `ast_scope/2`           | `Dllb.MetaAST.QueryHelpers.scope_at/2`    |

> [!NOTE]
> The client-side `Dllb.MetaAST.Diff.diff_trees/2` (and `ast::diff` in turn)
> compares node *type* and *children* structurally but ignores each node's
> `meta` keyword list. Renames and changes confined to metadata (e.g. a call
> target's name) are therefore detected as structural matches, not as
> `:modified` changes -- diff at the granularity of shape, not identifiers.

Incremental re-indexing combines a diff with `Dllb.MetaAST.Ingest`, so only
changed entities are re-embedded and re-inserted:

```elixir
diff = Dllb.MetaAST.Diff.diff_trees(old_ast, new_ast)
queries = Dllb.MetaAST.Ingest.incremental_queries(new_ast, diff, "/app/lib/parser.ex", "elixir")
Dllb.batch(queries)
```

## Modules

- `Dllb`—top-level query interface (`query/1`, `query!/1`)
- `Dllb.Connection`—raw TCP socket operations (connect, query, close, alive?)
- `Dllb.Pool`—NimblePool connection pool with dead-socket detection
- `Dllb.Protocol`—wire format encoding/decoding (line-based text over TCP)
- `Dllb.Query`—query string builder for all dllb statement types
- `Dllb.Result`—typed structs for parsed server responses
- `Dllb.Schema`—declarative schema bootstrap (DEFINE TABLE/FIELD/INDEX)
- `Dllb.MetaAST`—Metastatic AST serialization and bulk ingestion
- `Dllb.MetaAST.Query`—domain query builder for `ast_node`, including native (server-side) structural AST functions
- `Dllb.MetaAST.Ingest`—batch and incremental (diff-based) ingestion pipeline
- `Dllb.MetaAST.Diff`—pure-Elixir, client-side structural AST diff (no round-trip)
- `Dllb.MetaAST.Similarity`—pure-Elixir, client-side structural similarity, fingerprinting, and clone detection
- `Dllb.MetaAST.QueryHelpers`—pure-Elixir, client-side tree navigation (ancestors, scope, call targets, complexity)
- `Dllb.MetaAST.NodeTypes`—MetaAST node-type <-> dllb `kind` conversions
- `Dllb.Error`—exception struct with typed error classification

## Documentation

[hexdocs.pm/dllb](https://hexdocs.pm/dllb)

## Credits

Created as part of the [Oeditus](https://oeditus.com) code quality tooling ecosystem.

## License

MIT

