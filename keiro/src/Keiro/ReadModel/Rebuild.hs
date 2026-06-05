{- | The read-model rebuild lifecycle, expressed over a 'ReadModel'.

Thin, type-safe wrappers over the status transitions in
"Keiro.ReadModel.Schema" that take a whole 'ReadModel' and thread its
'name', 'version', and 'shapeHash' through for you. The intended sequence
when reshaping a projection is: 'rebuild' to take it offline, repopulate the
table from the event log, then 'promote' to serve it again — or
'abandonRebuild' to back out. While a model is rebuilding,
'Keiro.ReadModel.runQuery' rejects it with 'ReadModelNotLive'.
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
