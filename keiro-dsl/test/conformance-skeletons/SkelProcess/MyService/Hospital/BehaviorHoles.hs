-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SkelProcess.MyService.Hospital.BehaviorHoles (behaviorWitnesses) where

import SkelProcess.Generated.MyService.Hospital.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-01e61eb25214eb69")
  , Pending (BehaviorKey "behavior-v1-e093b54ae670c60c")
  ]