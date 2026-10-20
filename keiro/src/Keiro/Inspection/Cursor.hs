module Keiro.Inspection.Cursor
  ( InspectionCursor (..),
    CursorError (..),
    encodeCursor,
    decodeCursor,
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode, object, parseJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64.URL qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)

-- | An opaque, kind-bound continuation. Clients only echo it to the same read.
newtype InspectionCursor = InspectionCursor {cursorText :: Text}
  deriving stock (Eq, Show, Generic)

data CursorError = MalformedCursor !Text | CursorKindMismatch !Text !Text
  deriving stock (Eq, Show, Generic)

encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
encodeCursor kind payload = InspectionCursor (Text.decodeUtf8 (Base64.encodeUnpadded (LazyByteString.toStrict (encode (object ["k" .= kind, "v" .= payload])))))

decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
decodeCursor expected (InspectionCursor token)
  -- Check character count before UTF-8 encoding, then the actual encoded bytes.
  | Text.length token > 4096 = Left (MalformedCursor "cursor exceeds 4096 encoded bytes")
  | ByteString.length bytes > 4096 = Left (MalformedCursor "cursor exceeds 4096 encoded bytes")
  | otherwise = do
      decoded <- malformed (Base64.decodeUnpadded bytes)
      value <- malformed (eitherDecodeStrict' decoded)
      (kind, payload) <- malformed (parseEither (withObject "inspection cursor" (\obj -> (,) <$> obj .: "k" <*> obj .: "v")) value)
      if kind /= expected then Left (CursorKindMismatch expected kind) else malformed (parseEither parseJSONValue payload)
  where
    bytes = Text.encodeUtf8 token
    malformed = either (Left . MalformedCursor . Text.pack) Right
    parseJSONValue = parseJSON
