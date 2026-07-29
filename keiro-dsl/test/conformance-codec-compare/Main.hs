{-# LANGUAGE ImportQualifiedPost #-}

module Main (main) where

import Conformance.CodecCompare.Historical (generatedEquivalentArtifactInfoCodec, historicalArtifactInfoCodec)
import Control.Monad (unless)
import Data.Text qualified as T
import Generated.StructuralConformance.Structural.CodecCompare.ArtifactInfo (compareWithHistorical)
import Keiro.Dsl.CodecCompare
import System.Exit (exitFailure)

main :: IO ()
main = do
    report <- compareWithHistorical historicalArtifactInfoCodec corpusPath
    missingArm <- compareWithHistorical historicalArtifactInfoCodec missingArmPath
    parityReport <- compareWithHistorical generatedEquivalentArtifactInfoCodec parityCorpusPath
    let differences =
            [ difference
            | observation <- crObservations report
            , RequiresVersionWork difference <- [classifiedVerdict observation]
            ]
        assertions =
            [ ("comparison has explicit differences", not (null differences))
            , ("omitted key is not parity", any isArtifactHashDifference differences)
            , ("legacy union tag is not parity", any isCanonicalTagDifference differences)
            , ("historical corpus is valid", null (crInputIssues report))
            , ("historical and typed branch coverage is complete", null (crCoverageGaps report))
            , ("differences make the report fail", not (reportSucceeded report))
            , ("authority framing is mandatory", "MIGRATION EVIDENCE ONLY" `T.isInfixOf` renderCompareReport report)
            , ("missing canonical arm is a coverage gap", any isCanonicalGap (crCoverageGaps missingArm))
            , ("removing the historical quirks yields parity", reportSucceeded parityReport)
            , ("parity retains authority framing", "MIGRATION EVIDENCE ONLY" `T.isInfixOf` renderCompareReport parityReport)
            ]
    mapM_ (\(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)) assertions
    unless (all snd assertions) exitFailure
  where
    corpusPath = "test/conformance-codec-compare/fixtures/artifact-info"
    missingArmPath = "test/conformance-codec-compare/fixtures/missing-arm"
    parityCorpusPath = "test/conformance-codec-compare/fixtures/generated-parity"

isArtifactHashDifference :: ComparisonDifference -> Bool
isArtifactHashDifference difference = case difference of
    EncodedValueDifference (JsonPointer pointer) _ _ -> pointer == "/artifact_hash"
    _ -> False

isCanonicalTagDifference :: ComparisonDifference -> Bool
isCanonicalTagDifference (GeneratedDecodeRejected reason) = "unknown ArtifactLocation union tag" `T.isInfixOf` reason
isCanonicalTagDifference _ = False

isCanonicalGap :: CoverageGap -> Bool
isCanonicalGap gap = case cgKind gap of
    UnionArm arm -> arm == "canonical"
    _ -> False
