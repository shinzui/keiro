{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module StructuralConformance.ArtifactCatalog.Holes (
    artifactCatalogTransducer,
) where

import Generated.StructuralConformance.ArtifactCatalog.Domain
import Generated.StructuralConformance.StructuralProjections qualified as StructuralProjections
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, inpProj, lit)

-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
artifactCatalogTransducer ::
    SymTransducer
        (HsPred ArtifactCatalogRegs ArtifactCatalogCommand)
        ArtifactCatalogRegs
        ArtifactCatalogVertex
        ArtifactCatalogCommand
        ArtifactCatalogEvent
artifactCatalogTransducer =
    B.buildTransducer ArtifactCatalogEmpty initialArtifactCatalogRegs isTerminal do
        B.from ArtifactCatalogEmpty do
            B.onCmd inCtorObserveArtifact $ \d -> B.do
                B.requireEq
                    (inpProj StructuralProjections.structuralProjectionC41ZC72ZC74ZC69ZC66ZC61ZC63ZC74ZC49ZC6eZC66ZC6fZC2fZC61ZC72ZC74ZC69ZC66ZC61ZC63ZC74ZC5fZC6bZC65ZC79ZWitness inCtorObserveArtifact #artifact)
                    (lit "artifact-local-file")
                B.slot @"currentArtifact" =: d.artifact
                B.slot @"currentGeometry" =: d.geometry
                B.slot @"acceptedCount" =: B.reg @"acceptedCount"
                B.emit wireArtifactRecorded ArtifactRecordedTermFields{artifact = d.artifact, geometry = d.geometry, accepted = d.accepted}
                B.emit wireArtifactAccepted ArtifactAcceptedTermFields{accepted = d.accepted}
                B.goto ArtifactCatalogObserved
  where
    isTerminal = \case
        ArtifactCatalogObserved -> True
        _ -> False
