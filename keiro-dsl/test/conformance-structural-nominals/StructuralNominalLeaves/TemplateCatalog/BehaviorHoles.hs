-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module StructuralNominalLeaves.TemplateCatalog.BehaviorHoles (behaviorWitnesses) where

import Generated.StructuralNominalLeaves.TemplateCatalog.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-01b677e97ee382b5") -- TemplateCatalogRouted x RecordTemplate: required rejection
  , Pending (BehaviorKey "behavior-v1-26fa1ba9ca514f81") -- TemplateCatalogRouted x RouteTemplate: required rejection
  , Pending (BehaviorKey "behavior-v1-6cb89110a4e5d4bc") -- TemplateCatalogRecorded x RecordTemplate: required rejection
  , Pending (BehaviorKey "behavior-v1-5dbbc70789956424") -- TemplateCatalogRecorded x RouteTemplate: live transition
  , Pending (BehaviorKey "behavior-v1-83a3e25d3520f959") -- TemplateCatalogEmpty x RecordTemplate: live transition
  , Pending (BehaviorKey "behavior-v1-d8388e1ef8008039") -- TemplateCatalogEmpty x RouteTemplate: required rejection
  ]
