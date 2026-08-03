# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.4] - 2026-08-03

Aligns the client with the dllb engine's native `ast::diff`, `ast::scope`,
and `ast::clones` SQL functions (Code Intel Improvements).

### Added

- `Dllb.MetaAST.Query.ast_diff/2` builds a `SELECT` using the server-side
  `ast::diff(ast_serialized, target)` function, the engine-side counterpart
  to the purely client-side `Dllb.MetaAST.Diff.diff_trees/2`. Each result
  row carries a JSON-encoded `diff` summary (`changes`/`added`/`removed`/
  `modified`/`renamed`).
- `Dllb.MetaAST.Query.ast_scope/2` builds a `SELECT` using the server-side
  `ast::scope(ast_serialized, line)` function against a single AST node
  record, the engine-side counterpart to
  `Dllb.MetaAST.QueryHelpers.scope_at/2`.
- `Dllb.MetaAST.Query.ast_clones/2` builds a `SELECT` using the server-side
  `ast::clones(asts, threshold)` function, the engine-side counterpart to
  `Dllb.MetaAST.Similarity.find_clones/2`.

## [0.7.0] - 2026-06-13

Extends the client to cover the engine's new query-layer features: scoped
search, server-side aggregation and deletion, hybrid search, and graph
analytics verbs.

### Added

- `Dllb.Query.search/4` and `Dllb.Query.vector_search/4` accept a `:where`
  option that scopes ranked hits server-side (`SEARCH ... WHERE ... LIMIT`,
  `VECTOR SEARCH ... WHERE ... K`).
- `Dllb.Query.count/2` accepts a `:group_by` option, building
  `COUNT <table> [WHERE ...] GROUP BY <field>`. Grouped counts come back as a
  `Dllb.Result.Rows`, one row per distinct value with a `count`.
- `Dllb.Query.delete_where/2` builds `DELETE <table> [WHERE ...]`, removing
  every matching row server-side in a single operation (engine-maintained
  secondary, full-text, and vector indexes).
- `Dllb.Query.hybrid_search/6` builds
  `HYBRID SEARCH <table> TEXT <field> '<q>' VECTOR <field> [..] [ALPHA a] [WHERE ..] [LIMIT n]`,
  fusing BM25 and HNSW scores. Each row carries `score`, `text_score`, and
  `vector_score`.
- Graph analytics verbs: `Dllb.Query.graph_pagerank/2` (`DAMPING` / `MAX_ITER`
  / `LIMIT`), `Dllb.Query.graph_centrality/2` (`:degree` / `:indegree` /
  `:outdegree`, `LIMIT`), `Dllb.Query.graph_path/4`
  (`GRAPH PATH <src> -> <dst> ON <table> [MAX_DEPTH n]`), and
  `Dllb.Query.graph_edges/2` (`GRAPH EDGES <table> [WHERE ...]`, surfacing the
  stored edge `weight`, default `1.0`).
- `Dllb.Result.DeletedMany` struct, parsed from `{"status":"deleted_many"}`,
  reporting the number of rows removed by `DELETE ... WHERE`.

### Changed

- `Dllb.MetaAST.Query` now builds on the native verbs instead of the previous
  client-side workarounds:
  - `similar_to/2`, `search_source/2`, `search_docs/2`, and `hybrid_search/3`
    emit `VECTOR SEARCH` / `SEARCH` / `HYBRID SEARCH`, with optional `:kind` /
    `:file_path` / `:language` / `:project_path` scope filters for
    multi-project isolation.
  - `delete_by_file/1` and `delete_by_project/1` build a single
    `DELETE ... WHERE`; `exec_delete_by_file/2` and `exec_delete_by_project/2`
    issue one statement and read the deleted count from `DeletedMany`
    (previously a SELECT followed by N point deletes).
  - `stats_query/0` builds `COUNT ast_node GROUP BY kind`; `exec_stats/1`
    reads the grouped rows server-side instead of aggregating client-side.

### Removed

- BREAKING: `Dllb.MetaAST.Query.delete_by_file_select/1` is removed. Use the
  native `delete_by_file/1` (or `exec_delete_by_file/2`) instead.

## [0.6.0] - 2026-06-13

Adds client support for the engine's full-text (Tantivy/BM25) and vector
(HNSW) index creation and search, now wired into the query layer.

### Added

- `Dllb.Query.define_fulltext_index/4` builds
  `DEFINE FULLTEXT INDEX <name> ON TABLE <table> FIELDS <field> [ANALYZER <a>]`,
  with an optional `:analyzer` (`default`, `simple`, or a language).
- `Dllb.Query.define_vector_index/5` builds
  `DEFINE VECTOR INDEX <name> ON TABLE <table> FIELDS <field> DIMENSION <n> [METRIC <m>]`,
  with an optional `:metric` (`cosine`, `euclidean`/`l2`, or `dot`).
- `Dllb.Query.search/4` builds `SEARCH <table> <field> '<query>' [LIMIT n]`
  (BM25 full-text). Results are rows ranked best-first, each with a `score`.
- `Dllb.Query.vector_search/4` builds
  `VECTOR SEARCH <table> <field> [v, ...] [K n]` (approximate KNN). Results are
  rows ordered nearest-first, each with a `distance`.
- `Dllb.Schema.ast_node_search_indexes/0` defines the full-text indexes on
  `source_text`/`docstring` and the vector indexes on
  `source_embedding` (768, cosine) / `structure_embedding` (384, cosine).

### Changed

- `Dllb.Schema.all_statements/0` now also emits the full-text and vector
  search index definitions, so `bootstrap/1` provisions them. These require a
  dllb server with search services enabled (the default server build).

## [0.5.0] - 2026-06-13

Synchronizes the client with the dllb engine's persisted secondary-index
catalog and related query features.

### Added

- `Dllb.Query.define_index/4` builds the engine's catalog-backed secondary
  index DDL: `DEFINE INDEX <name> ON TABLE <table> FIELDS <field>[, ...]`.
  It supports composite (multi-field) indexes with leftmost-prefix planning
  and an optional `unique: true` constraint over the full indexed tuple.
- `Dllb.Query.remove_index/2` builds `REMOVE INDEX <name> ON TABLE <table>`.
- `Dllb.Query.upsert/4` accepts an explicit `update_fields` map, emitting
  `CREATE ... ON CONFLICT UPDATE SET <update_fields>`. The existing
  `upsert/3` behavior is unchanged.

### Changed

- `Dllb.Schema.ast_node_indexes/0` now emits the new secondary-index DDL and
  defines `idx_kind`, `idx_language`, `idx_file_path`, `idx_module`,
  `idx_project_path`, and the composite `idx_file_kind` on `file_path, kind`.
- Equality and range predicates on indexed fields are now transparently
  accelerated by the engine; no client query changes are required to benefit.

### Removed

- BREAKING: the typed `Dllb.Query.define_index/5` variants (`:btree`,
  `:fulltext`, `:hnsw`) are removed. They generated DDL
  (`SEARCH ANALYZER ...`, `HNSW DIMENSION ... DIST ...`) that the current
  engine parser rejects. Use `define_index/4` for secondary indexes.
- `Dllb.Schema.ast_node_indexes/0` no longer emits the non-functional HNSW
  (`idx_source_embedding`, `idx_structure_embedding`) and full-text
  (`idx_source_text`, `idx_docstring`) index definitions, because vector and
  full-text index creation are not exposed by the engine's query protocol.
