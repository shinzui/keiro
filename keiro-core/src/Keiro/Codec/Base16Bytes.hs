-- | Frozen JSON policy for unrestricted byte strings encoded as base16 text.
--
-- The reader accepts upper- and lowercase ASCII hexadecimal digits and the
-- empty string. The writer always emits lowercase text. Prefixes, whitespace,
-- odd-length inputs, and non-hexadecimal digits are rejected before a consumer
-- binding receives the decoded bytes.
module Keiro.Codec.Base16Bytes
  ( Base16BytesError (..),
    base16BytesCodecPolicyIdentity,
    decodeBase16BytesText,
    encodeBase16Bytes,
    parseBase16Bytes,
    renderBase16Bytes,
  )
where

import Data.Aeson (Value (String), withText)
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)

-- | Stable identity embedded in checked mapped wire fingerprints.
base16BytesCodecPolicyIdentity :: Text
base16BytesCodecPolicyIdentity = "keiro-core/base16-bytes/1"

-- | Stable failure categories for the pure base16 reader.
data Base16BytesError
  = Base16BytesOddLength !Int
  | Base16BytesInvalidDigit !Int !Char
  deriving stock (Eq, Show)

-- | Render bytes as lowercase base16 without adding a prefix.
renderBase16Bytes :: ByteString -> Text
renderBase16Bytes = T.pack . concatMap renderByte . BS.unpack
  where
    renderByte byte = [hexDigit (byte `div` 16), hexDigit (byte `mod` 16)]
    hexDigit nibble
      | nibble < 10 = chr (ord '0' + fromIntegral nibble)
      | otherwise = chr (ord 'a' + fromIntegral nibble - 10)

-- | Decode an even-length base16 string into exactly the represented bytes.
decodeBase16BytesText :: Text -> Either Base16BytesError ByteString
decodeBase16BytesText input
  | odd inputLength = Left (Base16BytesOddLength inputLength)
  | otherwise = BS.pack <$> go 0 (T.unpack input)
  where
    inputLength = T.length input
    go _ [] = Right []
    go index (high : low : rest) = do
      highNibble <- decodeDigit index high
      lowNibble <- decodeDigit (index + 1) low
      ((highNibble * 16 + lowNibble) :) <$> go (index + 2) rest
    go index [_] = Left (Base16BytesOddLength (index + 1))

    decodeDigit :: Int -> Char -> Either Base16BytesError Word8
    decodeDigit index character
      | character >= '0' && character <= '9' = Right (fromIntegral (ord character - ord '0'))
      | character >= 'a' && character <= 'f' = Right (fromIntegral (ord character - ord 'a' + 10))
      | character >= 'A' && character <= 'F' = Right (fromIntegral (ord character - ord 'A' + 10))
      | otherwise = Left (Base16BytesInvalidDigit index character)

-- | Encode a byte string as a JSON string using the canonical lowercase form.
encodeBase16Bytes :: ByteString -> Value
encodeBase16Bytes = String . renderBase16Bytes

-- | Parse the policy's JSON representation with stable failure text.
parseBase16Bytes :: Value -> Parser ByteString
parseBase16Bytes = withText "base16 byte string" $ \value ->
  case decodeBase16BytesText value of
    Right bytes -> pure bytes
    Left (Base16BytesOddLength lengthValue) ->
      fail ("base16 byte string must contain an even number of digits; received " <> show lengthValue)
    Left (Base16BytesInvalidDigit index character) ->
      fail ("invalid base16 digit at index " <> show index <> ": " <> show character)
