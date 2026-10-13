module Proof.WorkspaceProof.Assignment.BehaviorHoles (behaviorWitnesses) where

import Data.List.NonEmpty (NonEmpty (..))
import Proof.WorkspaceProof.Assignment.Generated.BehaviorContract
import Proof.WorkspaceProof.Assignment.Generated.Domain

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ LiveWitness (BehaviorKey "behavior-v1-fbe5335a1e485829") [] (SetProperty (SetPropertyData "colour" "blue")) (Emits (PropertySet (PropertySetData "colour" "blue") :| []))
  , LiveWitness (BehaviorKey "behavior-v1-075a56dd42e6bc95") [PropertySet (PropertySetData "colour" "blue")] (ClearProperty (ClearPropertyData "colour")) (Emits (PropertyCleared (PropertyClearedData "colour") :| []))
  , LiveWitness (BehaviorKey "behavior-v1-0db4efc62e642065") [] (Touch (TouchData "touch")) (Emits (Touched (TouchedData "touch") :| []))
  , ReplayWitness (BehaviorKey "behavior-v1-9200cd4f93c83098") [] [PropertyCleared (PropertyClearedData "colour")]
  ]
