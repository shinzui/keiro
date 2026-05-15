module Keiro.ReadModel.Rebuild
  ( rebuild
  , promote
  , abandonRebuild
  )
where

import Effectful (Eff, (:>))
import Keiro.Prelude
import Keiro.ReadModel
import Kiroku.Store.Effect (Store)

rebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
rebuild readModel =
  markRebuilding
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)

promote :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
promote readModel =
  markLive
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)

abandonRebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
abandonRebuild readModel =
  markAbandoned
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)
