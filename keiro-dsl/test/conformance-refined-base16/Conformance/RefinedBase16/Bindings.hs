{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it.
module Conformance.RefinedBase16.Bindings
  ( maybeContentHashFixtures,
    maybeContentHashBinding,
    hashEnvelopeFixtures,
    hashEnvelopeBinding,
    initialContentHash,
    contentHashFixtures,
    contentHashBinding,
  )
where

import Conformance.RefinedBase16.Domain (ContentHash, HashEnvelope, MaybeContentHash)
import Conformance.RefinedBase16.Domain qualified as Domain
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Generated.RefinedBase16.Structural.Shape.ContentHash qualified as ShapeContentHash
import Generated.RefinedBase16.Structural.Shape.HashEnvelope qualified as ShapeHashEnvelope
import Generated.RefinedBase16.Structural.Shape.MaybeContentHash qualified as ShapeMaybeContentHash
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

initialContentHash :: ContentHash
initialContentHash = Domain.ContentHash BS.empty

contentHashFixtures :: FixtureCases ContentHash
contentHashFixtures =
  FixtureCases
    ( ("empty", initialContentHash)
        :| [ ("leading-zero", bytes [0, 175]),
             ("arbitrary-length", bytes [0, 17, 34, 51, 68]),
             ("sha256-sized", bytes [0 .. 31])
           ]
    )

contentHashBinding :: StructuralBinding ContentHash ShapeContentHash.ContentHashShape
contentHashBinding =
  StructuralBinding
    { bindingToShape = \case Domain.ContentHash value -> value,
      bindingFromShape = Domain.ContentHash
    }

maybeContentHashFixtures :: FixtureCases MaybeContentHash
maybeContentHashFixtures =
  FixtureCases
    ( ("absent", Domain.MaybeContentHash Nothing)
        :| [ ("present-empty", Domain.MaybeContentHash (Just initialContentHash)),
             ("present-leading-zero", Domain.MaybeContentHash (Just (bytes [0, 175])))
           ]
    )

maybeContentHashBinding :: StructuralBinding MaybeContentHash ShapeMaybeContentHash.MaybeContentHashShape
maybeContentHashBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.MaybeContentHash value -> unHash <$> value,
      bindingFromShape = Domain.MaybeContentHash . fmap Domain.ContentHash
    }

hashEnvelopeFixtures :: FixtureCases HashEnvelope
hashEnvelopeFixtures =
  FixtureCases
    ( ( "empty-branches",
        Domain.HashEnvelope
          initialContentHash
          Nothing
          (Domain.MaybeContentHash Nothing)
          [initialContentHash]
          (Map.fromList [("empty", initialContentHash)])
      )
        :| [ ( "nested",
               Domain.HashEnvelope
                 (bytes [0, 175])
                 (Just (bytes [255]))
                 (Domain.MaybeContentHash (Just (bytes [0, 17, 34, 51, 68])))
                 [bytes [1], bytes [2, 3, 4]]
                 (Map.fromList [("short", bytes [0]), ("longer", bytes [0 .. 7])])
             )
           ]
    )

hashEnvelopeBinding :: StructuralBinding HashEnvelope ShapeHashEnvelope.HashEnvelopeShape
hashEnvelopeBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.HashEnvelope primaryValue optionalHashValue namedOptionalValue sequenceValue labelledValue ->
          ShapeHashEnvelope.HashEnvelope
            (unHash primaryValue)
            (unHash <$> optionalHashValue)
            (bindingToShape maybeContentHashBinding namedOptionalValue)
            (map unHash sequenceValue)
            (Map.map unHash labelledValue),
      bindingFromShape = \case
        ShapeHashEnvelope.HashEnvelope primaryValue optionalHashValue namedOptionalValue sequenceValue labelledValue ->
          Domain.HashEnvelope
            (Domain.ContentHash primaryValue)
            (Domain.ContentHash <$> optionalHashValue)
            (bindingFromShape maybeContentHashBinding namedOptionalValue)
            (map Domain.ContentHash sequenceValue)
            (Map.map Domain.ContentHash labelledValue)
    }

bytes :: [Word] -> ContentHash
bytes = Domain.ContentHash . BS.pack . map fromIntegral

unHash :: ContentHash -> BS.ByteString
unHash (Domain.ContentHash value) = value
