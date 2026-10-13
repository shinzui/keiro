module HistoryDependentHoles.Assignment.BehaviorHoles (behaviorWitnesses) where

import Data.List.NonEmpty (NonEmpty (..))
import Generated.HistoryDependentHoles.Assignment.BehaviorContract
import Generated.HistoryDependentHoles.Assignment.Domain

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ LiveWitness (BehaviorKey "behavior-v1-73b7455c36956c2b") [] (SetProperty (SetPropertyData "colour" "blue")) (Emits (PropertySet (PropertySetData "colour" "blue") :| []))
  , LiveWitness (BehaviorKey "behavior-v1-fe7277b756f0ff4b") [PropertySet (PropertySetData "colour" "blue")] (ClearProperty (ClearPropertyData "colour")) (Emits (PropertyCleared (PropertyClearedData "colour") :| []))
  , LiveWitness (BehaviorKey "behavior-v1-fa59fc344c44f50b") [] (Touch (TouchData "touch")) (Emits (Touched (TouchedData "touch") :| []))
  , ReplayWitness (BehaviorKey "behavior-v1-afe574346545beaa") [] [PropertyCleared (PropertyClearedData "colour")]
  ]
