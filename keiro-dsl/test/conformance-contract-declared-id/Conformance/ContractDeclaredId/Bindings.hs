{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Conformance.ContractDeclaredId.Bindings where

import Conformance.ContractDeclaredId.Domain
import Data.Aeson (Value (String))
import Data.KindID qualified as KindID
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))

claimIdText :: Text
claimIdText = "claim_01h455vb4pex5vsknk084sn02q"

claimId :: ClaimId
claimId = case KindID.parseText @"claim" claimIdText of
  Left reason -> error ("invalid committed ClaimId fixture: " <> show reason)
  Right value -> ClaimId value

claimIdBinding :: NominalBinding ClaimId (KindID.KindID "claim")
claimIdBinding = NominalBinding unClaimId ClaimId

claimIdFixtures :: NominalFixtureCases ClaimId
claimIdFixtures = NominalFixtureCases (NominalFixture "claim" (String claimIdText) claimId :| [])
