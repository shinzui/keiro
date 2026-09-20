-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module CheckedMappingReplay.ReplayTarget.BehaviorHoles (behaviorWitnesses) where

import Generated.CheckedMappingReplay.ReplayTarget.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-756d75346570c343") -- ReplayTargetReady x Store: live transition
  ]