{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}

module Main (main) where

import Conformance.Structural.Bindings qualified as Bindings
import Control.Monad (forM_, unless)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.List.NonEmpty qualified as NonEmpty
import Generated.StructuralConformance.ArtifactCatalog.Codec (encodeArtifactCatalogEvent)
import Generated.StructuralConformance.ArtifactCatalog.Domain (ArtifactCatalogCommand, ArtifactCatalogEvent (..), ArtifactCatalogRegs, ArtifactRecordedData (..), inCtorObserveArtifact)
import Generated.StructuralConformance.ArtifactCatalog.Harness (harnessAssertions)
import Generated.StructuralConformance.StructuralProjections qualified as StructuralProjections
import Keiki.Core (HsPred, inpProj, (./=))
import Keiki.Symbolic (symIsBot)
import Keiro.Codec.Structural (FixtureCases (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    goldenAssertions <- loadGoldenAssertions
    let assertions = harnessAssertions <> projectionAssertions <> goldenAssertions
    forM_ assertions $ \(label, ok) ->
        putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- assertions, not ok]
    unless (null failed) $ do
        putStrLn ("structural harness: " <> show (length failed) <> " assertion(s) failed")
        exitFailure

projectionAssertions :: [(String, Bool)]
projectionAssertions =
    [
        ( "projection key sharing: conformance.structural.ArtifactInfo.v1/artifact_key"
        , symIsBot
            ( inpProj artifactKeyWitness inCtorObserveArtifact #artifact
                ./= inpProj artifactKeyWitness inCtorObserveArtifact #artifact ::
                HsPred ArtifactCatalogRegs ArtifactCatalogCommand
            )
        )
    ]
  where
    artifactKeyWitness = StructuralProjections.structuralProjectionC41ZC72ZC74ZC69ZC66ZC61ZC63ZC74ZC49ZC6eZC66ZC6fZC2fZC61ZC72ZC74ZC69ZC66ZC61ZC63ZC74ZC5fZC6bZC65ZC79ZWitness

loadGoldenAssertions :: IO [(String, Bool)]
loadGoldenAssertions = do
    actual <- LazyByteString.readFile "test/golden-payloads/structural-conformance/ArtifactCatalog/ArtifactRecorded.v1.json"
    let artifact = snd (NonEmpty.head (fixtureCases Bindings.artifactInfoCases))
        geometry = snd (NonEmpty.head (fixtureCases Bindings.geometryCases))
        event = ArtifactRecorded ArtifactRecordedData{artifact, geometry, accepted = False}
        expected = Aeson.encode (encodeArtifactCatalogEvent event) <> "\n"
    unless (actual == expected) $ do
        LazyChar8.putStrLn ("expected: " <> expected)
        LazyChar8.putStrLn ("actual:   " <> actual)
    pure [("current JSON golden: ArtifactRecorded.v1", actual == expected)]
