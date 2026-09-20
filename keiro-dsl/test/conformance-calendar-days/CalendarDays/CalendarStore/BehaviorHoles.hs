-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module CalendarDays.CalendarStore.BehaviorHoles (behaviorWitnesses) where

import Generated.CalendarDays.CalendarStore.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-81c1074e5cad73be") -- CalendarStoreStored x StoreDate: required rejection
  , Pending (BehaviorKey "behavior-v1-8a6ce5ac60391741") -- CalendarStoreEmpty x StoreDate: live transition
  ]