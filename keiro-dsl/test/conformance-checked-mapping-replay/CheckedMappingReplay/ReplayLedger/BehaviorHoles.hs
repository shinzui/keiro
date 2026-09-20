-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module CheckedMappingReplay.ReplayLedger.BehaviorHoles (behaviorWitnesses) where

import Generated.CheckedMappingReplay.ReplayLedger.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-00d5b6d8d0fc6ef2") -- ReplayLedgerEmpty x ImportLegacy: replay-only transition
  , Pending (BehaviorKey "behavior-v1-9846660db9e83048") -- ReplayLedgerEmpty x ImportLegacy: required rejection
  , Pending (BehaviorKey "behavior-v1-cf9c72cd877a5085") -- ReplayLedgerEmpty x Record: live transition
  , Pending (BehaviorKey "behavior-v1-e88b4f5c37ef8bf2") -- ReplayLedgerRecorded x Record: required rejection
  , Pending (BehaviorKey "behavior-v1-efa5614712549991") -- ReplayLedgerRecorded x ImportLegacy: required rejection
  ]