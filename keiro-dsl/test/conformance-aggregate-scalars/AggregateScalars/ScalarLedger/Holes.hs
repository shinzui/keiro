{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. The generated harness pins this implementation's scalar
-- guards, writes, event, and forward/replay behavior.
module AggregateScalars.ScalarLedger.Holes (
    scalarLedgerTransducer,
    dishonestWireScalarsRecorded,
    -- (no projection)
) where

import Data.Time.Clock (UTCTime)
import Generated.AggregateScalars.ScalarLedger.Domain
import Keiki.Builder ((=:))
import qualified Keiki.Builder as B
import Keiki.Core (HsPred, SymTransducer, WireCtor (..), (.&&), (.==), (.>=))
import Numeric.Natural (Natural)

scalarLedgerTransducer ::
    SymTransducer
        (HsPred ScalarLedgerRegs ScalarLedgerCommand)
        ScalarLedgerRegs
        ScalarLedgerVertex
        ScalarLedgerCommand
        ScalarLedgerEvent
scalarLedgerTransducer =
    B.buildTransducer ScalarLedgerEmpty initialScalarLedgerRegs isTerminal do
        B.from ScalarLedgerEmpty do
            B.onCmd inCtorRecord $ \d -> B.do
                B.requireGuard
                    ( d.observedAt
                        .== d.observedAt
                        .&& d.observedAt
                        .>= d.observedAt
                        .&& d.revision
                        .== d.revision
                        .&& d.revision
                        .>= d.revision
                    )
                B.slot @"observedAt" =: d.observedAt
                B.slot @"revision" =: d.revision
                B.emit
                    emitWire
                    ScalarsRecordedTermFields
                        { observedAt = d.observedAt
                        , revision = d.revision
                        }
                B.goto ScalarLedgerRecorded
  where
    isTerminal = \case
        ScalarLedgerRecorded -> True
        _ -> False

-- The mutation test changes this indirection to the dormant dishonest ctor.
emitWire :: WireCtor ScalarLedgerEvent (UTCTime, (Natural, ()))
emitWire = wireScalarsRecorded

-- This builder pins every revision to one. The rewrite is idempotent, while
-- the unchanged output terms still prove both command fields were recovered.
dishonestWireScalarsRecorded :: WireCtor ScalarLedgerEvent (UTCTime, (Natural, ()))
dishonestWireScalarsRecorded =
    wireScalarsRecorded
        { wcBuild = wcBuild wireScalarsRecorded . forceRevisionOne
        }

forceRevisionOne :: (UTCTime, (Natural, ())) -> (UTCTime, (Natural, ()))
forceRevisionOne (observedAtValue, (_revisionValue, ())) =
    (observedAtValue, (1, ()))
