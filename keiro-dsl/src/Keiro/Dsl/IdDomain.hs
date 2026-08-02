-- | Semantic selection of the published ID runtime contract.
module Keiro.Dsl.IdDomain
  ( IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    idDomainContractFor,
    contractIdDomainContractFor,
    idDomainIdentity,
    idDomainIdentitiesForService,
    idDomainAcceptsText,
    validateIdDomainText,
    idDomainTextPattern,
    idDomainSampleText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Codec.IdDomain
import Keiro.Dsl.Grammar (ContractEvent (..), ContractField (..), ContractNode (..), ContractType (..), IdDecl (..), Node (..), Spec (..))
import Keiro.Dsl.LanguageVersion (RuntimeCapability (..), runtimeProfileHasCapability)
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, effectiveRuntimeProfile)

-- | Versions 1 and 2 intentionally return 'Nothing': their generated IDs
-- admitted arbitrary text. Runtime-semantics generation 2 is the first
-- enforcing contract.
idDomainContractFor :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
idDomainContractFor languageContract prefix
  | runtimeProfileHasCapability (effectiveRuntimeProfile languageContract) GeneratedIdDomainTypeIdV7 =
      Just (typeIdV7Domain prefix)
  | otherwise = Nothing

-- | Public contract DTOs adopt the frozen TypeID-v7 admission contract only
-- in runtime semantics 3. Aggregate IDs retain the independent selector above.
contractIdDomainContractFor :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
contractIdDomainContractFor languageContract prefix
  | runtimeProfileHasCapability (effectiveRuntimeProfile languageContract) ContractIdDomainTypeIdV7 = Just (typeIdV7Domain prefix)
  | otherwise = Nothing

-- | Durable identity for the runtime admission domain of one declaration.
-- This is deliberately separate from nominal equality: IDs without equality
-- expressions still have a construction and codec contract.
idDomainIdentity :: Text -> IdDomainContract -> Text
idDomainIdentity name contract =
  T.intercalate
    "|"
    [ "id-domain",
      "name=" <> name,
      "contract=" <> idDomainVersion contract,
      "prefix=" <> idDomainPrefix contract,
      "separator=" <> T.singleton (idDomainSeparator contract),
      "json=" <> idDomainJsonRepresentation contract
    ]

idDomainIdentitiesForService :: CheckedService -> [Text]
idDomainIdentitiesForService service =
  aggregateIdentities <> contractIdentities
  where
    spec = checkedSpec service
    languageContract = checkedLanguageContract service
    aggregateIdentities =
      [ idDomainIdentity (idName declaration) contract
      | declaration <- specIds spec,
        Just contract <- [idDomainContractFor languageContract (idPrefix declaration)]
      ]
    contractIdentities =
      [ idDomainIdentity ("contract:" <> ctrName contractNode <> "." <> ceName event <> "." <> cfName field) contract
      | NContract contractNode <- specNodes spec,
        event <- ctrEvents contractNode,
        field <- ceFields event,
        CTypeId prefix <- [cfType field],
        Just contract <- [contractIdDomainContractFor languageContract prefix]
      ]
