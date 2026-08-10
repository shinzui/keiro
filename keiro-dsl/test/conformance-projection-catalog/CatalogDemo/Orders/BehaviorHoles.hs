-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module CatalogDemo.Orders.BehaviorHoles (behaviorWitnesses) where

import Generated.CatalogDemo.Orders.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-8861ebe94ff5f68a") -- OrdersEmpty x RecordOrder: live transition
  , Pending (BehaviorKey "behavior-v1-badd7ebab3a3a844") -- OrdersRecorded x RecordOrder: required rejection
  ]
