-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module IdAdmissionDomains.IdentityLedger.BehaviorHoles (behaviorWitnesses) where

import Generated.IdAdmissionDomains.IdentityLedger.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-723df676736b6f6c") -- IdentityLedgerOpen x RecordIdentity: live transition
  ]