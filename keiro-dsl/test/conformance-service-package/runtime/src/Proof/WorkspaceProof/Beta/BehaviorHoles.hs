-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module Proof.WorkspaceProof.Beta.BehaviorHoles (behaviorWitnesses) where

import Proof.WorkspaceProof.Beta.Generated.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-6ab7fee2c8aa4e1d")
  ]