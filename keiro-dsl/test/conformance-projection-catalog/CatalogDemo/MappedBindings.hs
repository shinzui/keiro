{-# LANGUAGE OverloadedStrings #-}

module CatalogDemo.MappedBindings
  ( orderPayloadCases,
    qualificationPayloadBinding,
    qualificationPayloadCases,
    qualificationResultCases,
    queryCriteriaCases,
    queueMetadataCases,
    registerStateCases,
    initialRegisterState,
    sharedReferenceCases,
    unusedQualificationCases,
  )
where

import CatalogDemo.MappedDomain
import Data.List.NonEmpty (NonEmpty (..))
import Generated.CatalogDemo.Structural.Shape.QualificationPayload (QualificationPayloadShape)
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding)
import Keiro.Codec.Structural.Generic (genericStructuralBinding)

qualificationPayloadBinding :: StructuralBinding QualificationPayload QualificationPayloadShape
qualificationPayloadBinding = genericStructuralBinding

orderPayloadCases :: FixtureCases OrderPayload
orderPayloadCases =
  FixtureCases
    ( ("primary", OrderPayload "order-primary")
        :| [("secondary", OrderPayload "order-secondary")]
    )

sharedReferenceCases :: FixtureCases SharedReference
sharedReferenceCases =
  FixtureCases
    ( ("shared-a", SharedReference "shared-a")
        :| [("shared-b", SharedReference "shared-b")]
    )

qualificationPayloadCases :: FixtureCases QualificationPayload
qualificationPayloadCases =
  FixtureCases
    ( ("without-note", QualificationPayload "qualification-a" Nothing)
        :| [("with-note", QualificationPayload "qualification-b" (Just "priority"))]
    )

queueMetadataCases :: FixtureCases QueueMetadata
queueMetadataCases =
  FixtureCases
    ( ("primary", QueueMetadata "queue-primary")
        :| [("secondary", QueueMetadata "queue-secondary")]
    )

queryCriteriaCases :: FixtureCases QueryCriteria
queryCriteriaCases =
  FixtureCases
    ( ("primary", QueryCriteria "query-primary")
        :| [("secondary", QueryCriteria "query-secondary")]
    )

qualificationResultCases :: FixtureCases QualificationResult
qualificationResultCases =
  FixtureCases
    ( ("accepted", QualificationResult "accepted")
        :| [("rejected", QualificationResult "rejected")]
    )

registerStateCases :: FixtureCases RegisterState
registerStateCases =
  FixtureCases
    ( ("initial", initialRegisterState)
        :| [("updated", RegisterState "updated")]
    )

initialRegisterState :: RegisterState
initialRegisterState = RegisterState "initial"

unusedQualificationCases :: FixtureCases UnusedQualification
unusedQualificationCases =
  FixtureCases
    (("unused", UnusedQualification "unused") :| [])
