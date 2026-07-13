module Main (main) where

import Control.Monad (forM_, unless)
import Generated.IncidentPaging.PagingRouter.RouterHarness (routerHarnessValues)
import System.Exit (exitFailure)

expected :: [(String, String)]
expected =
    [ ("routerName", "jitsurei-paging")
    , ("keyField", "incidentId")
    , ("resolveSource", "read-model service_oncall")
    , ("resolveRow", "responderId")
    , ("dispatchCommand", "SendPage")
    , ("dispatchIdInputs", "(name, key, sourceEventId, targetStreamName, occurrence)")
    , ("onDuplicate", "AckOk")
    , ("onFailed", "Retry")
    , ("rejectedPolicy", "deadLetter")
    , ("poisonPolicy", "halt")
    ]

main :: IO ()
main = do
    let results = [(label, lookup label routerHarnessValues == Just value) | (label, value) <- expected]
        failed = [label | (label, ok) <- results, not ok]
    forM_ results $ \(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    unless (null failed) $ do
        putStrLn ("router harness: " <> show (length failed) <> " assertion(s) failed: " <> show failed)
        exitFailure
