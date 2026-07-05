{- | The single source of truth for the name of the dedicated PostgreSQL schema
that owns all of Keiro's framework tables.

A PostgreSQL /schema/ is a namespace inside one database. Keiro's framework
tables (@keiro_snapshots@, @keiro_timers@, @keiro_outbox@, …) live in the schema
named by 'keiroSchema'. The migrations in @keiro-migrations@ create them
schema-qualified (@keiro.<table>@); runtime queries in the @keiro@ package
qualify against this same name. This is the literal string every part of the
system must agree on, so it is defined once here and imported elsewhere.
-}
module Keiro.Schema (keiroSchema) where

import Data.Text (Text)

-- | The schema that owns Keiro's framework tables: @"keiro"@.
keiroSchema :: Text
keiroSchema = "keiro"
