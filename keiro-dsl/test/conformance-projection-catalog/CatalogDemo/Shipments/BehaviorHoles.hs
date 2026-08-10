-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module CatalogDemo.Shipments.BehaviorHoles (behaviorWitnesses) where

import Generated.CatalogDemo.Shipments.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-89eeb23ded471fe8") -- ShipmentsRecorded x RecordShipment: required rejection
  , Pending (BehaviorKey "behavior-v1-b0a7e39ecba10454") -- ShipmentsEmpty x RecordShipment: live transition
  ]