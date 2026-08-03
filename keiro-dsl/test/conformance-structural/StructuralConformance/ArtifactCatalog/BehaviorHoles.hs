-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module StructuralConformance.ArtifactCatalog.BehaviorHoles (behaviorWitnesses) where

import Generated.StructuralConformance.ArtifactCatalog.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-5ef17e70af0d6ff7")
  , Pending (BehaviorKey "behavior-v1-c20f0b92a1f17333")
  ]