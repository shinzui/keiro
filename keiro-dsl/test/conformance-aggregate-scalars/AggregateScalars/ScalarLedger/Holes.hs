{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- This is a HAND-OWNED language-4 hook module. Generated code owns the
-- transition envelope, guards, writes, and lifecycle. This module supplies
-- the explicit event-field mapping requested by the source declaration.
module AggregateScalars.ScalarLedger.Holes
  ( transition1EmptyRecordOutput1ScalarsRecorded
  ) where

import Generated.AggregateScalars.ScalarLedger.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)

transition1EmptyRecordOutput1ScalarsRecorded
  :: B.PayloadProj ScalarLedgerRegs ScalarLedgerCommand (RegFieldsOf RecordData)
  -> ScalarsRecordedTermFields ScalarLedgerRegs ScalarLedgerCommand (RegFieldsOf RecordData)
transition1EmptyRecordOutput1ScalarsRecorded d =
  ScalarsRecordedTermFields
    { observedAt = d.observedAt
    , revision = d.revision
    }
