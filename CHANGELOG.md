# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
