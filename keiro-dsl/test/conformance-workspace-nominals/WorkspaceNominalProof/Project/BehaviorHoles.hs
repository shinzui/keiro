-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module WorkspaceNominalProof.Project.BehaviorHoles (behaviorWitnesses) where

import Generated.WorkspaceNominalProof.Project.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-3de05f6aced1fbd8")
  , Pending (BehaviorKey "behavior-v1-3ef04b25c79aa821")
  , Pending (BehaviorKey "behavior-v1-44c09c629d21fd17")
  , Pending (BehaviorKey "behavior-v1-6134478c9aaa78cb")
  , Pending (BehaviorKey "behavior-v1-c4b406a5be4a0d0b")
  , Pending (BehaviorKey "behavior-v1-ea703ecdfbda1e70")
  ]
