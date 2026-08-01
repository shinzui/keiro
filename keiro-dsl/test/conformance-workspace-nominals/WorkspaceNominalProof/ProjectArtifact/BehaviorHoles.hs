-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module WorkspaceNominalProof.ProjectArtifact.BehaviorHoles (behaviorWitnesses) where

import Generated.WorkspaceNominalProof.ProjectArtifact.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-11da0fd14ad66aa0")
  , Pending (BehaviorKey "behavior-v1-c6d79387e567590e")
  ]
