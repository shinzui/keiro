-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ReplayDivergence.Note.BehaviorHoles (behaviorWitnesses) where

import Generated.ReplayDivergence.Note.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-248e9c1b1eb3e5bc")
  , Pending (BehaviorKey "behavior-v1-7c36eda198514110")
  ]