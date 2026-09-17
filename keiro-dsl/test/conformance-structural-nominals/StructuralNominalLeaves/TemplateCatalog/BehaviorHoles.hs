-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module StructuralNominalLeaves.TemplateCatalog.BehaviorHoles (behaviorWitnesses) where

import Generated.StructuralNominalLeaves.TemplateCatalog.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-6cb89110a4e5d4bc") -- TemplateCatalogRecorded x RecordTemplate: required rejection
  , Pending (BehaviorKey "behavior-v1-324168e7e31368e6") -- TemplateCatalogEmpty x RecordTemplate: live transition
  ]
