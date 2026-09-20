-- | Public codecs for Keiro-owned refined representation policies.
--
-- The first policy is unrestricted bytes encoded as base16 text. Keeping the
-- refinement entry point separate from structural and nominal codecs prevents
-- consumer validation callbacks from masquerading as total bindings.
module Keiro.Codec.Refined
  ( Base16BytesError (..),
    base16BytesCodecPolicyIdentity,
    decodeBase16BytesText,
    encodeBase16Bytes,
    parseBase16Bytes,
    renderBase16Bytes,
  )
where

import Keiro.Codec.Base16Bytes
