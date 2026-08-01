-- | Semantic selection of the published ID runtime contract.
module Keiro.Dsl.IdDomain
  ( IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    idDomainContractFor,
    idDomainAcceptsText,
    validateIdDomainText,
    idDomainTextPattern,
    idDomainSampleText,
  )
where

import Data.Text (Text)
import Keiro.Codec.IdDomain
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract, effectiveRuntimeSemantics)

-- | Versions 1 and 2 intentionally return 'Nothing': their generated IDs
-- admitted arbitrary text. Runtime-semantics generation 2 is the first
-- enforcing contract.
idDomainContractFor :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
idDomainContractFor languageContract prefix
  | effectiveRuntimeSemantics languageContract /= "keiro-dsl/runtime-semantics/2" = Nothing
  | otherwise = Just (typeIdV7Domain prefix)
