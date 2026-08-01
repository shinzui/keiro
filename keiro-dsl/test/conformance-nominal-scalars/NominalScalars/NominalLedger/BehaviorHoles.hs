-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module NominalScalars.NominalLedger.BehaviorHoles (behaviorWitnesses) where

import Generated.NominalScalars.NominalLedger.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-971c0c80ffdfe018"),
    Pending (BehaviorKey "behavior-v1-274eaf83d346048a")
  ]
