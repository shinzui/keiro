{-# LANGUAGE GADTs #-}

{- | Replay-audit assembly for a hand-written service.

Unlike a keiro-dsl service, hand-written code has no spec diff from which to
derive an affected event set. It must supply a conservative 'AffectedSet' or
run 'AuditFull'. The target assembly itself remains mechanical and should
include every aggregate family the candidate binary may hydrate, including
process-manager saga aggregates.
-}
module Jitsurei.ReplayAudit (
    replayAuditTargets,
) where

import Jitsurei.EscalationProcess (escalationEventStream)
import Jitsurei.OrderStream (orderEventStream)
import Keiro.ReplayAudit (AuditTarget (..), SomeAuditTarget (..), streamInCategory)

-- | The Order aggregate and the escalation process manager's saga aggregate.
replayAuditTargets :: [SomeAuditTarget]
replayAuditTargets =
    [ SomeAuditTarget
        AuditTarget
            { eventStream = orderEventStream
            , category = "order"
            , mkStream = streamInCategory "order"
            }
    , SomeAuditTarget
        AuditTarget
            { eventStream = escalationEventStream
            , category = "esc"
            , mkStream = streamInCategory "esc"
            }
    ]
