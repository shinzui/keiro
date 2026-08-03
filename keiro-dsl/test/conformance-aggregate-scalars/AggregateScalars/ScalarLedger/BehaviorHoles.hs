-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module AggregateScalars.ScalarLedger.BehaviorHoles (behaviorWitnesses) where

import Generated.AggregateScalars.ScalarLedger.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-4e461a9ba9271054")
  , Pending (BehaviorKey "behavior-v1-d15e326edfa1a438")
  ]