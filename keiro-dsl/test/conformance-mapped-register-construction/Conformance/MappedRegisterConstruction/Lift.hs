module Conformance.MappedRegisterConstruction.Lift (atTime, atTimeCases) where

import Conformance.MappedRegisterConstruction.Domain (MaybeTime (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))

-- Pure and total. Change the declared write-lift version whenever behavior changes.
atTime :: UTCTime -> MaybeTime
atTime value = MaybeTime (Just value)

atTimeCases :: NonEmpty (Text, UTCTime, MaybeTime)
atTimeCases = ("epoch", epoch, MaybeTime (Just epoch)) :| [("later", later, MaybeTime (Just later))]
  where
    epoch = UTCTime (fromGregorian 1970 1 1) 0
    later = UTCTime (fromGregorian 2026 10 14) 12345
