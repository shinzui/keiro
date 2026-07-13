{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Effectful (Eff, (:>))
import Generated.HospitalCapacity.Transfer_decisions.ReadModel
import Generated.HospitalCapacity.Transfer_decisions.ReadModelHarness (readModelFacts, runReadModelFacts)
import Keiro.Projection (AsyncProjection (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), ReadModelMetadata, StrongScope (..), qualifiedTableName)
import Keiro.ReadModel.Rebuild (RebuildError)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (GlobalPosition)
import System.Exit (exitFailure)

main :: IO ()
main = do
    factsOk <- runReadModelFacts
    let recordOk =
            transferDecisionsReadModel.name == "hospital-capacity-transfer-decisions"
                && transferDecisionsReadModel.tableName == "transfer_decisions"
                && transferDecisionsReadModel.schema == "hospital_capacity"
                && transferDecisionsReadModel.subscriptionName == "hospital-capacity-transfer-decisions-sub"
                && transferDecisionsReadModel.version == 1
                && transferDecisionsReadModel.shapeHash == "fnv1a:3717f6d9e3c44bd6"
        consistencyOk = case transferDecisionsReadModel.defaultConsistency of
            Strong -> True
            _ -> False
        scopeOk = case transferDecisionsReadModel.strongScope of
            CategoryHead "reservation" -> True
            _ -> False
        qualifiedTableOk =
            qualifiedTableName transferDecisionsReadModel == transferDecisionsQualifiedTable
                && transferDecisionsQualifiedTable == "\"hospital_capacity\".\"transfer_decisions\""
        asyncOk =
            transferDecisionsAsyncProjection.readModelName == transferDecisionsReadModel.name
                && transferDecisionsAsyncProjection.subscriptionName == transferDecisionsReadModel.subscriptionName
                && transferDecisionsAsyncProjection.name == "hospital-capacity-transfer-decisions-async"
        allOk = factsOk && all (\(_, expected, actual) -> expected == actual) readModelFacts && recordOk && consistencyOk && scopeOk && qualifiedTableOk && asyncOk
    putStrLn ("read-model facts: " <> show factsOk)
    putStrLn ("runtime record: " <> show recordOk)
    putStrLn ("consistency/scope: " <> show (consistencyOk && scopeOk))
    putStrLn ("qualified table: " <> show qualifiedTableOk)
    putStrLn ("async identity: " <> show asyncOk)
    unless allOk exitFailure

_usesRegister :: (Store :> es) => Eff es ()
_usesRegister = registerTransferDecisions

_usesStartRebuild :: (Store :> es) => GlobalPosition -> Eff es ReadModelMetadata
_usesStartRebuild = startTransferDecisionsRebuild

_usesFinishRebuild :: (Store :> es) => GlobalPosition -> Eff es (Either RebuildError ReadModelMetadata)
_usesFinishRebuild = finishTransferDecisionsRebuild

_usesAbandonRebuild :: (Store :> es) => Eff es ReadModelMetadata
_usesAbandonRebuild = abandonTransferDecisionsRebuild
