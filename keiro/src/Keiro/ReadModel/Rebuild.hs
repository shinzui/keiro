{- | The read-model rebuild lifecycle, expressed over a 'ReadModel'.

Thin, type-safe wrappers over the status transitions in
"Keiro.ReadModel.Schema" that take a whole 'ReadModel' and thread its
'name', 'version', and 'shapeHash' through for you. The intended sequence
when reshaping a projection is: 'rebuild' to take it offline, repopulate the
table from the event log, then 'promote' to serve it again — or
'abandonRebuild' to back out. While a model is rebuilding,
'Keiro.ReadModel.runQuery' rejects it with 'ReadModelNotLive'.

Operator runbook for an offline rebuild:

1. Stop or pause every worker that writes the read model's table. The helpers
   here do not coordinate workers for you.
2. Call 'rebuild'. This records the current schema identity with status
   'Rebuilding', so normal queries fail closed instead of serving a half-built
   table.
3. In the database, truncate or otherwise clear the projection table and reset
   the subscription checkpoint that feeds it to the replay position you intend
   to rebuild from.
4. Replay the event log through the projection code until it catches up to the
   current store head. Verify row counts, spot-check representative queries,
   and compare the subscription checkpoint with the store head.
5. Call 'promote' only after verification succeeds, then resume workers. If
   verification fails, call 'abandonRebuild' and keep the model offline until
   the data is repaired or restored.

This is deliberately an offline procedure. Keiro does not yet provide a
shadow-table or online cutover mechanism; applications that need zero-downtime
rebuilds must build that orchestration above this lifecycle API.
-}
module Keiro.ReadModel.Rebuild (
    rebuild,
    promote,
    abandonRebuild,
)
where

import Effectful (Eff, (:>))
import Keiro.Prelude
import Keiro.ReadModel
import Kiroku.Store.Effect (Store)

{- | Mark a model 'Rebuilding', taking it out of service while it is
repopulated from the event log.
-}
rebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
rebuild readModel =
    markRebuilding
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)

-- | Mark a rebuilt model 'Live', returning it to service.
promote :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
promote readModel =
    markLive
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)

-- | Mark a model 'Abandoned', backing out of an in-progress rebuild.
abandonRebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
abandonRebuild readModel =
    markAbandoned
        (readModel ^. #name)
        (readModel ^. #version)
        (readModel ^. #shapeHash)
