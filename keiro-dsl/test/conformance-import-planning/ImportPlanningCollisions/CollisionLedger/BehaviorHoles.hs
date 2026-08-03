-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ImportPlanningCollisions.CollisionLedger.BehaviorHoles (behaviorWitnesses) where

import Generated.ImportPlanningCollisions.CollisionLedger.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-2134fce4a19c59d7")
  , Pending (BehaviorKey "behavior-v1-995f9bf710ce7c6c")
  ]