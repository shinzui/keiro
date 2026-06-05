module Jitsurei.Database (
    initializeJitsureiTables,
    initializeOrderSummaryTable,
)
where

import Effectful (Eff, (:>))
import Jitsurei.ReadModels (initializeOrderSummaryTable)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

{- | Create Jitsurei-owned tables.

The Keiro framework tables (snapshots, read models, timers) are owned by
@keiro-migrations@ and are applied separately — by @keiro-migrate@ in
production and by the migrated template database in tests. This helper
creates only the application-owned read-model tables.
-}
initializeJitsureiTables :: (Store :> es) => Eff es ()
initializeJitsureiTables =
    runTransaction initializeOrderSummaryTable
