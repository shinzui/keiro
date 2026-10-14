{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Conformance.ContractListFields.Bindings (claimId, claimIdText)
import Data.Aeson (Value (Null, Object, String), object, toJSON, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.KindID qualified as KindID
import Data.Text (Text)
import Data.Text qualified as T
import Generated.ContractListFields.Nominals (TemplateId, parseTemplateId)
import Generated.ContractListFields.StructuralConformance (structuralConformanceAssertions)
import Generated.ContractListFields.Templates.Contract
import System.Exit (exitFailure)

templateTexts :: [Text]
templateTexts = [templateIdText, "template_01h455vb4pex5vsknk084sn02r"]

templateIdText :: Text
templateIdText = "template_01h455vb4pex5vsknk084sn02q"

templateIdValue :: TemplateId
templateIdValue = either (error . T.unpack) id (parseTemplateId templateIdText)

templateIdsValue :: [TemplateId]
templateIdsValue = map (either (error . T.unpack) id . parseTemplateId) templateTexts

legacyTemplateIdValue :: KindID.KindID "template"
legacyTemplateIdValue = either (error . show) id (KindID.parseText @"template" (templateIdText))

payload :: TemplatesPayload
payload = TemplatesReassigned (TemplatesReassignedData (templateIdValue) templateIdsValue [claimId] [legacyTemplateIdValue] ["first", "second"] [1, 2])

expectedJson :: Value
expectedJson =
  object
    [ "messageType" .= ("TemplatesReassigned" :: Text),
      "typeId" .= templateIdText,
      "templateIds" .= templateTexts,
      "claimIds" .= [claimIdText],
      "legacyTemplateIds" .= [templateIdText],
      "labels" .= (["first", "second"] :: [Text]),
      "positions" .= ([1, 2] :: [Int])
    ]

listKeys :: [Key]
listKeys = ["templateIds", "claimIds", "legacyTemplateIds", "labels", "positions"]

replaceField :: Key -> Value -> Value -> Value
replaceField key value (Object fields) = Object (KeyMap.insert key value fields)
replaceField _ _ value = value

removeField :: Key -> Value -> Value
removeField key (Object fields) = Object (KeyMap.delete key fields)
removeField _ value = value

rejectsAt :: Text -> Value -> Bool
rejectsAt path value = case parseTemplatesPayload value of
  Left problem -> path `T.isInfixOf` problem
  Right _ -> False

main :: IO ()
main = do
  let encoded = encodeTemplatesPayload payload
      empty = TemplatesReassigned (TemplatesReassignedData (templateIdValue) [] [] [] [] [])
      reversed = TemplatesReassigned (TemplatesReassignedData (templateIdValue) (reverse templateIdsValue) [claimId] [legacyTemplateIdValue] ["first", "second"] [1, 2])
      repeated = TemplatesReassigned (TemplatesReassignedData (templateIdValue) (templateIdsValue <> templateIdsValue) [claimId, claimId] [legacyTemplateIdValue, legacyTemplateIdValue] ["first", "first"] [1, 1])
      expectedEmpty = foldr (\key -> replaceField key (toJSON ([] :: [Value]))) expectedJson listKeys
      checks =
        [ ("list fields encode exact ordered scalar arrays", encoded == expectedJson),
          ("all scalar families round-trip", parseTemplatesPayload encoded == Right payload),
          ("empty lists encode required empty arrays and round-trip", encodeTemplatesPayload empty == expectedEmpty && parseTemplatesPayload expectedEmpty == Right empty),
          ("reversed IDs preserve their order", encodeTemplatesPayload reversed == replaceField "templateIds" (toJSON (reverse templateTexts)) expectedJson && parseTemplatesPayload (encodeTemplatesPayload reversed) == Right reversed),
          ("duplicates retain their positions", parseTemplatesPayload (encodeTemplatesPayload repeated) == Right repeated && encodeTemplatesPayload repeated == foldr (uncurry replaceField) expectedJson [("templateIds", toJSON (templateTexts <> templateTexts)), ("claimIds", toJSON [claimIdText, claimIdText]), ("legacyTemplateIds", toJSON [templateIdText, templateIdText]), ("labels", toJSON (["first", "first"] :: [Text])), ("positions", toJSON ([1, 1] :: [Int]))]),
          ("non-array fails at $.templateIds", rejectsAt "$.templateIds" (replaceField "templateIds" (String (templateIdText)) encoded)),
          ("wrong-prefix second element fails at $.templateIds[1]", rejectsAt "$.templateIds[1]" (replaceField "templateIds" (toJSON [templateIdText, claimIdText]) encoded)),
          ("consumer-bound ID admission has an element path", rejectsAt "$.claimIds[0]" (replaceField "claimIds" (toJSON [templateIdText]) encoded)),
          ("literal ID admission has an element path", rejectsAt "$.legacyTemplateIds[0]" (replaceField "legacyTemplateIds" (toJSON [claimIdText]) encoded)),
          ("all list fields are required", all (\key -> rejectsAt (T.pack (show key)) (removeField key encoded)) listKeys),
          ("all list fields reject null", all (\key -> rejectsAt ("$." <> T.dropAround (== '"') (T.pack (show key))) (replaceField key Null encoded)) listKeys),
          ("all scalar families reject null elements at their index", all (\key -> rejectsAt ("$." <> T.dropAround (== '"') (T.pack (show key)) <> "[0]") (replaceField key (toJSON [Null]) encoded)) listKeys),
          ("contract-only nominal helpers pass conformance", all snd structuralConformanceAssertions)
        ]
  mapM_ (\(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)) checks
  if all snd checks then pure () else exitFailure
