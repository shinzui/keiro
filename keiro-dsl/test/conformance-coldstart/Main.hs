{- | EP-7 cold-start proof: a brand-new `subscription` service, authored from
only the skill's notation (not in the corpus), driven through the full loop
(check -> scaffold -> fill the hole -> harness). Compiling this component
proves the scaffolded Generated modules + the hand-filled Holes compile
against keiki/keiro; running it runs the spec-derived harness green.
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Generated.Billing.Subscription.Harness (harnessAssertions)
import System.Exit (exitFailure)

main :: IO ()
main = do
    forM_ harnessAssertions $ \(label, ok) ->
        putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- harnessAssertions, not ok]
    unless (null failed) $ do
        putStrLn ("cold-start harness: " <> show (length failed) <> " failed")
        exitFailure
