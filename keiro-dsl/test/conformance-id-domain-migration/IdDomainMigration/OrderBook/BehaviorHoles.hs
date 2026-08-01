-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module IdDomainMigration.OrderBook.BehaviorHoles (behaviorWitnesses) where

import Generated.IdDomainMigration.OrderBook.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-6b331af859e674ea")
  , Pending (BehaviorKey "behavior-v1-a396f60ddb8f99be")
  ]