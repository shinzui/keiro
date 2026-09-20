-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module RefinedBase16.HashStore.BehaviorHoles (behaviorWitnesses) where

import Generated.RefinedBase16.HashStore.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-3506774d4ee392a3") -- HashStoreEmpty x StoreHash: live transition
  , Pending (BehaviorKey "behavior-v1-48110d655c1ffd6d") -- HashStoreStored x ImportLegacyHash: required rejection
  , Pending (BehaviorKey "behavior-v1-9838f2b4bff837a3") -- HashStoreEmpty x ImportLegacyHash: required rejection
  , Pending (BehaviorKey "behavior-v1-bf6e600d5467e6cc") -- HashStoreStored x StoreHash: required rejection
  , Pending (BehaviorKey "behavior-v1-ec86c76d09301c82") -- HashStoreEmpty x ImportLegacyHash: replay-only transition
  ]