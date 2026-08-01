module Main (main) where

import BehaviorComplete.Journey.BehaviorHoles (behaviorWitnesses)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Text.IO qualified as TIO
import Generated.BehaviorComplete.Journey.BehaviorContract
import System.Environment (getArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
  arguments <- getArgs
  let report = behaviorCoverageReport behaviorWitnesses
      jsonOutput = "--format=json" `elem` arguments || ["--format", "json"] `isSubsequenceOf` arguments
      failOnUnverified = "--fail-on-unverified" `elem` arguments
      conformancePassed = behaviorConformancePassedWith failOnUnverified report
  if jsonOutput
    then BL.putStrLn (Aeson.encode report)
    else TIO.putStr (renderBehaviorConformanceText report)
  if conformancePassed then pure () else exitFailure

isSubsequenceOf :: (Eq value) => [value] -> [value] -> Bool
isSubsequenceOf [] _ = True
isSubsequenceOf _ [] = False
isSubsequenceOf expected@(first : rest) (value : values)
  | first == value = isSubsequenceOf rest values
  | otherwise = isSubsequenceOf expected values
