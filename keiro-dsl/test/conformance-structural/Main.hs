{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}

module Main (main) where

import Conformance.Structural.Bindings qualified as Bindings
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as T
import Generated.StructuralConformance.ArtifactCatalog.Codec (decodeArtifactInfoMapped, decodeArtifactKindMapped, decodeArtifactLocationMapped, encodeArtifactCatalogEvent, encodeArtifactInfoMapped)
import Generated.StructuralConformance.ArtifactCatalog.Domain (ArtifactCatalogCommand, ArtifactCatalogEvent (..), ArtifactCatalogRegs, ArtifactRecordedData (..), inCtorObserveArtifact)
import Generated.StructuralConformance.ArtifactCatalog.Harness (harnessAssertions)
import Generated.StructuralConformance.StructuralConformance (structuralConformanceAssertions)
import Generated.StructuralConformance.StructuralProjections qualified as StructuralProjections
import Keiki.Core (HsPred, inpProj, (./=))
import Keiki.Symbolic (symIsBot)
import Keiro.Codec.Structural (FixtureCases (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    goldenAssertions <- loadGoldenAssertions
    let assertions =
            [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
                <> harnessAssertions
                <> projectionAssertions
                <> decodeDiagnosticAssertions
                <> goldenAssertions
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
    artifactKeyWitness = StructuralProjections.artifactInfoArtifactKeyWitness

decodeDiagnosticAssertions :: [(String, Bool)]
decodeDiagnosticAssertions =
    [ ( "mapped enum failure names the value and expected set"
      , leftContains ["unlisted", "guide", "reference"] (decodeArtifactKindMapped (String "unlisted"))
      )
    , ( "mapped union failure points at the tag and names every arm"
      , leftContains
            ["$.tag", "remote", "local_file", "local_dir", "repo_path", "url", "canonical"]
            (decodeArtifactLocationMapped (object ["tag" .= ("remote" :: T.Text)]))
      )
    , ( "nested mapped failure retains the complete field path"
      , leftContains ["$.location.contents"] nestedFailure
      )
    ]
  where
    artifact = snd (NonEmpty.head (fixtureCases Bindings.artifactInfoCases))
    nestedFailure = case encodeArtifactInfoMapped artifact of
        Object fields ->
            decodeArtifactInfoMapped
                ( Object
                    ( KeyMap.insert
                        "location"
                        (object ["tag" .= ("local_file" :: T.Text), "contents" .= (7 :: Int)])
                        fields
                    )
                )
        _ -> error "ArtifactInfo mapped encoder did not produce an object"
    leftContains fragments result = case result of
        Left problem -> all (`T.isInfixOf` problem) fragments
        Right _ -> False

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
