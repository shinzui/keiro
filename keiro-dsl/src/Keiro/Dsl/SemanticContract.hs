-- | The effective runtime-semantics contract selected before semantic planning.
--
-- 'SourceLanguage' remains source provenance: a legacy-unversioned source and
-- an explicitly declared version-1 source are different source forms even
-- though they select the same language. 'EffectiveLanguageContract' is the
-- normalized service-level input used after parsing and workspace composition.
-- It deliberately wraps 'Spec' rather than becoming part of the graph.
module Keiro.Dsl.SemanticContract
  ( EffectiveLanguageContract,
    effectiveContractLanguageVersion,
    effectiveRuntimeProfile,
    effectiveRuntimeSemantics,
    effectiveLanguageSupport,
    languageContractNotice,
    effectiveLanguageContract,
    effectiveLanguageContractForVersion,
    runtimeSemanticsFingerprintSegments,
    CheckedService (..),
    checkedSource,
    checkedService,
    legacyCheckedService,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar (Spec)
import Keiro.Dsl.LanguageVersion
  ( LanguageSupport (..),
    LanguageVersion,
    ParsedSource (..),
    RuntimeSemanticsProfile,
    SourceLanguage (..),
    currentStableLanguageVersion,
    definitionRuntimeSemanticsProfile,
    effectiveLanguageVersion,
    languageSupportForVersion,
    languageSupportText,
    languageVersion,
    languageVersionNumber,
    languageVersionText,
    lookupLanguageDefinition,
    runtimeProfileFoldSegments,
    runtimeProfileIdentifier,
  )

-- | One effective released-language selection plus the runtime-semantics
-- generation it selects. Versions 1 and 2 differ in grammar capabilities but
-- normalize equivalent graphs to the same released runtime semantics. The next
-- contract that changes runtime behavior must receive a new discriminator here;
-- fold, replay, diff, and generation planners consume that discriminator rather
-- than re-deriving policy from source text.
data EffectiveLanguageContract = EffectiveLanguageContract
  { effectiveContractLanguageVersion :: !LanguageVersion,
    effectiveRuntimeProfile :: !RuntimeSemanticsProfile
  }
  deriving stock (Eq, Ord, Show)

-- | Stable compatibility projection for records, JSON, and diagnostics.
-- Runtime behavior queries 'effectiveRuntimeProfile' capabilities instead.
effectiveRuntimeSemantics :: EffectiveLanguageContract -> Text
effectiveRuntimeSemantics = runtimeProfileIdentifier . effectiveRuntimeProfile

-- | Lifecycle classification derived from the authoritative language registry.
effectiveLanguageSupport :: EffectiveLanguageContract -> LanguageSupport
effectiveLanguageSupport contract =
  fromMaybe
    (error "keiro-dsl internal invariant: effective contract selected an unregistered language version")
    (languageSupportForVersion (effectiveContractLanguageVersion contract))

-- | One stderr line naming a non-stable effective contract. Stable sources
-- stay silent so adopting the current contract does not add CLI noise.
languageContractNotice :: FilePath -> Text -> EffectiveLanguageContract -> Maybe Text
languageContractNotice subject sourceFormSummary contract
  | effectiveLanguageSupport contract == Stable = Nothing
  | otherwise =
      Just
        ( T.pack subject
            <> ": language contract: effective keiro-dsl "
            <> languageVersionText (effectiveContractLanguageVersion contract)
            <> " ("
            <> sourceFormSummary
            <> ", "
            <> languageSupportText (effectiveLanguageSupport contract)
            <> ", runtime semantics "
            <> effectiveRuntimeSemantics contract
            <> "); language-"
            <> languageVersionText currentStableLanguageVersion
            <> " strict spec-surface validation is not applied — declare `language keiro-dsl "
            <> languageVersionText currentStableLanguageVersion
            <> "` to adopt the stable contract"
        )

instance ToJSON EffectiveLanguageContract where
  toJSON contract =
    object
      [ "languageVersion" .= languageVersionNumber (effectiveContractLanguageVersion contract),
        "runtimeSemantics" .= effectiveRuntimeSemantics contract,
        "languageSupport" .= languageSupportText (effectiveLanguageSupport contract)
      ]

instance FromJSON EffectiveLanguageContract where
  parseJSON = withObject "EffectiveLanguageContract" $ \fields -> do
    rawVersion <- fields .: "languageVersion"
    runtimeSemantics <- fields .: "runtimeSemantics"
    version <- maybe (fail "semantic contract language version must be positive") pure (languageVersion rawVersion)
    contract <- maybe (fail "semantic contract language version is unsupported") pure (effectiveLanguageContractForVersion version)
    if effectiveRuntimeSemantics contract == runtimeSemantics
      then pure contract
      else
        fail
          ( "semantic contract runtimeSemantics does not match language version "
              <> show rawVersion
              <> ": expected "
              <> show (effectiveRuntimeSemantics contract)
              <> ", received "
              <> show (runtimeSemantics :: Text)
          )

-- | Resolve source provenance to the semantic contract used by every
-- downstream planner. This function is total for parsed sources: the parser has
-- already rejected unsupported language versions.
effectiveLanguageContract :: SourceLanguage -> EffectiveLanguageContract
effectiveLanguageContract sourceLanguage =
  fromMaybe
    (error "keiro-dsl internal invariant: parsed source selected an unregistered language version")
    (effectiveLanguageContractForVersion (effectiveLanguageVersion sourceLanguage))

-- | Resolve a supported released language version to its runtime contract.
-- Keeping this mapping next to 'CheckedService' makes adding successor runtime
-- semantics a compile-visible registry change.
effectiveLanguageContractForVersion :: LanguageVersion -> Maybe EffectiveLanguageContract
effectiveLanguageContractForVersion version = do
  definition <- lookupLanguageDefinition version
  pure
    EffectiveLanguageContract
      { effectiveContractLanguageVersion = version,
        effectiveRuntimeProfile = definitionRuntimeSemanticsProfile definition
      }

-- | Deduplicated, stable replay-fold segments explicitly declared by the
-- effective runtime capabilities. Grammar-, validation-, and codec-only
-- changes deliberately contribute no segment.
runtimeSemanticsFingerprintSegments :: EffectiveLanguageContract -> [Text]
runtimeSemanticsFingerprintSegments = runtimeProfileFoldSegments . effectiveRuntimeProfile

-- | A normalized service graph paired with the effective contract under which
-- it was checked. Member-level declared/legacy provenance intentionally stays
-- on 'ParsedSource' or 'Keiro.Dsl.Workspace.WorkspaceMember'.
data CheckedService = CheckedService
  { checkedLanguageContract :: !EffectiveLanguageContract,
    checkedSpec :: !Spec
  }
  deriving stock (Eq, Show)

-- | Construct the semantic input for one parsed source without losing the
-- selected contract.
checkedSource :: ParsedSource -> CheckedService
checkedSource parsed =
  checkedService (parsedSourceLanguage parsed) (parsedSpec parsed)

-- | Construct a service from a source-language selection and normalized graph.
-- Workspace composition uses this only after proving that every member has the
-- same effective version.
checkedService :: SourceLanguage -> Spec -> CheckedService
checkedService sourceLanguage spec =
  CheckedService
    { checkedLanguageContract = effectiveLanguageContract sourceLanguage,
      checkedSpec = spec
    }

-- | Compatibility bridge for callers that historically supplied only 'Spec'.
-- Such a caller necessarily opts into the legacy/version-1 runtime semantics.
legacyCheckedService :: Spec -> CheckedService
legacyCheckedService = checkedService LegacyUnversioned
