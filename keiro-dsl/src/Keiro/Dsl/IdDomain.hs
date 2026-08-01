-- | Semantic selection of the published ID runtime contract.
module Keiro.Dsl.IdDomain
  ( IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    idDomainContractFor,
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
import Keiro.Dsl.Grammar (IdDecl (..), Spec (..))
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, effectiveRuntimeSemantics)

-- | Versions 1 and 2 intentionally return 'Nothing': their generated IDs
-- admitted arbitrary text. Runtime-semantics generation 2 is the first
-- enforcing contract.
idDomainContractFor :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
idDomainContractFor languageContract prefix
  | effectiveRuntimeSemantics languageContract /= "keiro-dsl/runtime-semantics/2" = Nothing
  | otherwise = Just (typeIdV7Domain prefix)

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
  [ idDomainIdentity (idName declaration) contract
  | declaration <- specIds (checkedSpec service),
    Just contract <- [idDomainContractFor (checkedLanguageContract service) (idPrefix declaration)]
  ]
