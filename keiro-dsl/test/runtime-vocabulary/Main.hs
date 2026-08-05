-- | Cross-package guard for vocabularies keiro-dsl must know but cannot import.
--
-- keiro-dsl validates specs without depending on the @keiro@ runtime package, so
-- a handful of runtime vocabularies are restated in
-- "Keiro.Dsl.Validate". A restatement can drift; this suite is the thing that
-- stops it, by depending on both packages and comparing them directly.
--
-- Vocabularies keiro-dsl imports rather than restates (the integration envelope
-- header names, which live in @keiro-core@) need no guard and have none.
module Main (main) where

import Data.Text qualified as T
import Keiro.Dsl.Validate (runtimeTimerStatuses)
import Keiro.Timer.Schema (TimerStatus)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let actual = map (T.pack . show) [minBound .. maxBound :: TimerStatus]
  if actual == runtimeTimerStatuses
    then
      putStrLn
        ( "runtime vocabulary: timer statuses agree ("
            <> show (length actual)
            <> " constructors)"
        )
    else do
      putStrLn "runtime vocabulary: timer statuses DIVERGED"
      putStrLn ("  Keiro.Timer.Schema.TimerStatus: " <> show actual)
      putStrLn ("  Keiro.Dsl.Validate.runtimeTimerStatuses: " <> show runtimeTimerStatuses)
      putStrLn "  Update runtimeTimerStatuses to match the runtime, then rerun."
      exitFailure
