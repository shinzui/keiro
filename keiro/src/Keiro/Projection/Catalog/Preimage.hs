{-# OPTIONS_HADDOCK hide #-}

-- | Canonical, injection-proof preimage encoding for catalog fingerprints.
module Keiro.Projection.Catalog.Preimage
  ( Preimage (..),
    renderPreimage,
    hashPreimage,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text.Encoding qualified as Text
import Keiro.Prelude

-- | A typed tree whose rendering preserves every structural boundary.
--
-- Every node starts with a distinguishing letter. Every variable-length
-- payload is preceded by its exact byte length or child count, so the rendering
-- is a prefix code over trees: two distinct trees first differ at a node where
-- the constructor letter, declared length, or payload bytes differ.
data Preimage
  = PText !Text
  | PList ![Preimage]
  | PRecord !Text ![Preimage]
  deriving stock (Eq, Ord, Show, Generic)

renderPreimage :: Preimage -> ByteString.ByteString
renderPreimage =
  LazyByteString.toStrict
    . Builder.toLazyByteString
    . renderBuilder

hashPreimage :: Text -> Preimage -> Text
hashPreimage prefix preimage =
  prefix
    <> ":"
    <> Text.decodeUtf8 (Base16.encode (SHA256.hash (renderPreimage preimage)))

renderBuilder :: Preimage -> Builder.Builder
renderBuilder = \case
  PText value ->
    let bytes = Text.encodeUtf8 value
     in Builder.char8 't'
          <> Builder.intDec (ByteString.length bytes)
          <> Builder.char8 ':'
          <> Builder.byteString bytes
  PList values ->
    Builder.char8 'l'
      <> Builder.intDec (length values)
      <> Builder.char8 ':'
      <> foldMap renderBuilder values
  PRecord tag fields ->
    let bytes = Text.encodeUtf8 tag
     in Builder.char8 'r'
          <> Builder.intDec (ByteString.length bytes)
          <> Builder.char8 ':'
          <> Builder.byteString bytes
          <> Builder.char8 'n'
          <> Builder.intDec (length fields)
          <> Builder.char8 ':'
          <> foldMap renderBuilder fields
