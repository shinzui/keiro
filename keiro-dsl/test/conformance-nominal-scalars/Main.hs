{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.KindID as KindID
import qualified Data.List.NonEmpty as NE
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Generated.NominalScalars.Nominal.Shape.OrderStatus as Representation
import Generated.NominalScalars.NominalLedger.Codec
import Generated.NominalScalars.NominalLedger.Domain
import Generated.NominalScalars.NominalLedger.Harness (harnessAssertions)
import Generated.NominalScalars.NominalLedger.Transducer (nominalLedgerTransducer)
import qualified Generated.NominalScalars.NominalProjections as Projections
import Keiki.Core (ExactFieldProjection (..), FieldProjection (..), FieldWitness, Index, ProjectionLawFailure (..), checkFieldProjectionKey, checkFieldProjectionOwner, evalPred, exactFieldWitness, fieldWitnessAgrees, lit, regProj, (!), (.==), (.>=))
import qualified Keiki.Core as K
import Keiki.ProjectionDomain (finiteProjectionDomain)
import Keiki.Shape (CanonicalTypeName (..))
import qualified Keiki.Symbolic as Symbolic
import Keiro.Codec (EventType (..), eventType)
import Keiro.Codec.Nominal
import qualified Keiro.EventStream as EventStream
import Keiro.Snapshot.Codec (defaultStateCodec)
import qualified NominalConformance.Bindings as Bindings
import NominalConformance.Domain
import Numeric.Natural (Natural)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)

main :: IO ()
main = do
    mutation <- lookupEnv "KEIRO_NOMINAL_MUTATION"
    exactProjectionProof <- nominalExactProjectionProof
    let checks =
            harnessAssertions
                <> bindingLawChecks
                <> [ ("expected wire parity: all nominal categories", expectedWireParity)
                   , ("enum representation covers every constructor and wire spelling exactly once", enumCoverage)
                   , ("event codec exact JSON bytes", exactEventJson)
                   , ("event codec round-trip", eventRoundTrip)
                   , ("pre-adoption valid ord payload still decodes", validHistoricalPayloadDecodes)
                   , ("wrong-prefix ID rejection", wrongPrefixRejected)
                   , ("malformed ID rejection", malformedIdRejected)
                   , ("unknown enum rejection", unknownEnumRejected)
                   , ("snapshot cache round-trip", snapshotRoundTrip)
                   , ("canonical nominal identities", canonicalIdentities)
                   , ("scalar projection witness agreement", projectionAgreement)
                   , ("ID and enum equality projection witness agreement", nominalEqualityProjectionAgreement)
                   , ("scalar equality support", equalityChecks)
                   , ("same-declaration ID and enum guards take both concrete branches", nominalGuardBranches)
                   , ("validated ID and finite enum projections are exact symbolically", exactProjectionProof)
                   , ("Int Natural and Time ordering support", orderingChecks)
                   , ("forward execution equals decoded replay", forwardReplayAgreement)
                   ]
                <> mutationChecks mutation
    forM_ checks $ \(label, passed) ->
        putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
    unless (all snd checks) exitFailure

mutationChecks :: Maybe String -> [(String, Bool)]
mutationChecks Nothing = []
mutationChecks (Just "enum-transpose") = [("mutation gate: transposed enum representation preserves expected wire", transposedEnumWireParity)]
mutationChecks (Just "scalar-wire") = [("mutation gate: changed scalar expected wire remains exact", changedScalarWireParity)]
mutationChecks (Just "id-one-direction") = [("mutation gate: one-direction ID suffix preserves domain law", oneDirectionIdLaw)]
mutationChecks (Just "dishonest-exact") = [("mutation gate: under-declared exact projection satisfies its owner law", dishonestExactProjectionLaw)]
mutationChecks (Just other) = [("unknown mutation: " <> other, False)]

data DishonestStatusProjection

instance FieldProjection DishonestStatusProjection where
    type FieldName DishonestStatusProjection = "dishonest-status"
    type FieldOwner DishonestStatusProjection = OrderStatus
    type FieldResult DishonestStatusProjection = Text
    fieldShapeId _ = "mutation/dishonest-status"
    projectFieldValue _ AwaitingApproval = "draft"
    projectFieldValue _ Accepted = "accepted-outside-domain"

instance ExactFieldProjection DishonestStatusProjection where
    fieldProjectionDomain _ = finiteProjectionDomain (NE.fromList ["draft", "submitted"])
    reconstructFieldOwner _ "draft" = Just AwaitingApproval
    reconstructFieldOwner _ "submitted" = Just Accepted
    reconstructFieldOwner _ _ = Nothing

dishonestStatusWitness :: FieldWitness DishonestStatusProjection
dishonestStatusWitness = exactFieldWitness @DishonestStatusProjection

dishonestExactProjectionLaw :: Bool
dishonestExactProjectionLaw = checkFieldProjectionOwner dishonestStatusWitness Accepted == Right ()

transposedEnumWireParity :: Bool
transposedEnumWireParity =
    all
        ( \fixture ->
            String (Representation.orderStatusRepresentationText (nominalToRepresentation transposed (nominalFixtureDomain fixture)))
                == nominalFixtureWire fixture
        )
        (NE.toList (nominalFixtureCases Bindings.orderStatusFixtures))
  where
    transposed =
        NominalBinding
            { nominalToRepresentation = \case
                AwaitingApproval -> Representation.Submitted
                Accepted -> Representation.Draft
            , nominalFromRepresentation = \case
                Representation.Draft -> Accepted
                Representation.Submitted -> AwaitingApproval
            }

changedScalarWireParity :: Bool
changedScalarWireParity =
    toJSON (nominalToRepresentation Bindings.riskScoreBinding (RiskScore 7)) == toJSON (8 :: Int)

oneDirectionIdLaw :: Bool
oneDirectionIdLaw = case KindID.parseText @"ord" "ord_00041061050r3gg28a1c60t3ge" of
    Left _ -> False
    Right changed ->
        nominalDomainRoundTrip
            Bindings.orderIdBinding{nominalFromRepresentation = const (OrderId changed)}
            Bindings.sampleOrderId

bindingLawChecks :: [(String, Bool)]
bindingLawChecks =
    lawChecks "OrderId" Bindings.orderIdBinding Bindings.orderIdFixtures
        <> lawChecks "OrderStatus" Bindings.orderStatusBinding Bindings.orderStatusFixtures
        <> lawChecks "AccountNumber" Bindings.accountNumberBinding Bindings.accountNumberFixtures
        <> lawChecks "RiskScore" Bindings.riskScoreBinding Bindings.riskScoreFixtures
        <> lawChecks "SequenceNumber" Bindings.sequenceNumberBinding Bindings.sequenceNumberFixtures
        <> lawChecks "FeatureFlag" Bindings.featureFlagBinding Bindings.featureFlagFixtures
        <> lawChecks "ObservedAt" Bindings.observedAtBinding Bindings.observedAtFixtures

lawChecks :: (Eq domain, Eq representation) => String -> NominalBinding domain representation -> NominalFixtureCases domain -> [(String, Bool)]
lawChecks label binding fixtures =
    [ ("binding domain law: " <> label, all (nominalDomainRoundTrip binding . nominalFixtureDomain) values)
    ,
        ( "binding representation law: " <> label
        , all
            (\fixture -> nominalRepresentationRoundTrip binding (nominalToRepresentation binding (nominalFixtureDomain fixture)))
            values
        )
    ]
  where
    values = NE.toList (nominalFixtureCases fixtures)

sampleEvent :: NominalLedgerEvent
sampleEvent =
    NominalsRecorded
        NominalsRecordedData
            { orderId = Bindings.sampleOrderId
            , status = Accepted
            , accountNumber = AccountNumber "acct-007"
            , riskScore = RiskScore 7
            , sequenceNumber = SequenceNumber 11
            , featureFlag = FeatureFlag True
            , observedAt = ObservedAt Bindings.sampleTime
            }

expectedEventJson :: Value
expectedEventJson =
    object
        [ "kind" .= ("NominalsRecorded" :: String)
        , "orderId" .= Bindings.validOrderIdText
        , "status" .= ("submitted" :: String)
        , "accountNumber" .= ("acct-007" :: String)
        , "riskScore" .= (7 :: Int)
        , "sequenceNumber" .= (11 :: Natural)
        , "featureFlag" .= True
        , "observedAt" .= Bindings.sampleTime
        ]

exactEventJson :: Bool
exactEventJson = encodeNominalLedgerEvent sampleEvent == expectedEventJson

eventRoundTrip :: Bool
eventRoundTrip =
    parseNominalLedgerEvent (eventType nominalLedgerCodec sampleEvent) (encodeNominalLedgerEvent sampleEvent)
        == Right sampleEvent

validHistoricalPayloadDecodes :: Bool
validHistoricalPayloadDecodes =
    parseNominalLedgerEvent (EventType "NominalsRecorded") expectedEventJson == Right sampleEvent

wrongPrefixRejected :: Bool
wrongPrefixRejected = rejects (replace "orderId" (String "usr_00041061050r3gg28a1c60t3gf") expectedEventJson)

malformedIdRejected :: Bool
malformedIdRejected = rejects (replace "orderId" (String "not-a-typeid") expectedEventJson)

unknownEnumRejected :: Bool
unknownEnumRejected = rejects (replace "status" (String "retired") expectedEventJson)

rejects :: Value -> Bool
rejects value = case parseNominalLedgerEvent (EventType "NominalsRecorded") value of
    Left _ -> True
    Right _ -> False

replace :: Key -> Value -> Value -> Value
replace key value (Object fields) = Object (KeyMap.insert key value fields)
replace _ _ other = other

expectedWireParity :: Bool
expectedWireParity =
    and
        [ wire Bindings.orderIdFixtures (String . KindID.toText . nominalToRepresentation Bindings.orderIdBinding)
        , wire Bindings.orderStatusFixtures (String . Representation.orderStatusRepresentationText . nominalToRepresentation Bindings.orderStatusBinding)
        , wire Bindings.accountNumberFixtures (toJSON . nominalToRepresentation Bindings.accountNumberBinding)
        , wire Bindings.riskScoreFixtures (toJSON . nominalToRepresentation Bindings.riskScoreBinding)
        , wire Bindings.sequenceNumberFixtures (toJSON . nominalToRepresentation Bindings.sequenceNumberBinding)
        , wire Bindings.featureFlagFixtures (toJSON . nominalToRepresentation Bindings.featureFlagBinding)
        , wire Bindings.observedAtFixtures (toJSON . nominalToRepresentation Bindings.observedAtBinding)
        ]
  where
    wire fixtures encodeRepresentation =
        all
            (\fixture -> encodeRepresentation (nominalFixtureDomain fixture) == nominalFixtureWire fixture)
            (NE.toList (nominalFixtureCases fixtures))

enumCoverage :: Bool
enumCoverage =
    representations == [Representation.Draft, Representation.Submitted]
        && wires == [String "draft", String "submitted"]
  where
    fixtures = NE.toList (nominalFixtureCases Bindings.orderStatusFixtures)
    representations = map (nominalToRepresentation Bindings.orderStatusBinding . nominalFixtureDomain) fixtures
    wires = map nominalFixtureWire fixtures

snapshotRoundTrip :: Bool
snapshotRoundTrip = case EventStream.decode codec encoded of
    Left _ -> False
    Right (vertex, registers) ->
        vertex == NominalLedgerEmpty
            && registers ! #orderId == Bindings.initialOrderId
            && registers ! #status == Bindings.initialOrderStatus
            && registers ! #accountNumber == Bindings.initialAccountNumber
            && registers ! #riskScore == Bindings.initialRiskScore
            && registers ! #sequenceNumber == Bindings.initialSequenceNumber
            && registers ! #featureFlag == Bindings.initialFeatureFlag
            && registers ! #observedAt == Bindings.initialObservedAt
            && EventStream.encode codec (vertex, registers) == encoded
  where
    codec = defaultStateCodec @NominalLedgerRegs @NominalLedgerVertex 1
    encoded = EventStream.encode codec (NominalLedgerEmpty, initialNominalLedgerRegs)

canonicalIdentities :: Bool
canonicalIdentities =
    and
        [ canonicalTypeName (Proxy @OrderId) == "nominal.OrderId.v1"
        , canonicalTypeName (Proxy @OrderStatus) == "nominal.OrderStatus.v1"
        , canonicalTypeName (Proxy @AccountNumber) == "nominal.AccountNumber.v1"
        , canonicalTypeName (Proxy @RiskScore) == "nominal.RiskScore.v1"
        , canonicalTypeName (Proxy @SequenceNumber) == "nominal.SequenceNumber.v1"
        , canonicalTypeName (Proxy @FeatureFlag) == "nominal.FeatureFlag.v1"
        , canonicalTypeName (Proxy @ObservedAt) == "nominal.ObservedAt.v1"
        ]

projectionAgreement :: Bool
projectionAgreement =
    and
        [ fieldWitnessAgrees Projections.accountNumberWitness (nominalToRepresentation Bindings.accountNumberBinding) Bindings.initialAccountNumber
        , fieldWitnessAgrees Projections.riskScoreWitness (nominalToRepresentation Bindings.riskScoreBinding) Bindings.initialRiskScore
        , fieldWitnessAgrees Projections.sequenceNumberWitness (nominalToRepresentation Bindings.sequenceNumberBinding) Bindings.initialSequenceNumber
        , fieldWitnessAgrees Projections.featureFlagWitness (nominalToRepresentation Bindings.featureFlagBinding) Bindings.initialFeatureFlag
        , fieldWitnessAgrees Projections.observedAtWitness (nominalToRepresentation Bindings.observedAtBinding) Bindings.initialObservedAt
        ]

nominalEqualityProjectionAgreement :: Bool
nominalEqualityProjectionAgreement =
    and
        [ fieldWitnessAgrees Projections.orderIdEqualityWitness (KindID.toText . nominalToRepresentation Bindings.orderIdBinding) Bindings.initialOrderId
        , fieldWitnessAgrees Projections.orderStatusEqualityWitness (Representation.orderStatusRepresentationText . nominalToRepresentation Bindings.orderStatusBinding) Bindings.initialOrderStatus
        , checkFieldProjectionOwner Projections.orderIdEqualityWitness Bindings.initialOrderId == Right ()
        , checkFieldProjectionOwner Projections.orderStatusEqualityWitness Bindings.initialOrderStatus == Right ()
        , checkFieldProjectionKey Projections.orderIdEqualityWitness Bindings.validOrderIdText == Right Bindings.initialOrderId
        , checkFieldProjectionKey Projections.orderStatusEqualityWitness "draft" == Right Bindings.initialOrderStatus
        , checkFieldProjectionKey Projections.orderStatusEqualityWitness "submitted" == Right Accepted
        , checkFieldProjectionKey Projections.orderIdEqualityWitness "usr_00041061050r3gg28a1c60t3gf" == Left ProjectedKeyOutsideDeclaredDomain
        ]

equalityChecks :: Bool
equalityChecks =
    and
        [ evalPred (regProj Projections.accountNumberWitness accountIx .== lit "acct-initial") initialNominalLedgerRegs ()
        , evalPred (regProj Projections.riskScoreWitness riskIx .== lit 0) initialNominalLedgerRegs ()
        , evalPred (regProj Projections.sequenceNumberWitness sequenceIx .== lit 0) initialNominalLedgerRegs ()
        , evalPred (regProj Projections.featureFlagWitness featureIx .== lit False) initialNominalLedgerRegs ()
        , evalPred (regProj Projections.observedAtWitness observedIx .== lit Bindings.sampleTime) initialNominalLedgerRegs ()
        ]

orderingChecks :: Bool
orderingChecks =
    and
        [ evalPred (regProj Projections.riskScoreWitness riskIx .>= lit 0) initialNominalLedgerRegs ()
        , evalPred (regProj Projections.sequenceNumberWitness sequenceIx .>= lit 0) initialNominalLedgerRegs ()
        , evalPred (regProj Projections.observedAtWitness observedIx .>= lit Bindings.sampleTime) initialNominalLedgerRegs ()
        ]

accountIx :: Index NominalLedgerRegs AccountNumber
accountIx = #accountNumber
riskIx :: Index NominalLedgerRegs RiskScore
riskIx = #riskScore
sequenceIx :: Index NominalLedgerRegs SequenceNumber
sequenceIx = #sequenceNumber
featureIx :: Index NominalLedgerRegs FeatureFlag
featureIx = #featureFlag
observedIx :: Index NominalLedgerRegs ObservedAt
observedIx = #observedAt

orderIdIx :: Index NominalLedgerRegs OrderId
orderIdIx = #orderId

statusIx :: Index NominalLedgerRegs OrderStatus
statusIx = #status

matchingCommand :: NominalLedgerCommand
matchingCommand =
    RecordNominals
        RecordNominalsData
            { orderId = Bindings.initialOrderId
            , status = Bindings.initialOrderStatus
            , accountNumber = AccountNumber "acct-next"
            , riskScore = RiskScore 4
            , sequenceNumber = SequenceNumber 9
            , featureFlag = FeatureFlag True
            , observedAt = ObservedAt Bindings.sampleTime
            }

nominalGuardBranches :: Bool
nominalGuardBranches =
    accepts matchingCommand
        && not (accepts (setOrderId alternateOrderId matchingCommand))
        && not (accepts (setStatus Accepted matchingCommand))
  where
    accepts command = case K.step nominalLedgerTransducer (NominalLedgerEmpty, initialNominalLedgerRegs) command of
        Just {} -> True
        Nothing -> False
    setOrderId value (RecordNominals command) = RecordNominals command{orderId = value}
    setStatus value (RecordNominals command) = RecordNominals command{status = value}

alternateOrderId :: OrderId
alternateOrderId = case KindID.parseText @"ord" "ord_00041061050r3gg28a1c60t3ge" of
    Left reason -> error ("invalid alternate conformance TypeID: " <> show reason)
    Right value -> OrderId value

nominalExactProjectionProof :: IO Bool
nominalExactProjectionProof = do
    let idValue = regProj Projections.orderIdEqualityWitness orderIdIx
        enumValue = regProj Projections.orderStatusEqualityWitness statusIx
        idContradiction = K.PAnd (K.PEq idValue (lit Bindings.validOrderIdText)) (K.PEq idValue (lit (KindID.toText (unOrderId alternateOrderId))))
        enumContradiction = K.PAnd (K.PEq enumValue (lit ("draft" :: Text))) (K.PEq enumValue (lit ("submitted" :: Text)))
    idResult <- Symbolic.verifyPredicate idContradiction
    enumResult <- Symbolic.verifyPredicate enumContradiction
    pure (idResult == Symbolic.VerifiedUnsatisfiable && enumResult == Symbolic.VerifiedUnsatisfiable)

forwardReplayAgreement :: Bool
forwardReplayAgreement = case K.step nominalLedgerTransducer initialPair matchingCommand of
    Nothing -> False
    Just (forwardVertex, forwardRegisters, events) ->
        case traverse decodeRoundTrip events of
            Left _ -> False
            Right decodedEvents -> case K.applyEventsEither nominalLedgerTransducer initialPair decodedEvents of
                Left _ -> False
                Right (replayVertex, replayRegisters) ->
                    replayVertex == forwardVertex
                        && replayRegisters ! #orderId == forwardRegisters ! #orderId
                        && replayRegisters ! #status == forwardRegisters ! #status
                        && replayRegisters ! #accountNumber == forwardRegisters ! #accountNumber
                        && replayRegisters ! #riskScore == forwardRegisters ! #riskScore
                        && replayRegisters ! #sequenceNumber == forwardRegisters ! #sequenceNumber
                        && replayRegisters ! #featureFlag == forwardRegisters ! #featureFlag
                        && replayRegisters ! #observedAt == forwardRegisters ! #observedAt
  where
    initialPair = (NominalLedgerEmpty, initialNominalLedgerRegs)
    decodeRoundTrip event = parseNominalLedgerEvent (eventType nominalLedgerCodec event) (encodeNominalLedgerEvent event)
