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
  )
where

import Data.ByteString qualified as ByteString
import Data.Text.Encoding qualified as Text.Encoding
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
