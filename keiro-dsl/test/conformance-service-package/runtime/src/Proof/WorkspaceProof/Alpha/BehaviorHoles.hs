-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module Proof.WorkspaceProof.Alpha.BehaviorHoles (behaviorWitnesses) where

import Proof.WorkspaceProof.Alpha.Generated.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-e2c1eef1cb7848f5")
  ]