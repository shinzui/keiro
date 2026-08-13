-- | The seed encoding shared by Keiro's deterministic (version-5 UUID)
-- identifiers.
--
-- A deterministic id is a pure function of a seed text, so that an
-- at-least-once writer collapses to exactly one row: the workflow journal's
-- event ids, sleep timer ids, legacy awakeable ids, and process-manager
-- command ids are all derived this way. That makes the seed encoding /replay
-- identity/ — it must yield the same bytes for the same text on every deploy,
-- forever. The rule is recorded in
-- @docs\/adr\/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md@.
module Keiro.DeterministicId
  ( identitySeedBytes,
    legacySeedBytes,
    seedMovedAcrossEncodings,
    deterministicIdProbes,
  )
where

import Data.ByteString qualified as ByteString
import Data.Char (isAscii)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID (UUID)
import Data.UUID.V5 qualified as UUID.V5
import Data.Word (Word8)
import Keiro.Prelude

-- | The UTF-8 bytes of a deterministic-id seed, in the @[Word8]@ shape
-- @Data.UUID.V5.generateNamed@ expects.
--
-- UTF-8 rather than the codepoints themselves: the original derivations fed
-- @fromIntegral . fromEnum@ over @Text.unpack@ into the hash, which truncated
-- every character to its codepoint modulo 256, so @"\x0101"@ and @"\SOH"@ (and
-- countless CJK pairs) hashed identically and could be assigned one id. For
-- pure-ASCII seeds UTF-8 bytes /are/ the codepoint values, so every id derived
-- from an ASCII seed is byte-identical to what the truncating encoding
-- produced; only non-ASCII seeds move, and they move off a collision.
--
-- This function is frozen. Changing it renames every deterministic id in every
-- deployment, which no amount of retrying recovers from, so a future change
-- needs an explicit versioned derivation and a migration story rather than an
-- edit here.
identitySeedBytes :: Text -> [Word8]
identitySeedBytes = ByteString.unpack . Text.Encoding.encodeUtf8

-- | The pre-0.12 deterministic-id seed encoding.
--
-- This deliberately reproduces the historical @Char -> Word8@ truncation so
-- deployed identifiers can be probed during the compatibility window. It is a
-- frozen reader for old identity, not an encoding for new writes.
legacySeedBytes :: Text -> [Word8]
legacySeedBytes = fmap (fromIntegral . fromEnum) . Text.unpack

-- | Whether UTF-8 and the historical seed encoding can produce different
-- bytes for this seed. ASCII is byte-identical under both encodings.
seedMovedAcrossEncodings :: Text -> Bool
seedMovedAcrossEncodings = not . Text.all isAscii

-- | Ordered candidate ids for one deterministic-id seed under the ADR 24
-- compatibility bridge: the current UTF-8-derived id first, the frozen
-- pre-UTF-8 id second only when the seed's bytes differ across encodings.
-- This is the single source of truth for the dual-probe policy; call sites
-- must not restate the ordering or the moved-seed condition.
deterministicIdProbes :: Text -> NonEmpty UUID
deterministicIdProbes seed =
  UUID.V5.generateNamed UUID.V5.namespaceURL (identitySeedBytes seed)
    :| [ UUID.V5.generateNamed UUID.V5.namespaceURL (legacySeedBytes seed)
       | seedMovedAcrossEncodings seed
       ]
