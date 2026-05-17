module Jitsurei.Database
  ( initializeJitsureiTables
  , initializeOrderSummaryTable
  )
where

import Effectful (Eff, (:>))
import Keiro.ReadModel (initializeReadModelSchema)
import Keiro.Snapshot (initializeSnapshotSchema)
import Keiro.Timer (initializeTimerSchema)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Jitsurei.ReadModels (initializeOrderSummaryTable)

initializeJitsureiTables :: (Store :> es) => Eff es ()
initializeJitsureiTables = do
  initializeSnapshotSchema
  initializeReadModelSchema
  initializeTimerSchema
  runTransaction initializeOrderSummaryTable
