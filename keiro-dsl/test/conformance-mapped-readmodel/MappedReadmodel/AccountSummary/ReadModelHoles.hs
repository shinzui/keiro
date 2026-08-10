-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module MappedReadmodel.AccountSummary.ReadModelHoles
  ( accountSummaryQuery,
  )
where

import Conformance.MappedReadModel.Domain (fixtureAccountSummary)
import Generated.MappedReadmodel.AccountSummary.QueryContract (AccountSummaryQueryInput, AccountSummaryQueryResult)
import Generated.MappedReadmodel.AccountSummary.ReadModelTable (accountSummaryQualifiedTable)
import Hasql.Transaction qualified as Tx

accountSummaryQuery :: AccountSummaryQueryInput -> Tx.Transaction AccountSummaryQueryResult
accountSummaryQuery _input =
  accountSummaryQualifiedTable `seq` pure (Just fixtureAccountSummary)
