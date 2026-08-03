-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SurgeDemo.Surge.BehaviorHoles (behaviorWitnesses) where

import Generated.SurgeDemo.Surge.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-364cc8c97a1dccd7")
  , Pending (BehaviorKey "behavior-v1-7bd417bb60f14aea")
  , Pending (BehaviorKey "behavior-v1-8303777877a78d98")
  , Pending (BehaviorKey "behavior-v1-9d1377f4e60cd45a")
  , Pending (BehaviorKey "behavior-v1-c7783d8bb46678fe")
  , Pending (BehaviorKey "behavior-v1-db2fec76864e5867")
  ]