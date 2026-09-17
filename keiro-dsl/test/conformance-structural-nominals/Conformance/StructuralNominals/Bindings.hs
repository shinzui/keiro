{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

module Conformance.StructuralNominals.Bindings where

import Conformance.StructuralNominals.Domain
import Data.Aeson (Value (String))
import Data.KindID (KindID)
import Data.KindID qualified as KindID
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Generated.StructuralNominalLeaves.Nominal.Shape.Channel qualified as ChannelRepresentation
import Generated.StructuralNominalLeaves.Nominals (TemplateId, TemplateKind (..), parseTemplateId, templateIdText)
import Generated.StructuralNominalLeaves.Structural.Shape.TemplateBook qualified as ShapeTemplateBook
import Generated.StructuralNominalLeaves.Structural.Shape.TemplateLookupInput qualified as ShapeTemplateLookupInput
import Generated.StructuralNominalLeaves.Structural.Shape.TemplateLookupRow qualified as ShapeTemplateLookupRow
import Generated.StructuralNominalLeaves.Structural.Shape.TemplateRef qualified as ShapeTemplateRef
import Generated.StructuralNominalLeaves.Structural.Shape.TemplateState qualified as ShapeTemplateState
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

templateIdText1, templateIdText2, claimIdText, claimIdText2 :: Text
templateIdText1 = "template_01h455vb4pex5vsknk084sn02q"
templateIdText2 = "template_01h455vb4pex5vsknk084sn02r"
claimIdText = "claim_01h455vb4pex5vsknk084sn02q"
claimIdText2 = "claim_01h455vb4pex5vsknk084sn02r"

templateId1, templateId2 :: TemplateId
templateId1 = parseCommittedTemplateId templateIdText1
templateId2 = parseCommittedTemplateId templateIdText2

claimId, claimId2 :: ClaimId
claimId = case KindID.parseText @"claim" claimIdText of
  Left reason -> error ("invalid committed ClaimId fixture: " <> show reason)
  Right value -> ClaimId value
claimId2 = case KindID.parseText @"claim" claimIdText2 of
  Left reason -> error ("invalid committed ClaimId fixture: " <> show reason)
  Right value -> ClaimId value

accountNumber :: AccountNumber
accountNumber = AccountNumber "account-007"

channelBinding :: NominalBinding Channel ChannelRepresentation.ChannelRepresentation
channelBinding =
  NominalBinding
    { nominalToRepresentation = \case
        EmailChannel -> ChannelRepresentation.Email
        SmsChannel -> ChannelRepresentation.Sms,
      nominalFromRepresentation = \case
        ChannelRepresentation.Email -> EmailChannel
        ChannelRepresentation.Sms -> SmsChannel
    }

channelFixtures :: NominalFixtureCases Channel
channelFixtures =
  NominalFixtureCases
    ( NominalFixture "email" (String "email") EmailChannel
        :| [NominalFixture "sms" (String "sms") SmsChannel]
    )

stateWithoutHolder, stateWithHolder :: TemplateState
stateWithoutHolder = TemplateState templateId1 Nothing accountNumber EmailChannel Draft EmailChannel
stateWithHolder = TemplateState templateId2 (Just claimId) (AccountNumber "account-008") SmsChannel Published SmsChannel

templateStateFixtures :: FixtureCases TemplateState
templateStateFixtures =
  FixtureCases
    ( ("without-holder", stateWithoutHolder)
        :| [("with-holder", stateWithHolder)]
    )

templateStateBinding :: StructuralBinding TemplateState ShapeTemplateState.TemplateStateShape
templateStateBinding =
  StructuralBinding
    { bindingToShape = \(TemplateState templateId holder account channel kind fallbackChannel) ->
        ShapeTemplateState.TemplateState templateId holder account channel kind fallbackChannel,
      bindingFromShape = \(ShapeTemplateState.TemplateState templateId holder account channel kind fallbackChannel) ->
        TemplateState templateId holder account channel kind fallbackChannel
    }

templateRefFixtures :: FixtureCases TemplateRef
templateRefFixtures =
  FixtureCases
    ( ("by-id", ById templateId1)
        :| [ ("by-account", ByAccount accountNumber),
             ("by-channel", ByChannel EmailChannel),
             ("unknown", Unknown)
           ]
    )

templateRefBinding :: StructuralBinding TemplateRef ShapeTemplateRef.TemplateRefShape
templateRefBinding =
  StructuralBinding
    { bindingToShape = \case
        ById value -> ShapeTemplateRef.ById value
        ByAccount value -> ShapeTemplateRef.ByAccount value
        ByChannel value -> ShapeTemplateRef.ByChannel value
        Unknown -> ShapeTemplateRef.Unknown,
      bindingFromShape = \case
        ShapeTemplateRef.ById value -> ById value
        ShapeTemplateRef.ByAccount value -> ByAccount value
        ShapeTemplateRef.ByChannel value -> ByChannel value
        ShapeTemplateRef.Unknown -> Unknown
    }

initialTemplateBook :: TemplateBook
initialTemplateBook =
  TemplateBook
    [stateWithoutHolder, stateWithHolder]
    [Nothing, Just claimId]
    (Map.fromList [("primary", templateId1), ("secondary", templateId2)])
    (Map.fromList [(templateIdText1, "primary"), (templateIdText2, "secondary")])
    (Map.fromList [(claimId, stateWithHolder), (claimId2, stateWithoutHolder)])

templateBookFixtures :: FixtureCases TemplateBook
templateBookFixtures = FixtureCases (("two-templates", initialTemplateBook) :| [])

templateBookBinding :: StructuralBinding TemplateBook ShapeTemplateBook.TemplateBookShape
templateBookBinding =
  StructuralBinding
    { bindingToShape = \(TemplateBook templates holders byKey byTemplate claims) ->
        ShapeTemplateBook.TemplateBook
          (map (bindingToShape templateStateBinding) templates)
          holders
          byKey
          (Map.fromList [(parseCommittedTemplateId key, value) | (key, value) <- Map.toList byTemplate])
          (Map.map (bindingToShape templateStateBinding) claims),
      bindingFromShape = \(ShapeTemplateBook.TemplateBook templates holders byKey byTemplate claims) ->
        TemplateBook
          (map (bindingFromShape templateStateBinding) templates)
          holders
          byKey
          (Map.fromList [(templateIdText key, value) | (key, value) <- Map.toList byTemplate])
          (Map.map (bindingFromShape templateStateBinding) claims)
    }

templateLookupInputFixtures :: FixtureCases TemplateLookupInput
templateLookupInputFixtures = FixtureCases (("claim", TemplateLookupInput claimId) :| [])

templateLookupInputBinding :: StructuralBinding TemplateLookupInput ShapeTemplateLookupInput.TemplateLookupInputShape
templateLookupInputBinding =
  StructuralBinding
    { bindingToShape = \(TemplateLookupInput claim) -> ShapeTemplateLookupInput.TemplateLookupInput claim,
      bindingFromShape = \(ShapeTemplateLookupInput.TemplateLookupInput claim) -> TemplateLookupInput claim
    }

templateLookupRowFixtures :: FixtureCases TemplateLookupRow
templateLookupRowFixtures = FixtureCases (("template-claim", TemplateLookupRow templateId1 claimId) :| [])

templateLookupRowBinding :: StructuralBinding TemplateLookupRow ShapeTemplateLookupRow.TemplateLookupRowShape
templateLookupRowBinding =
  StructuralBinding
    { bindingToShape = \(TemplateLookupRow template claim) -> ShapeTemplateLookupRow.TemplateLookupRow template claim,
      bindingFromShape = \(ShapeTemplateLookupRow.TemplateLookupRow template claim) -> TemplateLookupRow template claim
    }

claimIdBinding :: NominalBinding ClaimId (KindID "claim")
claimIdBinding = NominalBinding unClaimId ClaimId

claimIdFixtures :: NominalFixtureCases ClaimId
claimIdFixtures =
  NominalFixtureCases
    ( NominalFixture "claim-1" (String claimIdText) claimId
        :| [NominalFixture "claim-2" (String claimIdText2) claimId2]
    )

accountNumberBinding :: NominalBinding AccountNumber Text
accountNumberBinding = NominalBinding unAccountNumber AccountNumber

accountNumberFixtures :: NominalFixtureCases AccountNumber
accountNumberFixtures = NominalFixtureCases (NominalFixture "account" (String "account-007") accountNumber :| [])

parseCommittedTemplateId :: Text -> TemplateId
parseCommittedTemplateId value = case parseTemplateId value of
  Left reason -> error ("invalid committed TemplateId fixture: " <> show reason)
  Right templateId -> templateId
