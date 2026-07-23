{- | Conformance driver for the evolved (v2) HospitalCapacity/Reservation
aggregate (EP-2). Compiling this component proves the scaffolded v2 Generated
modules — a Codec with @schemaVersion = 2@ and
@upcasters = [(1, upcastTransferReservationCreatedV1)]@ — build against
keiki/keiro with the hand-filled upcaster hole. Running it proves the upcaster
chain actually migrates a v1-tagged payload forward (the "upcaster wired"
harness assertion is green only because the hole is filled).
-}
module Main (main) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value, eitherDecodeFileStrict')
import Data.List (sort)
import Data.Text qualified as T
import Generated.HospitalCapacity.Reservation.Codec (reservationCodec)
import Generated.HospitalCapacity.Reservation.Harness (harnessAssertions)
import Keiro.Codec (EventType (..), decodeRaw)
import System.Directory (listDirectory)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

main :: IO ()
main = do
    goldenAssertions <- loadGoldenAssertions
    let assertions = harnessAssertions <> goldenAssertions
    forM_ assertions $ \(label, ok) ->
        putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- assertions, not ok]
    unless (null failed) $ do
        putStrLn ("harness: " <> show (length failed) <> " assertion(s) failed")
        exitFailure

loadGoldenAssertions :: IO [(String, Bool)]
loadGoldenAssertions = do
    files <- sort <$> listDirectory goldenDirectory
    forM [file | file <- files, ".json" `T.isSuffixOf` T.pack file] $ \file ->
        case parseGoldenName file of
            Nothing -> pure ("golden " <> file <> " (invalid fixture filename)", False)
            Just (tag, version) -> do
                payloadResult <- eitherDecodeFileStrict' (goldenDirectory <> "/" <> file) :: IO (Either String Value)
                pure
                    ( "golden " <> T.unpack tag <> ".v" <> show version
                    , case payloadResult of
                        Left _ -> False
                        Right payload ->
                            either
                                (const False)
                                (const True)
                                (decodeRaw reservationCodec (EventType tag) version payload)
                    )

goldenDirectory :: FilePath
goldenDirectory = "test/golden-payloads/hospital-capacity/Reservation"

parseGoldenName :: FilePath -> Maybe (T.Text, Int)
parseGoldenName file = do
    stem <- T.stripSuffix ".json" (T.pack file)
    let (tagWithMarker, versionText) = T.breakOnEnd ".v" stem
        tag = T.dropEnd 2 tagWithMarker
    version <- readMaybe (T.unpack versionText)
    if T.null tag || T.null versionText then Nothing else Just (tag, version)
