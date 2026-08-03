-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module Billing.Subscription.BehaviorHoles (behaviorWitnesses) where

import Generated.Billing.Subscription.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-09842123ac52dd63")
  , Pending (BehaviorKey "behavior-v1-9399755ba2b617d6")
  , Pending (BehaviorKey "behavior-v1-93f6f3f8cb36420d")
  , Pending (BehaviorKey "behavior-v1-99ac0c974e512f76")
  , Pending (BehaviorKey "behavior-v1-9b81e070774b3ae1")
  , Pending (BehaviorKey "behavior-v1-b5d1ca5d9ad9b2ec")
  ]