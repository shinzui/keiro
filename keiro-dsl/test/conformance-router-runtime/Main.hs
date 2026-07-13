{-# LANGUAGE DataKinds #-}

module Main (main) where

import Control.Monad (unless)
import Data.UUID qualified as UUID
import Generated.IncidentPaging.PagingRouter.Router (pagingRouterName, pagingRouterWorkerOptions)
import Generated.IncidentPaging.PagingRouter.RouterHarness (routerHarnessValues)
import Keiro.ProcessManager (PoisonPolicy (..), RejectedCommandPolicy (..), WorkerOptions (..))
import Keiro.Router (deterministicRouterCommandId)
import Kiroku.Store.Types (EventId (..), StreamName (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let sourceEventId = EventId UUID.nil
        first = deterministicRouterCommandId pagingRouterName "incident-1" sourceEventId (StreamName "page-a") 0
        same = deterministicRouterCommandId pagingRouterName "incident-1" sourceEventId (StreamName "page-a") 0
        otherTarget = deterministicRouterCommandId pagingRouterName "incident-1" sourceEventId (StreamName "page-b") 0
        otherOccurrence = deterministicRouterCommandId pagingRouterName "incident-1" sourceEventId (StreamName "page-a") 1
        checks =
            [ ("router name", pagingRouterName == "jitsurei-paging")
            , ("rejected policy lowered", rejectedCommandPolicy pagingRouterWorkerOptions == RejectedDeadLetter)
            , ("poison policy lowered", poisonIsHalt pagingRouterWorkerOptions)
            , ("id stable across calls", first == same)
            , ("id discriminates target stream", first /= otherTarget)
            , ("id discriminates occurrence", first /= otherOccurrence)
            , ("harness pins target-keyed inputs", lookup "dispatchIdInputs" routerHarnessValues == Just "(name, key, sourceEventId, targetStreamName, occurrence)")
            ]
    mapM_ (\(label, ok) -> putStrLn (label <> ": " <> show ok)) checks
    unless (all snd checks) exitFailure

poisonIsHalt :: WorkerOptions es msg -> Bool
poisonIsHalt options = case poisonPolicy options of
    PoisonHalt -> True
    _ -> False
