{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module WorkspaceNominalProof.Project.Holes
  ( projectTransducer
  -- (no projection)

  ) where

import Generated.WorkspaceNominalProof.Project.Domain
import Keiki.Builder ((=:))
import qualified Keiki.Builder as B
import Keiki.Core (HsPred, RegFile, SymTransducer, lit, (.==), (./=), (.||))



-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
projectTransducer
  :: SymTransducer
       (HsPred ProjectRegs ProjectCommand)
       ProjectRegs
       ProjectVertex
       ProjectCommand
       ProjectEvent
projectTransducer =
  B.buildTransducer ProjectEmpty initialProjectRegs isTerminal do
    B.from ProjectEmpty do
      B.onCmd inCtorRegisterProject $ \d -> B.do
        -- HOLE emit ProjectRegistered (B.emit wireProjectRegistered ...)
        B.goto ProjectLive
 where
  isTerminal = \case
    ProjectLive -> True
    _ -> False
