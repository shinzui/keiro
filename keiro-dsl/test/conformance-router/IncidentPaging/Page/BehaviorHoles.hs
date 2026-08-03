-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module IncidentPaging.Page.BehaviorHoles (behaviorWitnesses) where

import Generated.IncidentPaging.Page.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-4cc963adc6662c5e")
  , Pending (BehaviorKey "behavior-v1-d0a1ec215dcca5f8")
  ]