-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SkelProcess.MyService.Surge.BehaviorHoles (behaviorWitnesses) where

import SkelProcess.Generated.MyService.Surge.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-86bc21fdc4a8ca5d") -- SurgeIdle x NoteSurgeThreshold: live transition (spec line 43)
  , Pending (BehaviorKey "behavior-v1-86bd3f785d9c7719") -- SurgeIdle x MarkSurgeTimerFired: live transition (spec line 44)
  , Pending (BehaviorKey "behavior-v1-d517bd7075620508") -- SurgeFired x NoteSurgeThreshold: required rejection (spec line 37)
  , Pending (BehaviorKey "behavior-v1-fe2793e47f0b6989") -- SurgeFired x MarkSurgeTimerFired: required rejection (spec line 37)
  ]
