{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module WorkspaceNominalProof.Bindings (
    projectClaimFixtures
  , projectClaimBinding
  , claimId
  , claimIdFixtures
  , claimIdBinding
  , artifactClaimFixtures
  , artifactClaimBinding
) where

import Data.KindID (KindID)
import Data.KindID qualified as KindID
import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Generated.WorkspaceNominalProof.Structural.Shape.ArtifactClaim qualified as ShapeArtifactClaim
import Generated.WorkspaceNominalProof.Structural.Shape.ProjectClaim qualified as ShapeProjectClaim
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))
import WorkspaceNominalProof.Domain (ArtifactClaim, ClaimId, ProjectClaim)
import WorkspaceNominalProof.Domain qualified as Domain

claimIdText :: Text
claimIdText = "claim_01h455vb4pex5vsknk084sn02q"

claimId :: ClaimId
claimId = case KindID.parseText @"claim" claimIdText of
  Left reason -> error ("invalid committed ClaimId fixture: " <> show reason)
  Right value -> Domain.ClaimId value

projectClaimFixtures :: FixtureCases ProjectClaim
projectClaimFixtures = FixtureCases (("shared-claim", Domain.ProjectClaim claimId) :| [])

projectClaimBinding :: StructuralBinding ProjectClaim ShapeProjectClaim.ProjectClaimShape
projectClaimBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.ProjectClaim claimIdValue -> ShapeProjectClaim.ProjectClaim claimIdValue
    , bindingFromShape = \case
      ShapeProjectClaim.ProjectClaim claimIdValue -> Domain.ProjectClaim claimIdValue
    }

claimIdFixtures :: NominalFixtureCases ClaimId
claimIdFixtures = NominalFixtureCases (NominalFixture "shared-claim" (String claimIdText) claimId :| [])

claimIdBinding :: NominalBinding ClaimId (KindID "claim")
claimIdBinding = NominalBinding Domain.unClaimId Domain.ClaimId

artifactClaimFixtures :: FixtureCases ArtifactClaim
artifactClaimFixtures = FixtureCases (("shared-claim", Domain.ArtifactClaim claimId) :| [])

artifactClaimBinding :: StructuralBinding ArtifactClaim ShapeArtifactClaim.ArtifactClaimShape
artifactClaimBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.ArtifactClaim claimIdValue -> ShapeArtifactClaim.ArtifactClaim claimIdValue
    , bindingFromShape = \case
      ShapeArtifactClaim.ArtifactClaim claimIdValue -> Domain.ArtifactClaim claimIdValue
    }
