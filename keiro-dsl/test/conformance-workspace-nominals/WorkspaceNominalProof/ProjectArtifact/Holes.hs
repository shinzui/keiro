{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module WorkspaceNominalProof.ProjectArtifact.Holes
  ( projectArtifactTransducer
  -- (no projection)

  ) where

import Generated.WorkspaceNominalProof.ProjectArtifact.Domain
import Keiki.Builder ((=:))
import qualified Keiki.Builder as B
import Keiki.Core (HsPred, RegFile, SymTransducer, lit, (.==), (./=), (.||))



-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
projectArtifactTransducer
  :: SymTransducer
       (HsPred ProjectArtifactRegs ProjectArtifactCommand)
       ProjectArtifactRegs
       ProjectArtifactVertex
       ProjectArtifactCommand
       ProjectArtifactEvent
projectArtifactTransducer =
  B.buildTransducer ProjectArtifactEmpty initialProjectArtifactRegs isTerminal do
    B.from ProjectArtifactEmpty do
      B.onCmd inCtorRecordArtifact $ \d -> B.do
        -- HOLE emit ArtifactRecorded (B.emit wireArtifactRecorded ...)
        B.goto ProjectArtifactRecorded
 where
  isTerminal = \case
    ProjectArtifactRecorded -> True
    _ -> False
