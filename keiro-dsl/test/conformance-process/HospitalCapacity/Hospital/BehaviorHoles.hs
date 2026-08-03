-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module HospitalCapacity.Hospital.BehaviorHoles (behaviorWitnesses) where

import Generated.HospitalCapacity.Hospital.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-69ac3daa8569d350")
  ]