{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Conformance.StructuralNominals.Historical
  ( historicalTemplateStateCodec,
  )
where

import Conformance.StructuralNominals.Domain
import Control.Monad (unless)
import Data.Aeson (Value (..), object, toJSON, withObject, withText, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Text qualified as T
import Generated.StructuralNominalLeaves.Nominals (TemplateId, parseTemplateId, templateIdText)
import Keiro.Codec.IdDomain (parseKindIdV7Text)
import Keiro.Dsl.CodecCompare (HistoricalCodec (..))

historicalTemplateStateCodec :: HistoricalCodec TemplateState
historicalTemplateStateCodec =
  HistoricalCodec
    { identity = "conformance.structural-nominals.TemplateIdValue.opaque-json",
      version = "opaque-v1",
      encode = encodeHistoricalTemplateState,
      decode = either (Left . T.pack) Right . parseEither parseHistoricalTemplateState
    }

encodeHistoricalTemplateState :: TemplateState -> Value
encodeHistoricalTemplateState value =
  object
    [ "templateId" .= templateIdText value.templateId,
      "holder" .= maybe Null toJSON value.holder,
      "account" .= unAccountNumber value.account
    ]

parseHistoricalTemplateState :: Value -> Parser TemplateState
parseHistoricalTemplateState = withObject "historical TemplateState" $ \objectValue -> do
  let allowed = ["templateId", "holder", "account"]
      unknown = [Key.toText key | key <- KeyMap.keys objectValue, Key.toText key `notElem` allowed]
  unless (null unknown) (fail ("unknown historical TemplateState fields " <> show unknown))
  templateId <- objectValue .: "templateId" >>= parseHistoricalTemplateId
  holder <- case KeyMap.lookup "holder" objectValue of
    Nothing -> pure Nothing
    Just Null -> pure Nothing
    Just value -> Just <$> parseHistoricalClaimId value
  account <- objectValue .: "account" >>= withText "historical AccountNumber" (pure . AccountNumber)
  pure (TemplateState templateId holder account)

parseHistoricalTemplateId :: Value -> Parser TemplateId
parseHistoricalTemplateId = withText "historical TemplateIdValue" $ \value ->
  either (fail . T.unpack) pure (parseTemplateId value)

parseHistoricalClaimId :: Value -> Parser ClaimId
parseHistoricalClaimId = withText "historical ClaimId" $ \value ->
  case parseKindIdV7Text @"claim" value of
    Left reason -> fail (show reason)
    Right claimId -> pure (ClaimId claimId)
