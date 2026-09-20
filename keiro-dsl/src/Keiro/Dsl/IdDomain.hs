-- | Semantic selection of the published ID runtime contract.
module Keiro.Dsl.IdDomain
  ( IdAdmission (..),
    IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    v5OrV7IdDomainVersion,
    typeIdV7Domain,
    typeIdV5OrV7Domain,
    idDomainContractFor,
    idDomainContractForAdmission,
    idDomainContractForDeclaration,
    contractIdDomainContractFor,
    contractIdDomainContractForAdmission,
    idDomainIdentity,
    idDomainIdentitiesForService,
    idDomainAcceptsText,
    validateIdDomainText,
    idDomainTextPattern,
    idDomainSampleText,
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Codec.IdDomain
import Keiro.Dsl.Grammar (ContractEvent (..), ContractField (..), ContractNode (..), ContractType (..), IdDecl (..), Node (..), Spec (..))
import Keiro.Dsl.LanguageVersion (RuntimeCapability (..), runtimeProfileHasCapability)
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract (..), checkedLanguageContract, checkedSpec)

-- | Versions 1 and 2 intentionally return 'Nothing': their generated IDs
-- admitted arbitrary text. Runtime-semantics generation 2 is the first
-- enforcing contract. The candidate explicit-domain capability lets a
-- declaration select the wider frozen v5-or-v7 policy.
idDomainContractFor :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
idDomainContractFor languageContract prefix
  | runtimeProfileHasCapability ((.runtimeProfile) languageContract) GeneratedIdDomainTypeIdV7 =
      Just (typeIdV7Domain prefix)
  | otherwise = Nothing

idDomainContractForAdmission :: EffectiveLanguageContract -> IdAdmission -> Text -> Maybe IdDomainContract
idDomainContractForAdmission languageContract admission prefix
  | runtimeProfileHasCapability ((.runtimeProfile) languageContract) GeneratedIdDomainTypeIdV7 =
      Just (contractForAdmission admission prefix)
  | otherwise = Nothing

idDomainContractForDeclaration :: EffectiveLanguageContract -> IdDecl -> Maybe IdDomainContract
idDomainContractForDeclaration languageContract declaration =
  idDomainContractForAdmission languageContract ((.admission) declaration) ((.prefix) declaration)

-- | Public contract DTOs adopt the frozen TypeID-v7 admission contract only
-- in runtime semantics 3. Aggregate IDs retain the independent selector above.
contractIdDomainContractFor :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
contractIdDomainContractFor languageContract prefix
  | runtimeProfileHasCapability ((.runtimeProfile) languageContract) ContractIdDomainTypeIdV7 = Just (typeIdV7Domain prefix)
  | otherwise = Nothing

contractIdDomainContractForAdmission :: EffectiveLanguageContract -> IdAdmission -> Text -> Maybe IdDomainContract
contractIdDomainContractForAdmission languageContract admission prefix
  | runtimeProfileHasCapability ((.runtimeProfile) languageContract) ContractIdDomainTypeIdV7 = Just (contractForAdmission admission prefix)
  | otherwise = Nothing

contractForAdmission :: IdAdmission -> Text -> IdDomainContract
contractForAdmission TypeIdV7 = typeIdV7Domain
contractForAdmission TypeIdV5OrV7 = typeIdV5OrV7Domain

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
      [ idDomainIdentity ((.name) declaration) contract
      | declaration <- (.ids) spec,
        Just contract <- [idDomainContractForDeclaration languageContract declaration]
      ]
    contractIdentities =
      [ idDomainIdentity ("contract:" <> (.name) contractNode <> "." <> (.name) event <> "." <> (.name) field) contract
      | NContract contractNode <- (.nodes) spec,
        event <- (.events) contractNode,
        field <- (.fields) event,
        Just (admission, prefix) <- [contractFieldAdmission field],
        Just contract <- [contractIdDomainContractForAdmission languageContract admission prefix]
      ]
    contractFieldAdmission field = case (.valueType) field of
      CTypeId prefix -> Just (TypeIdV7, prefix)
      CDeclaredId name -> (\declaration -> ((.admission) declaration, (.prefix) declaration)) <$> find ((== name) . (.name)) ((.ids) spec)
      _ -> Nothing
