// A TypeScript port of `domain/shared/src/lang/catalog.gleam`'s
// `migration_history_table_name`/`pending_aggregations_table_name` —
// both are plain, deterministic string functions with no Gleam-side
// state involved, so every TypeScript package that needs one of these
// names (schema-migration, event-creation, event-delivery,
// event-obsolescence) imports it from here rather than re-deriving the
// suffix itself. `domain/shared/src/lang/catalog.gleam` stays the
// definition of record — see
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 8's note on why this is a port rather than a Gleam call for a
// plain string computation.

export function migrationHistoryTableName(stream: string): string {
  return `_struo_${stream}_migration_history`;
}

export function pendingAggregationsTableName(stream: string): string {
  return `_struo_${stream}_pending_aggregations`;
}
