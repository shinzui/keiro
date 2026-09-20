-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module StructuralTextSets.LabelStore.BehaviorHoles (behaviorWitnesses) where

import Generated.StructuralTextSets.LabelStore.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-bf90d9e010468fdc") -- LabelStoreEmpty x StoreLabels: live transition
  , Pending (BehaviorKey "behavior-v1-c15c80eb55d3be38") -- LabelStoreStored x StoreLabels: required rejection
  , Pending (BehaviorKey "behavior-v1-21ff727d241ecd71") -- LabelStoreEmpty x ImportLegacyLabels: required rejection
  , Pending (BehaviorKey "behavior-v1-3fe9a1bf4f7fe73f") -- LabelStoreStored x ImportLegacyLabels: required rejection
  , Pending (BehaviorKey "behavior-v1-7f54aab10d4d248f") -- LabelStoreEmpty x ImportLegacyLabels: replay-only transition
  ]
