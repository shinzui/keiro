{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Conformance.CalendarDays.Domain where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Proxy (Proxy)
import Data.Text (Text)
import Data.Time.Calendar (Day)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype LocalDay = LocalDay {unLocalDay :: Day}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName LocalDay where
  canonicalTypeName :: Proxy LocalDay -> Text
  canonicalTypeName _ = "conformance.calendar-days.LocalDay.v1"

newtype MaybeLocalDay = MaybeLocalDay {unMaybeLocalDay :: Maybe Day}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName MaybeLocalDay where
  canonicalTypeName :: Proxy MaybeLocalDay -> Text
  canonicalTypeName _ = "conformance.calendar-days.MaybeLocalDay.v1"

data CalendarEnvelope = CalendarEnvelope
  { primary :: !Day,
    optionalDay :: !(Maybe Day),
    namedOptional :: !MaybeLocalDay,
    sequence :: ![Day],
    labelled :: !(Map Text Day)
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName CalendarEnvelope where
  canonicalTypeName :: Proxy CalendarEnvelope -> Text
  canonicalTypeName _ = "conformance.calendar-days.CalendarEnvelope.v1"
