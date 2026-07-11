-- keiro_inbox_received_idx served only the listInbox test helper's ordering
-- but was maintained on every consumed message. Retention GC uses
-- keiro_inbox_completed_idx; the backlog gauge uses keiro_inbox_backlog_idx.
DROP INDEX IF EXISTS keiro.keiro_inbox_received_idx;
