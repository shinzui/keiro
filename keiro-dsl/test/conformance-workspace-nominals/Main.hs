{-# LANGUAGE DataKinds #-}

module Main (main) where

import Data.Text qualified as T
import Data.Aeson.Types (parseEither)
import Generated.WorkspaceNominalProof.Nominals (ProjectId, ProjectPhase (..), parseProjectId)
import Generated.WorkspaceNominalProof.Project.Codec qualified as ProjectCodec
import Generated.WorkspaceNominalProof.Project.Domain qualified as Project
import Generated.WorkspaceNominalProof.Project.Harness qualified as ProjectHarness
import Generated.WorkspaceNominalProof.Project.Transducer (projectTransducer)
import Generated.WorkspaceNominalProof.ProjectArtifact.Codec qualified as ArtifactCodec
import Generated.WorkspaceNominalProof.ProjectArtifact.Domain qualified as Artifact
import Generated.WorkspaceNominalProof.ProjectArtifact.Harness qualified as ArtifactHarness
import Generated.WorkspaceNominalProof.ProjectArtifact.Transducer (projectArtifactTransducer)
import Generated.WorkspaceNominalProof.Structural.NominalLeaves qualified as NominalLeaves
import Generated.WorkspaceNominalProof.StructuralConformance (structuralConformanceAssertions)
import Keiki.Core qualified as K
import Keiro.Codec (EventType (..))
import WorkspaceNominalProof.Bindings qualified as Bindings
import WorkspaceNominalProof.Domain qualified as Consumer

main :: IO ()
main =
  if and (map snd (structuralConformanceAssertions <> ProjectHarness.harnessAssertions <> ArtifactHarness.harnessAssertions) <> [sharedNominalIdentity, sharedClaimIdentity, memberStructuralRoundTrips, projectRoundTrip, artifactRoundTrip, generatedFleetAgreement])
    then pure ()
    else fail "workspace nominal conformance failed"

projectPayload :: Project.ProjectRegisteredData
projectPayload = Project.ProjectRegisteredData projectIdValue Active projectClaim

artifactPayload :: Artifact.ArtifactRecordedData
artifactPayload = toArtifactPayload projectPayload

toArtifactPayload :: Project.ProjectRegisteredData -> Artifact.ArtifactRecordedData
toArtifactPayload (Project.ProjectRegisteredData projectId phase (Consumer.ProjectClaim claimId)) =
  Artifact.ArtifactRecordedData projectId phase (Consumer.ArtifactClaim claimId)

sharedNominalIdentity :: Bool
sharedNominalIdentity =
  case artifactPayload of
    Artifact.ArtifactRecordedData projectId phase (Consumer.ArtifactClaim claimId) ->
      projectId == projectIdValue && phase == Active && claimId == Bindings.claimId

sharedClaimIdentity :: Bool
sharedClaimIdentity =
  case parseEither NominalLeaves.parseClaimIdLeaf (NominalLeaves.encodeClaimIdLeaf Bindings.claimId) of
    Left _ -> False
    Right claimId ->
      case (Consumer.ProjectClaim claimId, Consumer.ArtifactClaim claimId) of
        (Consumer.ProjectClaim projectClaimId, Consumer.ArtifactClaim artifactClaimId) ->
          projectClaimId == artifactClaimId

memberStructuralRoundTrips :: Bool
memberStructuralRoundTrips =
  ProjectCodec.decodeProjectClaimMapped (ProjectCodec.encodeProjectClaimMapped projectClaim) == Right projectClaim
    && ArtifactCodec.decodeArtifactClaimMapped (ArtifactCodec.encodeArtifactClaimMapped artifactClaim) == Right artifactClaim

projectClaim :: Consumer.ProjectClaim
projectClaim = Consumer.ProjectClaim Bindings.claimId

artifactClaim :: Consumer.ArtifactClaim
artifactClaim = Consumer.ArtifactClaim Bindings.claimId

projectRoundTrip :: Bool
projectRoundTrip =
  let event = Project.ProjectRegistered projectPayload
   in ProjectCodec.parseProjectEvent
        (EventType "ProjectRegistered")
        (ProjectCodec.encodeProjectEvent event)
        == Right event

artifactRoundTrip :: Bool
artifactRoundTrip =
  let event = Artifact.ArtifactRecorded artifactPayload
   in ArtifactCodec.parseProjectArtifactEvent
        (EventType "ArtifactRecorded")
        (ArtifactCodec.encodeProjectArtifactEvent event)
        == Right event

generatedFleetAgreement :: Bool
generatedFleetAgreement = projectRing && artifactRing
  where
    matchingId = projectIdValue
    matchingPhase = Draft
    register = Project.RegisterProject (Project.RegisterProjectData matchingId matchingPhase projectClaim)
    archive = Project.ArchiveProject (Project.ArchiveProjectData matchingId matchingPhase)
    mismatchedArchive = Project.ArchiveProject (Project.ArchiveProjectData otherProjectIdValue matchingPhase)
    projectRing = case K.step projectTransducer (Project.ProjectEmpty, Project.initialProjectRegs) register of
      Nothing -> False
      Just (live, registers, _) ->
        live == Project.ProjectLive
          && rejects (K.step projectTransducer (live, registers) mismatchedArchive)
          && case K.step projectTransducer (live, registers) archive of
            Just (archived, _, _) -> archived == Project.ProjectArchived
            Nothing -> False
    artifactCommand = Artifact.RecordArtifact (Artifact.RecordArtifactData matchingId matchingPhase artifactClaim)
    artifactMismatch = Artifact.RecordArtifact (Artifact.RecordArtifactData otherProjectIdValue matchingPhase artifactClaim)
    artifactRing =
      case K.step projectArtifactTransducer (Artifact.ProjectArtifactEmpty, Artifact.initialProjectArtifactRegs) artifactCommand of
        Just (recorded, _, _) ->
          recorded == Artifact.ProjectArtifactRecorded
            && rejects (K.step projectArtifactTransducer (Artifact.ProjectArtifactEmpty, Artifact.initialProjectArtifactRegs) artifactMismatch)
        Nothing -> False
    rejects Nothing = True
    rejects Just {} = False

projectIdValue :: ProjectId
projectIdValue = checkedProjectId "proj_01h455vb4pex5vsknk084sn02q"

otherProjectIdValue :: ProjectId
otherProjectIdValue = checkedProjectId "proj_01h455vb4pex5vsknk084sn02r"

checkedProjectId :: String -> ProjectId
checkedProjectId raw =
  case parseProjectId (T.pack raw) of
    Right parsed -> parsed
    Left problem -> error (show problem)
