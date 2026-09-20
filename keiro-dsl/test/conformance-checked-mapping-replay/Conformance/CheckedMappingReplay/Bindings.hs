{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module Conformance.CheckedMappingReplay.Bindings (
    textLabelsFixtures
  , textLabelsBinding
  , initialReplayEnvelope
  , replayEnvelopeFixtures
  , replayEnvelopeBinding
  , maybeLabelFixtures
  , maybeLabelBinding
  , maybeContentHashFixtures
  , maybeContentHashBinding
  , importantDaysFixtures
  , importantDaysBinding
  , contentHashFixtures
  , contentHashBinding
) where

import Conformance.CheckedMappingReplay.Domain (ContentHash, ImportantDays, MaybeContentHash, MaybeLabel, ReplayEnvelope, TextLabels)
import Conformance.CheckedMappingReplay.Domain qualified as Domain
import Generated.CheckedMappingReplay.Structural.Shape.ContentHash qualified as ShapeContentHash
import Generated.CheckedMappingReplay.Structural.Shape.ImportantDays qualified as ShapeImportantDays
import Generated.CheckedMappingReplay.Structural.Shape.MaybeContentHash qualified as ShapeMaybeContentHash
import Generated.CheckedMappingReplay.Structural.Shape.MaybeLabel qualified as ShapeMaybeLabel
import Generated.CheckedMappingReplay.Structural.Shape.ReplayEnvelope qualified as ShapeReplayEnvelope
import Generated.CheckedMappingReplay.Structural.Shape.TextLabels qualified as ShapeTextLabels
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Generated.CheckedMappingReplay.Nominals (RetainedId, parseRetainedId)
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

-- HOLE: provide deterministic labelled conformance fixtures for TextLabels
textLabelsFixtures :: FixtureCases TextLabels
textLabelsFixtures =
  FixtureCases
    ( ("empty", Domain.TextLabels Set.empty)
        :| [ ("ordinary", Domain.TextLabels (Set.fromList ["a", "b"])),
             ("code-point-order", Domain.TextLabels (Set.fromList ["\x10000", "\xE000", "ä", "a\x0308", "a", "A"]))
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
textLabelsBinding :: StructuralBinding TextLabels ShapeTextLabels.TextLabelsShape
textLabelsBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.TextLabels value -> value
    , bindingFromShape = \case
      value -> Domain.TextLabels value
    }

-- HOLE: provide the initial register value for ReplayEnvelope
initialReplayEnvelope :: ReplayEnvelope
initialReplayEnvelope =
  Domain.ReplayEnvelope
    (Domain.MaybeLabel Nothing)
    (Domain.ImportantDays [fromGregorian 1970 1 1])
    (Domain.TextLabels Set.empty)
    (Domain.MaybeContentHash Nothing)
    retainedV7
    (Map.singleton retainedV7 "current")
    Nothing

-- HOLE: provide deterministic labelled conformance fixtures for ReplayEnvelope
replayEnvelopeFixtures :: FixtureCases ReplayEnvelope
replayEnvelopeFixtures =
  FixtureCases
    ( ("initial", initialReplayEnvelope)
        :| [
             ( "mixed-history",
               Domain.ReplayEnvelope
                 (Domain.MaybeLabel (Just "retained"))
                 (Domain.ImportantDays [fromGregorian 2000 2 29, fromGregorian 12345678901234567890 6 30])
                 (Domain.TextLabels (Set.fromList ["b", "a"]))
                 (Domain.MaybeContentHash (Just (bytes [0, 175])))
                 retainedV5
                 (Map.fromList [(retainedV5, "historical-v5"), (retainedV7, "current-v7")])
                 (Just (Set.fromList ["optional", "labels"]))
             )
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
replayEnvelopeBinding :: StructuralBinding ReplayEnvelope ShapeReplayEnvelope.ReplayEnvelopeShape
replayEnvelopeBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.ReplayEnvelope labelValue daysValue labelsValue contentHashValue primaryValue identitiesValue optionalLabelsValue ->
        ShapeReplayEnvelope.ReplayEnvelope
          (bindingToShape maybeLabelBinding labelValue)
          (bindingToShape importantDaysBinding daysValue)
          (bindingToShape textLabelsBinding labelsValue)
          (bindingToShape maybeContentHashBinding contentHashValue)
          primaryValue
          identitiesValue
          optionalLabelsValue
    , bindingFromShape = \case
      ShapeReplayEnvelope.ReplayEnvelope labelValue daysValue labelsValue contentHashValue primaryValue identitiesValue optionalLabelsValue ->
        Domain.ReplayEnvelope
          (bindingFromShape maybeLabelBinding labelValue)
          (bindingFromShape importantDaysBinding daysValue)
          (bindingFromShape textLabelsBinding labelsValue)
          (bindingFromShape maybeContentHashBinding contentHashValue)
          primaryValue
          identitiesValue
          optionalLabelsValue
    }

-- HOLE: provide deterministic labelled conformance fixtures for MaybeLabel
maybeLabelFixtures :: FixtureCases MaybeLabel
maybeLabelFixtures = FixtureCases (("absent", Domain.MaybeLabel Nothing) :| [("present", Domain.MaybeLabel (Just "label"))])

-- HOLE: complete both total directions; wire policy remains in the generated codec.
maybeLabelBinding :: StructuralBinding MaybeLabel ShapeMaybeLabel.MaybeLabelShape
maybeLabelBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.MaybeLabel value -> value
    , bindingFromShape = \case
      value -> Domain.MaybeLabel value
    }

-- HOLE: provide deterministic labelled conformance fixtures for MaybeContentHash
maybeContentHashFixtures :: FixtureCases MaybeContentHash
maybeContentHashFixtures =
  FixtureCases
    ( ("absent", Domain.MaybeContentHash Nothing)
        :| [("empty", Domain.MaybeContentHash (Just (bytes []))), ("leading-zero", Domain.MaybeContentHash (Just (bytes [0, 175])))]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
maybeContentHashBinding :: StructuralBinding MaybeContentHash ShapeMaybeContentHash.MaybeContentHashShape
maybeContentHashBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.MaybeContentHash value -> (\(Domain.ContentHash rawBytes) -> rawBytes) <$> value
    , bindingFromShape = \case
      value -> Domain.MaybeContentHash (Domain.ContentHash <$> value)
    }

-- HOLE: provide deterministic labelled conformance fixtures for ImportantDays
importantDaysFixtures :: FixtureCases ImportantDays
importantDaysFixtures =
  FixtureCases
    ( ("empty", Domain.ImportantDays [])
        :| [ ("leap-day", Domain.ImportantDays [fromGregorian 2000 2 29]),
             ("full-carrier", Domain.ImportantDays [fromGregorian (-1) 1 1, fromGregorian 12345678901234567890 6 30])
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
importantDaysBinding :: StructuralBinding ImportantDays ShapeImportantDays.ImportantDaysShape
importantDaysBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.ImportantDays value -> value
    , bindingFromShape = \case
      value -> Domain.ImportantDays value
    }

-- HOLE: provide deterministic labelled conformance fixtures for ContentHash
contentHashFixtures :: FixtureCases ContentHash
contentHashFixtures =
  FixtureCases
    ( ("empty", bytes [])
        :| [("leading-zero", bytes [0, 175]), ("arbitrary-length", bytes [0, 17, 34, 51, 68])]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
contentHashBinding :: StructuralBinding ContentHash ShapeContentHash.ContentHashShape
contentHashBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.ContentHash value -> value
    , bindingFromShape = \case
      value -> Domain.ContentHash value
    }

retainedV5Text, retainedV7Text :: Text
retainedV5Text = "retained_58kj0y515rbwebzaxwzzknjqnk"
retainedV7Text = "retained_01h455vb4pex5vsknk084sn02q"

retainedV5, retainedV7 :: RetainedId
retainedV5 = committedId retainedV5Text
retainedV7 = committedId retainedV7Text

bytes :: [Word] -> ContentHash
bytes = Domain.ContentHash . BS.pack . map fromIntegral

committedId :: Text -> RetainedId
committedId value = case parseRetainedId value of
  Right parsed -> parsed
  Left reason -> error ("invalid committed RetainedId fixture: " <> show reason)
