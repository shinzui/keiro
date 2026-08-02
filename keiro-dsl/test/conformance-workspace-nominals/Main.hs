{-# LANGUAGE DataKinds #-}

module Main (main) where

import Generated.WorkspaceNominalProof.Nominals (ProjectId (..), ProjectPhase (..))
import Generated.WorkspaceNominalProof.Project.Codec qualified as ProjectCodec
import Generated.WorkspaceNominalProof.Project.Domain qualified as Project
import Generated.WorkspaceNominalProof.Project.Harness qualified as ProjectHarness
import Generated.WorkspaceNominalProof.Project.Transducer (projectTransducer)
import Generated.WorkspaceNominalProof.ProjectArtifact.Codec qualified as ArtifactCodec
import Generated.WorkspaceNominalProof.ProjectArtifact.Domain qualified as Artifact
import Generated.WorkspaceNominalProof.ProjectArtifact.Harness qualified as ArtifactHarness
import Generated.WorkspaceNominalProof.ProjectArtifact.Transducer (projectArtifactTransducer)
import Keiki.Core qualified as K
import Keiro.Codec (EventType (..))

main :: IO ()
main =
  if and (map snd (ProjectHarness.harnessAssertions <> ArtifactHarness.harnessAssertions) <> [sharedNominalIdentity, projectRoundTrip, artifactRoundTrip, generatedFleetAgreement])
    then pure ()
    else fail "workspace nominal conformance failed"

projectPayload :: Project.ProjectRegisteredData
projectPayload = Project.ProjectRegisteredData (ProjectId "proj_shared") Active

artifactPayload :: Artifact.ArtifactRecordedData
artifactPayload = toArtifactPayload projectPayload

toArtifactPayload :: Project.ProjectRegisteredData -> Artifact.ArtifactRecordedData
toArtifactPayload (Project.ProjectRegisteredData projectId phase) =
  Artifact.ArtifactRecordedData projectId phase

sharedNominalIdentity :: Bool
sharedNominalIdentity =
  case artifactPayload of
    Artifact.ArtifactRecordedData projectId phase ->
      projectId == ProjectId "proj_shared" && phase == Active

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
    matchingId = ProjectId ""
    matchingPhase = Draft
    register = Project.RegisterProject (Project.RegisterProjectData matchingId matchingPhase)
    archive = Project.ArchiveProject (Project.ArchiveProjectData matchingId matchingPhase)
    mismatchedArchive = Project.ArchiveProject (Project.ArchiveProjectData (ProjectId "different") matchingPhase)
    projectRing = case K.step projectTransducer (Project.ProjectEmpty, Project.initialProjectRegs) register of
      Nothing -> False
      Just (live, registers, _) ->
        live == Project.ProjectLive
          && rejects (K.step projectTransducer (live, registers) mismatchedArchive)
          && case K.step projectTransducer (live, registers) archive of
            Just (archived, _, _) -> archived == Project.ProjectArchived
            Nothing -> False
    artifactCommand = Artifact.RecordArtifact (Artifact.RecordArtifactData matchingId matchingPhase)
    artifactMismatch = Artifact.RecordArtifact (Artifact.RecordArtifactData (ProjectId "different") matchingPhase)
    artifactRing =
      case K.step projectArtifactTransducer (Artifact.ProjectArtifactEmpty, Artifact.initialProjectArtifactRegs) artifactCommand of
        Just (recorded, _, _) ->
          recorded == Artifact.ProjectArtifactRecorded
            && rejects (K.step projectArtifactTransducer (Artifact.ProjectArtifactEmpty, Artifact.initialProjectArtifactRegs) artifactMismatch)
        Nothing -> False
    rejects Nothing = True
    rejects Just {} = False
