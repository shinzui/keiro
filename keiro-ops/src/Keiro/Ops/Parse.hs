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
  value <- maybe (Left durationError) Right (Read.readMaybe numberText :: Maybe Double)
  if value < 0
    then Left durationError
    else Right (realToFrac (value * multiplier))
  where
    durationError = "expected a non-negative duration in seconds, or with s, m, h, or d suffix"

durationFactor :: Char -> Maybe Double
durationFactor = \case
  's' -> Just 1
  'm' -> Just 60
  'h' -> Just 3600
  'd' -> Just 86400
  _ -> Nothing
