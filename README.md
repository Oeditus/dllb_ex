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
- **Query builder**—Composable functions for CREATE, SELECT, UPDATE, DELETE, RELATE, COUNT, upsert (`ON CONFLICT UPDATE [SET ...]`), DEFINE TABLE/FIELD, and DEFINE/REMOVE INDEX statements.
- **Result structs**—Typed structs (`Ok`, `Created`, `Deleted`, `Rows`, `Count`, `Update`, `Batch`, `Communities`, `Components`, `Error`) parsed from server responses.
- **Secondary indexes**—Persisted single- and multi-field (composite) index definitions with optional `UNIQUE` constraints. Equality and range filters on indexed fields are transparently accelerated by the engine.
- **Full-text & vector search**—`DEFINE FULLTEXT INDEX` (BM25/Tantivy) and `DEFINE VECTOR INDEX` (HNSW) creation, plus `SEARCH` and `VECTOR SEARCH` query builders.
- **MetaAST bridge**—Serialization between Metastatic AST 3-tuples and dllb documents/edges, including bulk tree ingestion.
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
  pool_size: 5,
  outcome: :json,
  timeout: 30_000
```

Setting `enabled: false` (the default) starts the application without the
connection pool, which is useful for compile-time or test environments where
no dllb server is available.

### Options

- `:host`—server hostname or IP (default `"127.0.0.1"`)
- `:port`—server port (default `3009`)
- `:pool_size`—number of persistent TCP connections (default `5`)
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
queried with the `SEARCH` and `VECTOR SEARCH` verbs. Both require a dllb
server with search services enabled (the default server build).

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
```

Valid analyzers: `default`, `simple`, `english`, `spanish`, `french`,
`german`, `italian`, `portuguese`, `russian`. Valid metrics: `cosine`,
`euclidean` (alias `l2`), `dot` (alias `dotproduct`/`dot_product`).

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

## Modules

- `Dllb`—top-level query interface (`query/1`, `query!/1`)
- `Dllb.Connection`—raw TCP socket operations (connect, query, close, alive?)
- `Dllb.Pool`—NimblePool connection pool with dead-socket detection
- `Dllb.Protocol`—wire format encoding/decoding (line-based text over TCP)
- `Dllb.Query`—query string builder for all dllb statement types
- `Dllb.Result`—typed structs for parsed server responses
- `Dllb.Schema`—declarative schema bootstrap (DEFINE TABLE/FIELD/INDEX)
- `Dllb.MetaAST`—Metastatic AST serialization and bulk ingestion
- `Dllb.Error`—exception struct with typed error classification

## Documentation

[hexdocs.pm/dllb](https://hexdocs.pm/dllb)

## Credits

Created as part of the [Oeditus](https://oeditus.com) code quality tooling ecosystem.

## License

MIT

