# Schema Migration

## Context: 
* ddl_facade.gleam
  - apply_ddl

## Current Behavior
* Inputs
  - Starting catalog
  - StruoQL source code
* Outputs
  - Revised catalog
  - Source code transpiled to PostgreSQL
  - OR, a language error

## Desired Behavior
* Inputs
  - Stream name
  - Starting catalog - must not include the named stream
  - List of SHA256 hash codes for migrations that have previously been 
    applied for the named schema in some external database.
  - StruoQL source code - one or more CREATE SCHEMA or ALTER SCHEMA statements in one long string
    All of the statements must apply to the same stream (the one named in the first parameter).
    The statements are a sequence of migration steps starting from the stream
    being nonexistent, so the first must be CREATE SCHEMA, and the rest must 
    be ALTER SCHEMA.
  * Outputs
    - Revised catalog, including the fully migrated stream with its full list of hash codes
    - PostgreSQL transpiled code for only the newly added migration steps
      not already included in the input hash code list.
    - OR, an existing language error or a new error: source code modified from prior 
      migrations (hash code mismatch)
      
## Migration Tracking
* To ensure that migrations are append-only a catalog now includes a list of
  SHA256 hash codes for each stream. Each hash code is a hash 
  of one input StruoQL schema definition statement, CREATE SCHEMA or ALTER SCHEMA.
* The hash code is generated from the AST of the statement so that white space
  changes do not change the hash. The hash does not include any trailing semicolon.
* The catalog.gleam type StreamSchema adds a field migration_hashes which 
  is a list of the SHA256 hash codes for the migrations of that stream.
* SHA256 hashes are computed using newly added module dependency gleam_crypto.