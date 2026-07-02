-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database.
SET search_path TO kiroku, pg_catalog;

-- keiro_inbox_received_idx served only the listInbox test helper's ordering
-- but was maintained on every consumed message. Retention GC uses
-- keiro_inbox_completed_idx; the backlog gauge uses keiro_inbox_backlog_idx.
DROP INDEX IF EXISTS keiro_inbox_received_idx;
