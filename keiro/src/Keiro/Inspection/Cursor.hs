module Keiro.Inspection.Cursor
  ( InspectionCursor (..),
    CursorError (..),
    maxCursorBytes,
    encodeCursor,
    encodeCursorBounded,
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

maxCursorBytes :: Int
maxCursorBytes = 4096

encodeCursor :: (ToJSON payload) => Text -> payload -> InspectionCursor
encodeCursor kind payload = encodedCursor (cursorJson kind payload)

-- | Page producers must not emit a continuation the decoder would reject.
-- Demand only the maximum representable JSON prefix before base64 encoding.
encodeCursorBounded :: (ToJSON payload) => Text -> payload -> Maybe InspectionCursor
encodeCursorBounded kind payload =
  let decodedLimit = maxCursorBytes * 3 `div` 4
      prefix = LazyByteString.take (fromIntegral decodedLimit + 1) (cursorJson kind payload)
   in if LazyByteString.length prefix > fromIntegral decodedLimit then Nothing else Just (encodedCursor prefix)

cursorJson :: (ToJSON payload) => Text -> payload -> LazyByteString.ByteString
cursorJson kind payload = encode (object ["k" .= kind, "v" .= payload])

encodedCursor :: LazyByteString.ByteString -> InspectionCursor
encodedCursor = InspectionCursor . Text.decodeUtf8 . Base64.encodeUnpadded . LazyByteString.toStrict

decodeCursor :: (FromJSON payload) => Text -> InspectionCursor -> Either CursorError payload
decodeCursor expected (InspectionCursor token)
  -- Check character count before UTF-8 encoding, then the actual encoded bytes.
  | Text.length token > maxCursorBytes = Left (MalformedCursor "cursor exceeds 4096 encoded bytes")
  | ByteString.length bytes > maxCursorBytes = Left (MalformedCursor "cursor exceeds 4096 encoded bytes")
  | otherwise = do
      decoded <- malformed (Base64.decodeUnpadded bytes)
      value <- malformed (eitherDecodeStrict' decoded)
      (kind, payload) <- malformed (parseEither (withObject "inspection cursor" (\obj -> (,) <$> obj .: "k" <*> obj .: "v")) value)
      if kind /= expected then Left (CursorKindMismatch expected kind) else malformed (parseEither parseJSONValue payload)
  where
    bytes = Text.encodeUtf8 token
    malformed = either (Left . MalformedCursor . Text.pack) Right
    parseJSONValue = parseJSON
