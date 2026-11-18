{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Compiled proof for ExecPlan 345 / IR-64: Optional contract fields and a
-- contract whose event type comes from the envelope instead of a body key.
module Main (main) where

import Data.Aeson (Value (Null, Object, String), encode, object, toJSON, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.KindID qualified as KindID
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Generated.ContractForeignEvent.Audit.Contract qualified as Audit
import Generated.ContractForeignEvent.Nominals (MemberId, parseMemberId)
import Generated.ContractForeignEvent.Registration.Contract qualified as Registration
import Generated.ContractForeignEvent.StructuralConformance (structuralConformanceAssertions)
import Keiro.Integration.Event
  ( IntegrationContentType (..),
    IntegrationEvent (..),
    IntegrationEventError (..),
    decodeJsonIntegrationEventWith,
  )
import System.Exit (exitFailure)

registrationIdText :: Text
registrationIdText = "registration_01h455vb4pex5vsknk084sn02q"

memberIdText :: Text
memberIdText = "member_01h455vb4pex5vsknk084sn02q"

registrationId :: KindID.KindID "registration"
registrationId = either (error . show) id (KindID.parseText @"registration" registrationIdText)

memberId :: MemberId
memberId = either (error . T.unpack) id (parseMemberId memberIdText)

referrerId :: KindID.KindID "member"
referrerId = either (error . show) id (KindID.parseText @"member" memberIdText)

occurredAtText :: Text
occurredAtText = "2026-11-18T00:00:00Z"

-- Body-discriminated contract: every optional scalar family.

seenFull :: Audit.AuditPayload
seenFull = Audit.RegistrationSeen (Audit.RegistrationSeenData registrationId (Just "owner@example.com") (Just memberId) (Just 42) (Just referrerId))

seenAbsent :: Audit.AuditPayload
seenAbsent = Audit.RegistrationSeen (Audit.RegistrationSeenData registrationId Nothing Nothing Nothing Nothing)

seenFullJson :: Value
seenFullJson =
  object
    [ "messageType" .= ("RegistrationSeen" :: Text),
      "registrationId" .= registrationIdText,
      "ownerEmail" .= ("owner@example.com" :: Text),
      "mlsMemberId" .= memberIdText,
      "legacyAccountId" .= (42 :: Int),
      "referrerId" .= memberIdText
    ]

seenAbsentJson :: Value
seenAbsentJson =
  object
    [ "messageType" .= ("RegistrationSeen" :: Text),
      "registrationId" .= registrationIdText
    ]

-- Each optional key of RegistrationSeen, with the payload that results when
-- only that key is null.
seenNullCases :: [(Key, Audit.AuditPayload)]
seenNullCases =
  [ ("ownerEmail", Audit.RegistrationSeen (Audit.RegistrationSeenData registrationId Nothing (Just memberId) (Just 42) (Just referrerId))),
    ("mlsMemberId", Audit.RegistrationSeen (Audit.RegistrationSeenData registrationId (Just "owner@example.com") Nothing (Just 42) (Just referrerId))),
    ("legacyAccountId", Audit.RegistrationSeen (Audit.RegistrationSeenData registrationId (Just "owner@example.com") (Just memberId) Nothing (Just referrerId))),
    ("referrerId", Audit.RegistrationSeen (Audit.RegistrationSeenData registrationId (Just "owner@example.com") (Just memberId) (Just 42) Nothing))
  ]

-- Envelope-discriminated contract: the motivating RegistrationCompleted event.

completedFull :: Registration.RegistrationPayload
completedFull = Registration.RegistrationCompleted (Registration.RegistrationCompletedData registrationId occurredAtText (Just "owner@example.com") (Just memberId) (Just 7))

completedAbsent :: Registration.RegistrationPayload
completedAbsent = Registration.RegistrationCompleted (Registration.RegistrationCompletedData registrationId occurredAtText Nothing Nothing Nothing)

completedFullJson :: Value
completedFullJson =
  object
    [ "registrationId" .= registrationIdText,
      "occurredAt" .= occurredAtText,
      "ownerEmail" .= ("owner@example.com" :: Text),
      "mlsMemberId" .= memberIdText,
      "legacyAccountId" .= (7 :: Int)
    ]

-- The bare object registration-service-v2 publishes when both optional
-- values are unknown.
completedBareJson :: Value
completedBareJson =
  object
    [ "registrationId" .= registrationIdText,
      "occurredAt" .= occurredAtText
    ]

envelopeFor :: Text -> Value -> IntegrationEvent
envelopeFor eventType body =
  IntegrationEvent
    { messageId = "message-1",
      source = "registration-service-v2",
      destination = "registration.completed.v1",
      key = Nothing,
      eventType = eventType,
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes = LazyByteString.toStrict (encode body),
      occurredAt = UTCTime (fromGregorian 2026 11 18) 0,
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

replaceField :: Key -> Value -> Value -> Value
replaceField key value (Object fields) = Object (KeyMap.insert key value fields)
replaceField _ _ value = value

removeField :: Key -> Value -> Value
removeField key (Object fields) = Object (KeyMap.delete key fields)
removeField _ value = value

hasKey :: Key -> Value -> Bool
hasKey key (Object fields) = KeyMap.member key fields
hasKey _ _ = False

failsWith :: Text -> Either Text a -> Bool
failsWith fragment = either (fragment `T.isInfixOf`) (const False)

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

main :: IO ()
main = do
  let parseAudit = Audit.parseAuditPayload
      parseCompleted = Registration.parseRegistrationPayloadAs "RegistrationCompleted"
      noted note = Audit.MemberNoted (Audit.MemberNotedData memberId note)
      notedJson extra = object (["messageType" .= ("MemberNoted" :: Text), "memberId" .= memberIdText] <> extra)
      checks =
        [ -- AC-1 on the body-discriminated contract.
          ("present optionals encode exactly and round-trip for text, int, literal TypeID and declared id", Audit.encodeAuditPayload seenFull == seenFullJson && parseAudit seenFullJson == Right seenFull),
          ("absent optionals encode with no key and round-trip", Audit.encodeAuditPayload seenAbsent == seenAbsentJson && parseAudit seenAbsentJson == Right seenAbsent),
          ("each optional key set to null decodes to Nothing", all (\(key, expected) -> parseAudit (replaceField key Null seenFullJson) == Right expected) seenNullCases),
          ("a wrong-typed optional text fails at $.ownerEmail", failsWith "$.ownerEmail" (parseAudit (replaceField "ownerEmail" (toJSON (7 :: Int)) seenFullJson))),
          ("a wrong-typed optional int fails at $.legacyAccountId", failsWith "$.legacyAccountId" (parseAudit (replaceField "legacyAccountId" (String "seven") seenFullJson))),
          ("a wrong-prefix optional declared id fails at $.mlsMemberId", failsWith "$.mlsMemberId" (parseAudit (replaceField "mlsMemberId" (String registrationIdText) seenFullJson))),
          ("a wrong-prefix optional literal TypeID fails at $.referrerId", failsWith "$.referrerId" (parseAudit (replaceField "referrerId" (String registrationIdText) seenFullJson))),
          ("a missing required field is still rejected", isLeft' (parseAudit (removeField "registrationId" seenAbsentJson))),
          ("an unknown extra key is ignored", parseAudit (replaceField "unexpected" (String "ignored") seenFullJson) == Right seenFull),
          ("MemberNoted round-trips with and without its optional note", Audit.encodeAuditPayload (noted Nothing) == notedJson [] && parseAudit (notedJson []) == Right (noted Nothing) && Audit.encodeAuditPayload (noted (Just "hello")) == notedJson ["note" .= ("hello" :: Text)] && parseAudit (notedJson ["note" .= ("hello" :: Text)]) == Right (noted (Just "hello"))),
          ("the body-discriminated contract still requires its messageType key", failsWith "messageType" (parseAudit (removeField "messageType" seenFullJson))),
          -- AC-2 on the envelope-discriminated contract.
          ("the envelope contract encodes no messageType key", not (hasKey "messageType" (Registration.encodeRegistrationPayload completedFull))),
          ("the envelope contract encodes exactly and round-trips", Registration.encodeRegistrationPayload completedFull == completedFullJson && parseCompleted completedFullJson == Right completedFull),
          ("absent optionals encode as the bare producer object", Registration.encodeRegistrationPayload completedAbsent == completedBareJson),
          ("the bare producer object decodes with both optionals absent", parseCompleted completedBareJson == Right completedAbsent),
          ("an explicit null ownerEmail decodes the same way", parseCompleted (replaceField "ownerEmail" Null completedBareJson) == Right completedAbsent),
          ("an undeclared event type is rejected naming it", failsWith "unknown message type \"SomethingElse\"" (Registration.parseRegistrationPayloadAs "SomethingElse" completedBareJson)),
          ("a wrong-typed ownerEmail fails at $.ownerEmail", failsWith "$.ownerEmail" (parseCompleted (replaceField "ownerEmail" (toJSON (7 :: Int)) completedBareJson))),
          ("a wrong-prefix mlsMemberId fails at $.mlsMemberId", failsWith "$.mlsMemberId" (parseCompleted (replaceField "mlsMemberId" (String registrationIdText) completedBareJson))),
          ("a missing registrationId is rejected", isLeft' (parseCompleted (removeField "registrationId" completedBareJson))),
          ("a body messageType key is ignored as an unknown key", parseCompleted (replaceField "messageType" (String "SomethingElse") completedBareJson) == Right completedAbsent),
          -- AC-2 through keiro-core's envelope join.
          ("decodeJsonIntegrationEventWith decodes a matching envelope", decodeJsonIntegrationEventWith Registration.parseRegistrationPayloadAs (envelopeFor "RegistrationCompleted" completedBareJson) == Right completedAbsent),
          ( "decodeJsonIntegrationEventWith rejects a mismatched envelope event type",
            case decodeJsonIntegrationEventWith Registration.parseRegistrationPayloadAs (envelopeFor "RegistrationStarted" completedBareJson) of
              Left (DecodeFailed problem) -> "RegistrationStarted" `T.isInfixOf` problem
              _ -> False
          ),
          ( "decodeJsonIntegrationEventWith refuses a non-JSON content type",
            decodeJsonIntegrationEventWith Registration.parseRegistrationPayloadAs ((envelopeFor "RegistrationCompleted" completedBareJson) {contentType = OtherContentType "application/avro"})
              == Left (UnsupportedContentType "application/avro")
          ),
          ( "decodeJsonIntegrationEventWith reports unparsable bytes as malformed",
            case decodeJsonIntegrationEventWith Registration.parseRegistrationPayloadAs ((envelopeFor "RegistrationCompleted" completedBareJson) {payloadBytes = "{"}) of
              Left (MalformedPayload _) -> True
              _ -> False
          ),
          ("contract nominal helpers pass conformance", all snd structuralConformanceAssertions)
        ]
  mapM_ (\(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)) checks
  if all snd checks then pure () else exitFailure
