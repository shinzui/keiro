-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module CatalogDemo.Orders.BehaviorHoles (behaviorWitnesses) where

import Generated.CatalogDemo.Orders.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-3c2d2fb10ac96bf0") -- OrdersEmpty x RecordOrder: live transition (spec line 67)
  , Pending (BehaviorKey "behavior-v1-badd7ebab3a3a844") -- OrdersRecorded x RecordOrder: required rejection (spec line 62)
  ]