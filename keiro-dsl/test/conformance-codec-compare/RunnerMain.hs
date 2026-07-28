{-# LANGUAGE ImportQualifiedPost #-}

module Main (main) where

import Conformance.CodecCompare.Historical (historicalArtifactInfoCodec)
import Data.Text.IO qualified as TIO
import Generated.StructuralConformance.Structural.CodecCompare.ArtifactInfo (compareWithHistorical)
import Keiro.Dsl.CodecCompare (renderCompareReport, reportSucceeded, writeCompareReportAtomic)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    arguments <- getArgs
    case arguments of
        ["--historical-goldens", goldenDirectory, "--report", reportPath] -> do
            report <- compareWithHistorical historicalArtifactInfoCodec goldenDirectory
            TIO.putStr (renderCompareReport report)
            writeResult <- writeCompareReportAtomic reportPath report
            case writeResult of
                Left err -> hPutStrLn stderr (show err) >> exitFailure
                Right () -> if reportSucceeded report then pure () else exitFailure
        _ -> do
            hPutStrLn stderr "usage: keiro-dsl-codec-compare-artifact-info --historical-goldens DIR --report FILE"
            exitFailure
