-- | Validated terminal refusal data for outbox publication.
--
-- This module is intentionally not exposed by the package. Public callers use
-- the abstract 'PublishRejection' type and smart constructor re-exported from
-- "Keiro.Outbox.Types"; database decoders inside the package can use the data
-- constructor after schema constraints have validated the stored values.
module Keiro.Outbox.Rejection
  ( PublishRejection (..),
    PublishRejectionError (..),
    mkPublishRejection,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Keiro.Prelude

-- | A stable machine-readable refusal code and optional operator detail.
--
-- Codes are lowercase ASCII identifiers of 1 to 64 characters. Detail is
-- non-empty when present and is bounded to 1024 UTF-8 bytes.
data PublishRejection = PublishRejection
  { publishRejectionCode :: !Text,
    publishRejectionDetail :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | Why 'mkPublishRejection' refused caller-provided data.
data PublishRejectionError
  = InvalidPublishRejectionCode !Text
  | PublishRejectionDetailEmpty
  | PublishRejectionDetailTooLong !Int
  deriving stock (Generic, Eq, Show)

-- | Validate a terminal publication refusal without normalizing caller data.
mkPublishRejection :: Text -> Maybe Text -> Either PublishRejectionError PublishRejection
mkPublishRejection code detail
  | not (validCode code) = Left (InvalidPublishRejectionCode code)
  | otherwise =
      case detail of
        Just value
          | Text.null value -> Left PublishRejectionDetailEmpty
          | detailBytes value > 1024 -> Left (PublishRejectionDetailTooLong (detailBytes value))
        _ -> Right PublishRejection {publishRejectionCode = code, publishRejectionDetail = detail}
  where
    detailBytes = ByteString.length . TE.encodeUtf8

validCode :: Text -> Bool
validCode code =
  Text.length code <= 64
    && case Text.uncons code of
      Nothing -> False
      Just (first, rest) -> isLowerAscii first && Text.all isCodeTail rest
  where
    isLowerAscii char = char >= 'a' && char <= 'z'
    isCodeTail char =
      isLowerAscii char
        || (char >= '0' && char <= '9')
        || char == '.'
        || char == '_'
        || char == '-'
