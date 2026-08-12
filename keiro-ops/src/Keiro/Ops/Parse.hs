module Keiro.Ops.Parse
  ( durationReader,
    parseDuration,
  )
where

import Data.Char (toLower)
import Data.Time (NominalDiffTime)
import Options.Applicative (ReadM, eitherReader)
import Text.Read qualified as Read

durationReader :: ReadM NominalDiffTime
durationReader = eitherReader parseDuration

parseDuration :: String -> Either String NominalDiffTime
parseDuration input = do
  let (numberText, multiplier) =
        case reverse input of
          suffix : rest
            | Just factor <- durationFactor (toLower suffix) ->
                (reverse rest, factor)
          _ -> (input, 1)
  value <- maybe (Left malformed) Right (Read.readMaybe numberText :: Maybe Double)
  let scaled = value * multiplier
  if isNaN scaled || isInfinite scaled || scaled < 0
    then Left malformed
    else
      if scaled > maxDurationSeconds
        then Left tooLarge
        else Right (realToFrac scaled)
  where
    malformed =
      "invalid duration "
        <> show input
        <> ": expected a finite, non-negative number of seconds, optionally with an s, m, h, or d suffix"
    tooLarge =
      "invalid duration "
        <> show input
        <> ": exceeds the maximum supported duration of 9.0e12 seconds (about 285000 years)"

-- | Upper bound on any operator-supplied duration, in seconds. PostgreSQL's
-- binary timestamptz format is Int64 microseconds since 2000-01-01 (maximum
-- about 9.22e12 seconds); a larger duration wraps modulo 2^64 into an arbitrary
-- cutoff. 9.0e12 seconds is comfortably inside that range and far beyond any
-- legitimate retention.
maxDurationSeconds :: Double
maxDurationSeconds = 9.0e12

durationFactor :: Char -> Maybe Double
durationFactor = \case
  's' -> Just 1
  'm' -> Just 60
  'h' -> Just 3600
  'd' -> Just 86400
  _ -> Nothing
