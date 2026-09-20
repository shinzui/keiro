-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module BareContainers.BareStore.BehaviorHoles (behaviorWitnesses) where

import Generated.BareContainers.BareStore.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-b3fa753a88b62d6d") -- BareStoreEmpty x Store: live transition
  , Pending (BehaviorKey "behavior-v1-b728b85baa41bc71") -- BareStoreStored x Store: required rejection
  ]