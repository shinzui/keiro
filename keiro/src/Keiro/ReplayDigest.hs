{- | Stable canonical encodings and SHA-256 digests for replay comparisons.

Canonicalization is Aeson's RFC 8785 implementation. Hashing is the maintained
@cryptohash-sha256@ implementation of FIPS 180-4, and hexadecimal rendering is
@base16-bytestring@'s RFC 4648 encoder. Correctness comparisons still use the
canonical bytes directly; the digest is their compact operator-facing
identifier.
-}
module Keiro.ReplayDigest (
    canonicalJsonBytes,
    replayDigest,
) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson.RFC8785 qualified as RFC8785
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text.Encoding qualified as Text
import Keiro.Prelude

-- | Render a JSON value in RFC 8785 canonical form.
canonicalJsonBytes :: Value -> ByteString
canonicalJsonBytes = LazyByteString.toStrict . RFC8785.encodeCanonical

-- | SHA-256 over RFC 8785 canonical JSON, rendered as lower-case hexadecimal.
replayDigest :: Value -> Text
replayDigest =
    Text.decodeUtf8
        . Base16.encode
        . SHA256.hash
        . canonicalJsonBytes
