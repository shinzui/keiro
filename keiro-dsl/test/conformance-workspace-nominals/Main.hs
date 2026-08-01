module Main (main) where

import Generated.WorkspaceNominalProof.Nominals (ProjectId (..), ProjectPhase (..))
import Generated.WorkspaceNominalProof.Project.Codec qualified as ProjectCodec
import Generated.WorkspaceNominalProof.Project.Domain qualified as Project
import Generated.WorkspaceNominalProof.ProjectArtifact.Codec qualified as ArtifactCodec
import Generated.WorkspaceNominalProof.ProjectArtifact.Domain qualified as Artifact
import Keiro.Codec (EventType (..))

main :: IO ()
main =
  if and [sharedNominalIdentity, projectRoundTrip, artifactRoundTrip]
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
