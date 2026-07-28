{- | Conformance driver for the replay-divergence mutation fixture. It prints
every generated assertion and exits non-zero when any assertion fails, so the
mutation script can distinguish the new forward/replay register check from all
pre-existing checks.
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Generated.ReplayDivergence.Note.Harness (harnessAssertions)
import System.Exit (exitFailure)

main :: IO ()
main = do
    forM_ harnessAssertions $ \(label, ok) ->
        putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- harnessAssertions, not ok]
    unless (null failed) $ do
        putStrLn ("harness: " <> show (length failed) <> " assertion(s) failed")
        exitFailure
