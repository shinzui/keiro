module Conformance.MappedRegisterConstruction.Bindings (noTime, maybeTimeCases) where

import Conformance.MappedRegisterConstruction.Domain (MaybeTime (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Keiro.Codec.Structural (FixtureCases (..))

noTime :: MaybeTime
noTime = MaybeTime Nothing

maybeTimeCases :: FixtureCases MaybeTime
maybeTimeCases = FixtureCases (("none", noTime) :| [("present", MaybeTime (Just (UTCTime (fromGregorian 2026 10 14) 0)))])
