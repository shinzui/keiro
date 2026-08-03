-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module AggregateScalarExpressions.ScalarAccount.BehaviorHoles (behaviorWitnesses) where

import Generated.AggregateScalarExpressions.ScalarAccount.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-e9c863d5daf20011"),
    Pending (BehaviorKey "behavior-v1-1de91883b9e3f8bc"),
    Pending (BehaviorKey "behavior-v1-5c58e0aafeb5f400"),
    Pending (BehaviorKey "behavior-v1-a19a8e94d935493f"),
    Pending (BehaviorKey "behavior-v1-b7db52f28632d8da"),
    Pending (BehaviorKey "behavior-v1-dbf483c868dd6d34")
  ]
