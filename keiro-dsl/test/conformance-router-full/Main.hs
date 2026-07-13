{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (unless)
import Effectful (runPureEff)
import Generated.IncidentPaging.PagingRouter.RouterHarness (routerHarnessValues)
import IncidentPaging.PagingRouter.RouterValue (IncidentRaised (..), pagingRouter)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.Router (Router (..))
import Keiro.Stream (stream)
import System.Exit (exitFailure)

main :: IO ()
main = do
    let input = IncidentRaised{incidentId = "incident-1", service = "cardiology"}
        commands = runPureEff (pagingRouter.resolve input)
        targets = map target commands
        checks =
            [ ("router name", pagingRouter.name == "jitsurei-paging")
            , ("router key", pagingRouter.key input == "incident-1")
            , ("resolver returns the expected targets", targets == [stream "page-incident-1-responder-a", stream "page-incident-1-responder-b"])
            , ("harness policy", lookup "rejectedPolicy" routerHarnessValues == Just "deadLetter")
            ]
    mapM_ (\(label, ok) -> putStrLn (label <> ": " <> show ok)) checks
    unless (all snd checks) exitFailure
