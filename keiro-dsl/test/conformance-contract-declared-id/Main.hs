{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Conformance.ContractDeclaredId.Bindings (claimId, claimIdText)
import Data.Aeson (Value (Object), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.KindID qualified as KindID
import Data.Text (Text)
import Data.Text qualified as T
import Generated.ContractDeclaredId.Nominals (TemplateId, parseTemplateId)
import Generated.ContractDeclaredId.StructuralConformance (structuralConformanceAssertions)
import Generated.ContractDeclaredId.Templates.Contract
import System.Exit (exitFailure)

canonicalSuffix :: Text
canonicalSuffix = "01h455vb4pex5vsknk084sn02q"

templateIdText :: Text
templateIdText = "template_" <> canonicalSuffix

templateIdValue :: TemplateId
templateIdValue = either (error . T.unpack) id (parseTemplateId templateIdText)

legacyTemplateIdValue :: KindID.KindID "template"
legacyTemplateIdValue = either (error . show) id (KindID.parseText @"template" templateIdText)

payload :: TemplatesPayload
payload = TemplateClaimed (TemplateClaimedData templateIdValue claimId legacyTemplateIdValue)

payloadJson :: Text -> Value
payloadJson rawClaimId =
  object
    [ "messageType" .= ("TemplateClaimed" :: Text),
      "templateId" .= templateIdText,
      "claimId" .= rawClaimId,
      "legacyTemplateId" .= templateIdText
    ]

main :: IO ()
main = do
  let encoded = encodeTemplatesPayload payload
      checks =
        [ ("declared contract IDs round-trip", encoded == payloadJson claimIdText && parseTemplatesPayload encoded == Right payload),
          ("literal and declared forms retain identical JSON text", equalTemplateFields encoded),
          ("wrong-prefix consumer ID is rejected at $.claimId", rejectsWrongPrefix),
          ("contract-only nominal conformance", all snd structuralConformanceAssertions)
        ]
  mapM_ (\(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)) checks
  let failed = [label | (label, ok) <- checks, not ok]
  if null failed then pure () else putStrLn ("declared-ID contract: failed " <> show failed) >> exitFailure
  where
    equalTemplateFields (Object fields) = KeyMap.lookup "templateId" fields == KeyMap.lookup "legacyTemplateId" fields
    equalTemplateFields _ = False
    rejectsWrongPrefix = case parseTemplatesPayload (payloadJson ("template_" <> canonicalSuffix)) of
      Left problem -> "$.claimId" `T.isInfixOf` problem
      Right _ -> False
