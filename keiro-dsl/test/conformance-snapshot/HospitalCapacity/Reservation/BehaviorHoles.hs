-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module HospitalCapacity.Reservation.BehaviorHoles (behaviorWitnesses) where

import Generated.HospitalCapacity.Reservation.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-a544566ac00664fb")
  , Pending (BehaviorKey "behavior-v1-bf9ebe70beb18440")
  , Pending (BehaviorKey "behavior-v1-cf40a84edc844a41")
  , Pending (BehaviorKey "behavior-v1-dff0853d3cd55550")
  , Pending (BehaviorKey "behavior-v1-e53a65263ad89283")
  , Pending (BehaviorKey "behavior-v1-e7378f31cfa93bbf")
  ]