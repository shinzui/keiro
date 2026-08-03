-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SkelProcess.MyService.Surge.BehaviorHoles (behaviorWitnesses) where

import SkelProcess.Generated.MyService.Surge.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-86bc21fdc4a8ca5d")
  , Pending (BehaviorKey "behavior-v1-86bd3f785d9c7719")
  , Pending (BehaviorKey "behavior-v1-d517bd7075620508")
  , Pending (BehaviorKey "behavior-v1-fe2793e47f0b6989")
  ]