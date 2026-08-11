-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module TransferRouting.Hospital.BehaviorHoles (behaviorWitnesses) where

import Generated.TransferRouting.Hospital.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-51a443ca8bbb0eab") -- HospitalRouted x RouteAcceptedTransferNeed: required rejection
  , Pending (BehaviorKey "behavior-v1-6dc56a81dec7fe2b") -- HospitalOpen x RouteAcceptedTransferNeed: live transition
  ]