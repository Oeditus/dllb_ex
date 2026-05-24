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
- **Query builder**—Composable functions for CREATE, SELECT, UPDATE, DELETE, RELATE, DEFINE TABLE/FIELD/INDEX statements.
- **Result structs**—Typed structs (`Ok`, `Created`, `Deleted`, `Rows`, `Error`) parsed from server responses.
- **Vector index support**—HNSW index definitions with configurable dimension and distance metric.
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

Dllb.Query.select("user", where: "age > 25", order: "name ASC", limit: 10)
# => "SELECT * FROM user WHERE age > 25 ORDER BY name ASC LIMIT 10"

Dllb.Query.relate("user:a", "follows", "user:b", %{since: "2024"})
# => "RELATE user:a->follows->user:b SET since = '2024'"
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

