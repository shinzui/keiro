-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module DomainOutcomes.Reservation.BehaviorHoles (behaviorWitnesses) where

import Generated.DomainOutcomes.Reservation.BehaviorContract
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Generated.DomainOutcomes.Nominals (ReservationNoOp (..), ReservationRejection (..))
import Generated.DomainOutcomes.Reservation.Domain

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ live "behavior-v1-0b1588f69a27bc77" [] firstRequest (Emits (cancelled "request-1" :| [])),
    live "behavior-v1-316c9e96fc1a94b1" cancelledHistory secondRequest (RejectedWith AlreadyCancelled),
    live "behavior-v1-fd391b55fbbfa640" cancelledHistory firstRequest (NoOpWith DuplicateRequest)
  ]

live :: Text -> [ReservationEvent] -> ReservationCommand -> LiveExpectation -> BehaviorWitness
live rawKey history command expectation =
  LiveWitness (BehaviorKey rawKey) history command expectation

cancelledHistory :: [ReservationEvent]
cancelledHistory = [cancelled "request-1"]

firstRequest :: ReservationCommand
firstRequest = Cancel (CancelData "request-1")

secondRequest :: ReservationCommand
secondRequest = Cancel (CancelData "request-2")

cancelled :: Text -> ReservationEvent
cancelled requestIdValue = Cancelled (CancelledData requestIdValue)
