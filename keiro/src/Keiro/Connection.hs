{- | Schema-resolution helpers for application read-model and projection tables.

Keiro's own framework tables live in the dedicated @keiro@ schema and its
runtime queries are fully qualified there. This module is about the /third/
layer: where an application's read-model /data/ tables live, and how the
application declares and reaches that location.

A PostgreSQL /schema/ is a namespace of tables inside one database. Because
Keiro opens its database pool through kiroku's connection settings — whose
@search_path@ starts with the event store's private @kiroku@ schema — an
unqualified @CREATE TABLE my_read_model (...)@ would land the table inside the
@kiroku@ event-store schema. To place it elsewhere, the application must
qualify at least its @CREATE TABLE@ as @schema.table@ (an unqualified create
always lands in the first @search_path@ entry). Qualifying the read/write SQL
too makes everything correct regardless of @search_path@ — the robust default.

This module gives applications exactly one convention:

* 'qualifyTable' builds a double-quoted, schema-qualified table reference to
  interpolate into projection SQL.
* 'withProjectionSchema' / 'keiroConnectionSettings' wire the store connection
  so a chosen projection schema also /resolves/ on the pool (via kiroku's
  @extraSearchPath@), for applications that also want unqualified SQL to work.
* 'ensureProjectionSchema' is an opt-in @CREATE SCHEMA IF NOT EXISTS@ helper for
  development, tests, and worked examples; Keiro never calls it automatically.

The kiroku store connection's @schema@ field stays @kiroku@ and is never
repointed: it also drives the @<schema>.events@ @LISTEN@/@NOTIFY@ channel, so
changing it would break subscription wake-ups. The projection schema is reached
only by qualification and\/or @extraSearchPath@.
-}
module Keiro.Connection (
    qualifyTable,
    quoteIdentifier,
    withProjectionSchema,
    keiroConnectionSettings,
    ensureProjectionSchema,
)
where

import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful (Eff, (:>))
import Keiro.Prelude
import Kiroku.Store.Connection (ConnectionSettings, defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | Build a double-quoted, schema-qualified table reference @"schema"."table"@,
doubling any embedded double quotes (the same identifier quoting kiroku uses).
Interpolate the result directly into projection SQL, e.g.

@
"SELECT ... FROM " <> qualifyTable "app" "orders" <> " WHERE ..."
@
-}
qualifyTable :: Text -> Text -> Text
qualifyTable schema table = quoteIdentifier schema <> "." <> quoteIdentifier table

{- | Double-quote a single SQL identifier, doubling any embedded double quotes
(the same identifier quoting kiroku uses). Useful for building qualified names
or a @CREATE SCHEMA "<name>"@ statement.
-}
quoteIdentifier :: Text -> Text
quoteIdentifier ident = "\"" <> T.replace "\"" "\"\"" ident <> "\""

{- | Append @projectionSchema@ to a settings value's @extraSearchPath@ so a
pooled connection can /resolve/ (read\/write) application tables in that schema.
Idempotent: the schema is appended only if not already present. The store's
@schema@ field is left untouched (stays @kiroku@).
-}
withProjectionSchema :: Text -> ConnectionSettings -> ConnectionSettings
withProjectionSchema projectionSchema settings =
    settings & #extraSearchPath %~ appendUnique projectionSchema
  where
    appendUnique s xs
        | s `elem` xs = xs
        | otherwise = xs <> [s]

{- | kiroku's default connection settings (@schema = "kiroku"@) with
@projectionSchema@ added to @extraSearchPath@, so unqualified application
data-manipulation SQL resolves on the store pool while the store @schema@ stays
@kiroku@ (honoring the NOTIFY-channel constraint). This does /not/ bake Keiro's
own @keiro@ schema into @extraSearchPath@: Keiro's runtime queries are already
fully qualified and must not depend on @search_path@.
-}
keiroConnectionSettings :: Text -> Text -> ConnectionSettings
keiroConnectionSettings connString projectionSchema =
    withProjectionSchema projectionSchema (defaultConnectionSettings connString)

{- | Run @CREATE SCHEMA IF NOT EXISTS "<schema>"@ in a transaction. This is
opt-in: Keiro never calls it automatically. Use it in development, tests, and
worked examples where the application (not a production migration tool) owns
schema creation.
-}
ensureProjectionSchema :: (Store :> es) => Text -> Eff es ()
ensureProjectionSchema projectionSchema =
    runTransaction $
        Tx.sql (TE.encodeUtf8 ("CREATE SCHEMA IF NOT EXISTS " <> quoteIdentifier projectionSchema))
