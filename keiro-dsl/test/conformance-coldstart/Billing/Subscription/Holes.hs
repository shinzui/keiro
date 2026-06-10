{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- HAND-FILLED hole module for the EP-7 cold-start demo: a fresh `subscription`
-- aggregate authored from only the skill notation, then filled against the
-- generated signatures. The harness pins this fill.
module Billing.Subscription.Holes (
    subscriptionTransducer,
    applySubscriptions,
) where

import Generated.Billing.Subscription.Domain
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, lit, (./=))

subscriptionTransducer ::
    SymTransducer
        (HsPred SubscriptionRegs SubscriptionCommand)
        SubscriptionRegs
        SubscriptionVertex
        SubscriptionCommand
        SubscriptionEvent
subscriptionTransducer =
    B.buildTransducer SubscriptionInactive initialSubscriptionRegs isTerminal do
        B.from SubscriptionInactive do
            B.onCmd inCtorActivateSubscription $ \d -> B.do
                B.requireGuard (d.plan ./= lit Free)
                B.slot @"subscriptionState" =: lit SubscriptionActive
                B.emit
                    wireSubscriptionActivated
                    SubscriptionActivatedTermFields
                        { subscriptionId = d.subscriptionId
                        , customerId = d.customerId
                        , plan = d.plan
                        }
                B.goto SubscriptionActive
        B.from SubscriptionActive do
            B.onCmd inCtorCancelSubscription $ \d -> B.do
                B.slot @"subscriptionState" =: lit SubscriptionClosed
                B.emit
                    wireSubscriptionCancelled
                    SubscriptionCancelledTermFields
                        { subscriptionId = d.subscriptionId
                        , customerId = d.customerId
                        }
                B.goto SubscriptionClosed
  where
    isTerminal = \case
        SubscriptionClosed -> True
        _ -> False

applySubscriptions :: SubscriptionEvent -> recorded -> txn ()
applySubscriptions _event _recorded = error "HOLE: fill subscriptions projection apply"
