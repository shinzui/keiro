-- | Frozen JSON policy for sets of Unicode text values.
--
-- The writer emits one JSON string per distinct element in lexicographic
-- Unicode code-point order. The reader accepts any array order and duplicate
-- strings, and normalizes them to a 'Set' before the value reaches generated
-- bindings or transducers. No Unicode normalization or case folding occurs.
module Keiro.Codec.TextSet
  ( textSetCodecPolicyIdentity,
    encodeTextSet,
    parseTextSet,
  )
where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value)
import Data.Aeson.Types (Parser)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

-- | Stable identity for the complete text-set JSON policy.
--
-- This identity is part of generated mapped-wire fingerprints. Changing the
-- accepted domain, duplicate policy, ordering, normalization, case handling,
-- or emitted bytes requires a successor identity and a retained v1 reader.
textSetCodecPolicyIdentity :: Text
textSetCodecPolicyIdentity = "keiro-core/text-set/1"

-- | Encode a set as an ascending, duplicate-free JSON string array.
--
-- 'Text' ordering is lexicographic Unicode code-point order. In particular,
-- U+E000 sorts before U+10000; this is not UTF-16 code-unit ordering.
encodeTextSet :: Set Text -> Value
encodeTextSet = toJSON . Set.toAscList

-- | Parse the v1 historical read language.
--
-- Array order and duplicates are deliberately insignificant. JSON validation
-- still happens before set construction, so non-array input and non-string
-- elements fail with Aeson's located parser diagnostics.
parseTextSet :: Value -> Parser (Set Text)
parseTextSet value = Set.fromList <$> parseJSON value
