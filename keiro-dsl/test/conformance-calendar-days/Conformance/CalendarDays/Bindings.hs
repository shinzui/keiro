{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module Conformance.CalendarDays.Bindings (
    maybeLocalDayFixtures
  , maybeLocalDayBinding
  , initialLocalDay
  , localDayFixtures
  , localDayBinding
  , calendarEnvelopeFixtures
  , calendarEnvelopeBinding
) where

import Conformance.CalendarDays.Domain (CalendarEnvelope, LocalDay, MaybeLocalDay)
import Conformance.CalendarDays.Domain qualified as Domain
import Generated.CalendarDays.Structural.Shape.CalendarEnvelope qualified as ShapeCalendarEnvelope
import Generated.CalendarDays.Structural.Shape.LocalDay qualified as ShapeLocalDay
import Generated.CalendarDays.Structural.Shape.MaybeLocalDay qualified as ShapeMaybeLocalDay
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time.Calendar (fromGregorian)
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

-- HOLE: provide deterministic labelled conformance fixtures for MaybeLocalDay
maybeLocalDayFixtures :: FixtureCases MaybeLocalDay
maybeLocalDayFixtures =
  FixtureCases
    ( ("absent", Domain.MaybeLocalDay Nothing)
        :| [ ("leap-day", Domain.MaybeLocalDay (Just (fromGregorian 2000 2 29))),
             ("year-zero", Domain.MaybeLocalDay (Just (fromGregorian 0 1 1)))
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
maybeLocalDayBinding :: StructuralBinding MaybeLocalDay ShapeMaybeLocalDay.MaybeLocalDayShape
maybeLocalDayBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.MaybeLocalDay value -> value
    , bindingFromShape = \case
      value -> Domain.MaybeLocalDay value
    }

-- HOLE: provide the initial register value for LocalDay
initialLocalDay :: LocalDay
initialLocalDay = Domain.LocalDay (fromGregorian 1970 1 1)

-- HOLE: provide deterministic labelled conformance fixtures for LocalDay
localDayFixtures :: FixtureCases LocalDay
localDayFixtures =
  FixtureCases
    ( ("epoch", initialLocalDay)
        :| [ ("leap-day", Domain.LocalDay (fromGregorian 2000 2 29)),
             ("year-zero", Domain.LocalDay (fromGregorian 0 12 31)),
             ("negative-year", Domain.LocalDay (fromGregorian (-1) 1 1)),
             ("extended-year", Domain.LocalDay (fromGregorian 12345678901234567890 6 30))
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
localDayBinding :: StructuralBinding LocalDay ShapeLocalDay.LocalDayShape
localDayBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.LocalDay value -> value
    , bindingFromShape = \case
      value -> Domain.LocalDay value
    }

-- HOLE: provide deterministic labelled conformance fixtures for CalendarEnvelope
calendarEnvelopeFixtures :: FixtureCases CalendarEnvelope
calendarEnvelopeFixtures =
  FixtureCases
    ( ( "absent-optional",
        Domain.CalendarEnvelope
          (fromGregorian 2000 2 29)
          Nothing
          (Domain.MaybeLocalDay Nothing)
          [fromGregorian 1900 2 28, fromGregorian 1900 3 1]
          (Map.fromList [("year-zero", fromGregorian 0 1 1)])
      )
        :| [ ( "complete-carrier",
               Domain.CalendarEnvelope
                 (fromGregorian (-12345) 12 31)
                 (Just (fromGregorian 12345678901234567890 6 30))
                 (Domain.MaybeLocalDay (Just (fromGregorian 2026 1 31)))
                 [fromGregorian 2026 1 31, fromGregorian 2026 2 1]
                 (Map.fromList [("leap", fromGregorian 2000 2 29)])
             )
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
calendarEnvelopeBinding :: StructuralBinding CalendarEnvelope ShapeCalendarEnvelope.CalendarEnvelopeShape
calendarEnvelopeBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.CalendarEnvelope primaryValue optionalDayValue namedOptionalValue sequenceValue labelledValue ->
        ShapeCalendarEnvelope.CalendarEnvelope
          primaryValue
          optionalDayValue
          (bindingToShape maybeLocalDayBinding namedOptionalValue)
          sequenceValue
          labelledValue
    , bindingFromShape = \case
      ShapeCalendarEnvelope.CalendarEnvelope primaryValue optionalDayValue namedOptionalValue sequenceValue labelledValue ->
        Domain.CalendarEnvelope
          primaryValue
          optionalDayValue
          (bindingFromShape maybeLocalDayBinding namedOptionalValue)
          sequenceValue
          labelledValue
    }
