{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- HAND-FILLED language-4 hooks for the EP-7 cold-start demo. Generated code
-- owns the transition lifecycle; this module contains only the explicit event
-- mapping and the projection integration point.
module Billing.Subscription.Holes
  ( transition2ActiveCancelSubscriptionOutput1SubscriptionCancelled
  , applySubscriptions
  ) where

import Generated.Billing.Subscription.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)

transition2ActiveCancelSubscriptionOutput1SubscriptionCancelled
  :: B.PayloadProj SubscriptionRegs SubscriptionCommand (RegFieldsOf CancelSubscriptionData)
  -> SubscriptionCancelledTermFields SubscriptionRegs SubscriptionCommand (RegFieldsOf CancelSubscriptionData)
transition2ActiveCancelSubscriptionOutput1SubscriptionCancelled d =
  SubscriptionCancelledTermFields
    { subscriptionId = d.subscriptionId
    , customerId = d.customerId
    }

applySubscriptions :: SubscriptionEvent -> recorded -> txn ()
applySubscriptions _event _recorded = error "HOLE: fill subscriptions projection apply"
