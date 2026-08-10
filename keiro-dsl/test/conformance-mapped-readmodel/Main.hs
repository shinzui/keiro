{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Conformance.MappedReadModel.Domain (AccountLookup, AccountSummary, fixtureAccountLookup)
import Control.Monad (forM_, unless)
import Generated.MappedReadmodel.AccountSummary.QueryContract (AccountSummaryQueryInput, AccountSummaryQueryResult)
import Generated.MappedReadmodel.AccountSummary.ReadModel (accountSummaryReadModel)
import Generated.MappedReadmodel.AccountSummary.ReadModelHarness (runReadModelFacts)
import Generated.MappedReadmodel.StructuralConformance (structuralConformanceAssertions)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModel (..))
import MappedReadmodel.AccountSummary.ReadModelHoles (accountSummaryQuery)
import System.Exit (exitFailure)

main :: IO ()
main = do
  readModelFactsOk <- runReadModelFacts
  let queryInput :: AccountSummaryQueryInput
      queryInput = fixtureAccountLookup
      queryContractOk = queryInput == fixtureAccountLookup
      runtimeTypeOk = accountSummaryReadModel.name == "mapped-readmodel-account-summary"
      assertions =
        [ ("generated query input is AccountLookup", queryContractOk),
          ("generated ReadModel carries the typed query", runtimeTypeOk),
          ("read-model runtime facts", readModelFactsOk)
        ]
          <> [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

_queryReturnsMappedDomain :: AccountLookup -> Tx.Transaction (Maybe AccountSummary)
_queryReturnsMappedDomain = accountSummaryQuery

_generatedContractAgrees :: AccountSummaryQueryInput -> Tx.Transaction AccountSummaryQueryResult
_generatedContractAgrees = accountSummaryQuery
