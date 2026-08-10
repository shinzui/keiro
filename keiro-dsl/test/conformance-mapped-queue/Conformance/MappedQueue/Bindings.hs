{-# LANGUAGE OverloadedRecordDot #-}

module Conformance.MappedQueue.Bindings
  ( geometryCases,
    jobMetadataBinding,
    jobMetadataCases,
    jobPayloadBinding,
    jobPayloadCases,
  )
where

import Conformance.MappedQueue.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Generated.MappedQueue.Structural.Shape.JobMetadata qualified as MetadataShape
import Generated.MappedQueue.Structural.Shape.JobPayload qualified as PayloadShape
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))
import Keiro.Codec.Structural.Generic (genericStructuralBinding)

jobMetadataBinding :: StructuralBinding Domain.JobMetadata MetadataShape.JobMetadataShape
jobMetadataBinding = genericStructuralBinding

jobPayloadBinding :: StructuralBinding Domain.JobPayload PayloadShape.JobPayloadShape
jobPayloadBinding =
  StructuralBinding
    { bindingToShape = \value ->
        PayloadShape.JobPayload
          value.jobId
          value.label
          (bindingToShape jobMetadataBinding <$> value.metadata)
          value.geometry,
      bindingFromShape = \(PayloadShape.JobPayload jobId label metadata geometry) ->
        Domain.JobPayload
          jobId
          label
          (bindingFromShape jobMetadataBinding <$> metadata)
          geometry
    }

geometryCases :: FixtureCases Domain.Geometry
geometryCases =
  FixtureCases
    ( ("point", Domain.Geometry "POINT (1 2)")
        :| [("empty", Domain.Geometry "GEOMETRYCOLLECTION EMPTY")]
    )

jobMetadataCases :: FixtureCases Domain.JobMetadata
jobMetadataCases =
  FixtureCases
    ( ("none", Domain.JobMetadata Nothing)
        :| [("some", Domain.JobMetadata (Just "priority"))]
    )

jobPayloadCases :: FixtureCases Domain.JobPayload
jobPayloadCases =
  FixtureCases
    ( ( "without-metadata",
        Domain.JobPayload "job-1" "primary" Nothing (Domain.Geometry "POINT (1 2)")
      )
        :| [ ( "with-metadata",
               Domain.JobPayload "job-2" "secondary" (Just (Domain.JobMetadata (Just "priority"))) (Domain.Geometry "POINT (3 4)")
             )
           ]
    )
