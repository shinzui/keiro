{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module IncidentPaging.Page.Holes (
    pageTransducer,
    -- (no projection)
) where

import Generated.IncidentPaging.Page.Domain
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)

-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
pageTransducer ::
    SymTransducer
        (HsPred PageRegs PageCommand)
        PageRegs
        PageVertex
        PageCommand
        PageEvent
pageTransducer =
    B.buildTransducer PagePending initialPageRegs isTerminal do
        B.from PagePending do
            B.onCmd inCtorSendPage $ \d -> B.do
                B.emit wirePageSent PageSentTermFields{incidentId = d.incidentId, responderId = d.responderId}
                B.goto PageDelivered
  where
    isTerminal = \case
        PageDelivered -> True
        _ -> False
