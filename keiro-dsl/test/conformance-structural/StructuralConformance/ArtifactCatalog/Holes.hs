{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- HAND-OWNED language-4 event mapping. Generated code owns the aggregate
-- lifecycle, guards, writes, and transition envelope.
module StructuralConformance.ArtifactCatalog.Holes
  ( transition1EmptyObserveArtifactOutput2ArtifactAccepted
  ) where

import Generated.StructuralConformance.ArtifactCatalog.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)

transition1EmptyObserveArtifactOutput2ArtifactAccepted
  :: B.PayloadProj ArtifactCatalogRegs ArtifactCatalogCommand (RegFieldsOf ObserveArtifactData)
  -> ArtifactAcceptedTermFields ArtifactCatalogRegs ArtifactCatalogCommand (RegFieldsOf ObserveArtifactData)
transition1EmptyObserveArtifactOutput2ArtifactAccepted d =
  ArtifactAcceptedTermFields {accepted = d.accepted}
