{- | Deterministic identities derived from a first-class read-model declaration.
The validator, scaffolder, harness, and differ share these functions so captured
fixtures and generated runtime values cannot silently disagree.
-}
module Keiro.Dsl.ReadModelShape (
    canonicalShape,
    deriveShapeHash,
    registryNameFor,
    subscriptionNameFor,
) where

import Data.Bits (shiftR, xor, (.&.), (.|.))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Keiro.Dsl.Grammar (Name, ReadModelNode (..), RmColumn (..))
import Numeric (showHex)

-- | The ordered table-and-column identity hashed into 'deriveShapeHash'.
canonicalShape :: ReadModelNode -> Text
canonicalShape readModel =
    T.intercalate "|" (rmTable readModel : map columnSegment (rmColumns readModel))
  where
    columnSegment columnDecl =
        T.intercalate
            ":"
            [ rmcName columnDecl
            , rmcType columnDecl
            , if rmcRequired columnDecl then "req" else "null"
            ]

-- | A fixed-width FNV-1a-64 digest over the canonical shape's UTF-8 bytes.
deriveShapeHash :: ReadModelNode -> Text
deriveShapeHash readModel =
    "fnv1a:" <> T.justifyRight 16 '0' (T.pack (showHex digest ""))
  where
    digest = foldl' step offsetBasis (concatMap utf8Bytes (T.unpack (canonicalShape readModel)))
    step hash byte = (hash `xor` byte) * fnvPrime

-- | The runtime registry identity derived from context and notation name.
registryNameFor :: Name -> ReadModelNode -> Text
registryNameFor contextName readModel =
    contextName <> "-" <> T.replace "_" "-" (rmName readModel)

-- | The explicit subscription override or its deterministic default.
subscriptionNameFor :: Name -> ReadModelNode -> Text
subscriptionNameFor contextName readModel =
    fromMaybe (registryNameFor contextName readModel <> "-sub") (rmSubscription readModel)

offsetBasis :: Word64
offsetBasis = 0xcbf29ce484222325

fnvPrime :: Word64
fnvPrime = 0x100000001b3

{- | Encode one Unicode scalar value as UTF-8 bytes, represented as 'Word64'
values so the hash fold needs no bytestring package dependency.
-}
utf8Bytes :: Char -> [Word64]
utf8Bytes character
    | codePoint <= 0x7f = [byte codePoint]
    | codePoint <= 0x7ff =
        [ byte (0xc0 .|. (codePoint `shiftR` 6))
        , continuation codePoint
        ]
    | codePoint <= 0xffff =
        [ byte (0xe0 .|. (codePoint `shiftR` 12))
        , continuation (codePoint `shiftR` 6)
        , continuation codePoint
        ]
    | otherwise =
        [ byte (0xf0 .|. (codePoint `shiftR` 18))
        , continuation (codePoint `shiftR` 12)
        , continuation (codePoint `shiftR` 6)
        , continuation codePoint
        ]
  where
    codePoint = fromEnum character
    byte = fromIntegral
    continuation value = byte (0x80 .|. (value .&. 0x3f))
