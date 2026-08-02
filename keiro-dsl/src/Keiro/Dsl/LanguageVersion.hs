{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | The released-language contract selected by a @.keiro@ source.
--
-- Source-language provenance deliberately wraps the semantic 'Spec' rather than
-- becoming part of it.  A workspace can therefore merge semantically equivalent
-- legacy and explicitly versioned members without inventing one declaration for
-- the merged graph.
module Keiro.Dsl.LanguageVersion
  ( LanguageVersion,
    languageVersion,
    languageVersionNumber,
    languageVersionText,
    SourceLanguage (..),
    sourceFormText,
    declaredLanguageVersionMaybe,
    effectiveLanguageVersion,
    LanguageBodyParser (..),
    SyntaxProfile,
    syntaxProfileIdentifier,
    syntaxProfileSupportsFeature,
    RuntimeSemanticsProfile,
    runtimeProfileIdentifier,
    runtimeProfileHasCapability,
    runtimeProfileFoldSegments,
    RuntimeCapability (..),
    capabilityFoldSegment,
    LanguageDefinition (..),
    definitionRuntimeSemantics,
    languageRegistry,
    supportedLanguageVersions,
    lookupLanguageDefinition,
    LanguageFeature (..),
    languageFeatureMinimumVersion,
    languageVersionsSupportingFeature,
    languageSupportsFeature,
    SourceLanguageErrorCode (..),
    sourceLanguageErrorCodeText,
    SourceLanguageDiagnostic (..),
    sourceLanguageDiagnosticMessage,
    renderSourceLanguageDiagnostic,
    ParsedSource (..),
    ParseFailure (..),
    renderParseFailure,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar (Loc (..), Spec, noLoc)
import Numeric.Natural (Natural)

-- | A positive released Keiro DSL language version.
newtype LanguageVersion = LanguageVersion Natural
  deriving stock (Eq, Ord)

instance Show LanguageVersion where
  show = T.unpack . languageVersionText

instance ToJSON LanguageVersion where
  toJSON = toJSON . languageVersionNumber

instance FromJSON LanguageVersion where
  parseJSON value = do
    raw <- parseJSON value
    maybe (fail "language version must be a positive decimal") pure (languageVersion raw)

-- | Construct a version, rejecting zero because released versions are positive.
languageVersion :: Natural -> Maybe LanguageVersion
languageVersion 0 = Nothing
languageVersion value = Just (LanguageVersion value)

-- | Extract the positive decimal value.
languageVersionNumber :: LanguageVersion -> Natural
languageVersionNumber (LanguageVersion value) = value

languageVersionText :: LanguageVersion -> Text
languageVersionText = T.pack . show . languageVersionNumber

-- | Whether a source declared a contract or entered through the legacy bridge.
data SourceLanguage
  = LegacyUnversioned
  | DeclaredLanguage
      { declaredLanguageVersion :: !LanguageVersion,
        languageVersionLoc :: !Loc
      }
  deriving stock (Eq, Show)

sourceFormText :: SourceLanguage -> Text
sourceFormText LegacyUnversioned = "legacy-unversioned"
sourceFormText DeclaredLanguage {} = "declared"

declaredLanguageVersionMaybe :: SourceLanguage -> Maybe LanguageVersion
declaredLanguageVersionMaybe LegacyUnversioned = Nothing
declaredLanguageVersionMaybe DeclaredLanguage {declaredLanguageVersion = version} = Just version

-- | The body-parser configuration selected by a released version.
data LanguageBodyParser
  = LanguageBodyParserV1
  | LanguageBodyParserV2
  deriving stock (Eq, Show)

-- | An immutable, explicitly named set of source-language capabilities.
-- Constructors stay private so a released profile can only be selected from
-- the authoritative registry rather than widened ad hoc by parser callers.
data SyntaxProfile = SyntaxProfile
  { profileIdentifier :: !Text,
    profileFeatures :: !(Set LanguageFeature)
  }
  deriving stock (Eq, Show, Generic)

syntaxProfileIdentifier :: SyntaxProfile -> Text
syntaxProfileIdentifier SyntaxProfile {profileIdentifier} = profileIdentifier

syntaxProfileSupportsFeature :: SyntaxProfile -> LanguageFeature -> Bool
syntaxProfileSupportsFeature SyntaxProfile {profileFeatures} feature = Set.member feature profileFeatures

-- | One independently selectable runtime behavior in a released language
-- contract.  Constructors are append-only: registry profiles are monotone, and
-- 'capabilityFoldSegment' must make an explicit fingerprint decision for every
-- new constructor.
data RuntimeCapability
  = GeneratedIdDomainTypeIdV7
  | NominalEqualityV2
  | ContractIdDomainTypeIdV7
  | StrictSpecSurfaceValidation
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | An immutable, explicitly named set of runtime capabilities.  The
-- constructor stays private so callers select only an authoritative registry
-- profile rather than widening runtime behavior ad hoc.
data RuntimeSemanticsProfile = RuntimeSemanticsProfile
  { runtimeSemanticsIdentifier :: !Text,
    runtimeSemanticsCapabilities :: !(Set RuntimeCapability)
  }
  deriving stock (Eq, Ord, Show, Generic)

runtimeProfileIdentifier :: RuntimeSemanticsProfile -> Text
runtimeProfileIdentifier RuntimeSemanticsProfile {runtimeSemanticsIdentifier} = runtimeSemanticsIdentifier

runtimeProfileHasCapability :: RuntimeSemanticsProfile -> RuntimeCapability -> Bool
runtimeProfileHasCapability RuntimeSemanticsProfile {runtimeSemanticsCapabilities} capability =
  Set.member capability runtimeSemanticsCapabilities

-- | Optional replay-fold identity contributed by one capability.  Duplicate
-- tokens intentionally collapse at the profile boundary so the two coupled
-- language-3 behaviors preserve their historical single segment.
capabilityFoldSegment :: RuntimeCapability -> Maybe Text
capabilityFoldSegment GeneratedIdDomainTypeIdV7 = Just "semantic-contract:keiro-dsl/runtime-semantics/2"
capabilityFoldSegment NominalEqualityV2 = Just "semantic-contract:keiro-dsl/runtime-semantics/2"
capabilityFoldSegment ContractIdDomainTypeIdV7 = Nothing
capabilityFoldSegment StrictSpecSurfaceValidation = Nothing

runtimeProfileFoldSegments :: RuntimeSemanticsProfile -> [Text]
runtimeProfileFoldSegments RuntimeSemanticsProfile {runtimeSemanticsCapabilities} =
  Set.toAscList
    ( Set.fromList
        [ segment
        | capability <- Set.toAscList runtimeSemanticsCapabilities,
          Just segment <- [capabilityFoldSegment capability]
        ]
    )

-- | One append-only released-language registry entry.
data LanguageDefinition = LanguageDefinition
  { definitionVersion :: !LanguageVersion,
    definitionPredecessor :: !(Maybe LanguageVersion),
    -- | Compatibility projection retained for the 0.7 public API. Parser
    -- dispatch uses 'definitionSyntaxProfile', never this historical tag.
    definitionBodyParser :: !LanguageBodyParser,
    definitionSyntaxProfile :: !SyntaxProfile,
    definitionRuntimeSemanticsProfile :: !RuntimeSemanticsProfile
  }
  deriving stock (Eq, Show, Generic)

-- | Stable compatibility projection used by serialized records and diagnostic
-- text.  Runtime behavior must query 'definitionRuntimeSemanticsProfile'.
definitionRuntimeSemantics :: LanguageDefinition -> Text
definitionRuntimeSemantics = runtimeProfileIdentifier . definitionRuntimeSemanticsProfile

version1 :: LanguageVersion
version1 = LanguageVersion 1

version2 :: LanguageVersion
version2 = LanguageVersion 2

version3 :: LanguageVersion
version3 = LanguageVersion 3

version4 :: LanguageVersion
version4 = LanguageVersion 4

-- | The authoritative, append-only registry of released language contracts.
languageRegistry :: NonEmpty LanguageDefinition
languageRegistry =
  LanguageDefinition version1 Nothing LanguageBodyParserV1 profileV1 runtimeProfileV1
    :| [ LanguageDefinition version2 (Just version1) LanguageBodyParserV2 profileV2 runtimeProfileV1,
         LanguageDefinition version3 (Just version2) LanguageBodyParserV2 profileV2 runtimeProfileV2,
         LanguageDefinition version4 (Just version3) LanguageBodyParserV2 profileV2 runtimeProfileV3
       ]

profileV1 :: SyntaxProfile
profileV1 = SyntaxProfile "keiro-dsl/syntax-profile/1" Set.empty

profileV2 :: SyntaxProfile
profileV2 =
  SyntaxProfile
    "keiro-dsl/syntax-profile/2"
    ( Set.fromList
        [ NominalBindingSyntax,
          IntegerScalarSyntax,
          TypedAggregateExpressionSyntax,
          ExplicitTransitionImplementationSyntax
        ]
    )

runtimeProfileV1 :: RuntimeSemanticsProfile
runtimeProfileV1 =
  RuntimeSemanticsProfile
    "keiro-dsl/runtime-semantics/1"
    Set.empty

runtimeProfileV2 :: RuntimeSemanticsProfile
runtimeProfileV2 =
  RuntimeSemanticsProfile
    "keiro-dsl/runtime-semantics/2"
    (Set.fromList [GeneratedIdDomainTypeIdV7, NominalEqualityV2])

runtimeProfileV3 :: RuntimeSemanticsProfile
runtimeProfileV3 =
  RuntimeSemanticsProfile
    "keiro-dsl/runtime-semantics/3"
    ( Set.fromList
        [ GeneratedIdDomainTypeIdV7,
          NominalEqualityV2,
          ContractIdDomainTypeIdV7,
          StrictSpecSurfaceValidation
        ]
    )

-- | Supported versions, derived from 'languageRegistry'.
supportedLanguageVersions :: NonEmpty LanguageVersion
supportedLanguageVersions = definitionVersion <$> languageRegistry

lookupLanguageDefinition :: LanguageVersion -> Maybe LanguageDefinition
lookupLanguageDefinition version =
  find ((== version) . definitionVersion) (NE.toList languageRegistry)

-- | Grammar-owned syntax introduced after the frozen version-1 contract.
-- Keeping these gates beside the released-language registry prevents the
-- parser from growing an independent list of textual spellings.
data LanguageFeature
  = NominalBindingSyntax
  | IntegerScalarSyntax
  | TypedAggregateExpressionSyntax
  | ExplicitTransitionImplementationSyntax
  deriving stock (Eq, Ord, Show)

-- | The first released contract that owns each grammar feature.
languageFeatureMinimumVersion :: LanguageFeature -> LanguageVersion
languageFeatureMinimumVersion feature =
  case find (\definition -> syntaxProfileSupportsFeature (definitionSyntaxProfile definition) feature) (NE.toList languageRegistry) of
    Just definition -> definitionVersion definition
    Nothing -> error "keiro-dsl internal invariant: a released language feature has no owning profile"

languageVersionsSupportingFeature :: LanguageFeature -> [LanguageVersion]
languageVersionsSupportingFeature feature =
  [ definitionVersion definition
  | definition <- NE.toList languageRegistry,
    syntaxProfileSupportsFeature (definitionSyntaxProfile definition) feature
  ]

languageSupportsFeature :: LanguageVersion -> LanguageFeature -> Bool
languageSupportsFeature version feature =
  maybe False (\definition -> syntaxProfileSupportsFeature (definitionSyntaxProfile definition) feature) (lookupLanguageDefinition version)

effectiveLanguageVersion :: SourceLanguage -> LanguageVersion
effectiveLanguageVersion LegacyUnversioned = version1
effectiveLanguageVersion DeclaredLanguage {declaredLanguageVersion = version} = version

instance ToJSON SourceLanguage where
  toJSON sourceLanguage =
    object
      [ "sourceForm" .= sourceFormText sourceLanguage,
        "declaredLanguageVersion" .= declaredLanguageVersionMaybe sourceLanguage,
        "effectiveLanguageVersion" .= effectiveLanguageVersion sourceLanguage
      ]

instance FromJSON SourceLanguage where
  parseJSON = withObject "SourceLanguage" $ \fields -> do
    sourceForm <- fields .: "sourceForm"
    declared <- fields .:? "declaredLanguageVersion"
    effective <- fields .: "effectiveLanguageVersion"
    case (sourceForm :: Text, declared) of
      ("legacy-unversioned", Nothing)
        | effective == effectiveLanguageVersion LegacyUnversioned -> pure LegacyUnversioned
        | otherwise -> fail "legacy-unversioned source must select effective language version 1"
      ("declared", Just version)
        | effective == version -> pure (DeclaredLanguage version noLoc)
        | otherwise -> fail "declared and effective language versions must match"
      ("legacy-unversioned", Just _) -> fail "legacy-unversioned source cannot declare a language version"
      ("declared", Nothing) -> fail "declared source must include declaredLanguageVersion"
      (other, _) -> fail ("unknown source form: " <> T.unpack other)

-- | Stable codes for failures detected before a body grammar is selected.
data SourceLanguageErrorCode
  = InvalidLanguageVersion
  | UnsupportedLanguageVersion
  | DuplicateLanguagePreamble
  | MisplacedLanguagePreamble
  | LanguageFeatureRequiresVersion
  deriving stock (Eq, Ord, Show)

sourceLanguageErrorCodeText :: SourceLanguageErrorCode -> Text
sourceLanguageErrorCodeText = T.pack . show

-- | A source-selection failure with the original member-local source line.
data SourceLanguageDiagnostic = SourceLanguageDiagnostic
  { sourceLanguageErrorCode :: !SourceLanguageErrorCode,
    sourceLanguageSource :: !FilePath,
    sourceLanguageLoc :: !Loc,
    sourceLanguageToken :: !(Maybe Text),
    sourceLanguageDeclaredVersion :: !(Maybe LanguageVersion),
    sourceLanguageSupportedVersions :: !(NonEmpty LanguageVersion)
  }
  deriving stock (Eq, Show)

renderSourceLanguageDiagnostic :: SourceLanguageDiagnostic -> Text
renderSourceLanguageDiagnostic diagnostic =
  T.pack (sourceLanguageSource diagnostic)
    <> ":"
    <> T.pack (show line)
    <> ":1: error ["
    <> sourceLanguageErrorCodeText code
    <> "]: "
    <> sourceLanguageDiagnosticMessage diagnostic
  where
    Loc line = sourceLanguageLoc diagnostic
    code = sourceLanguageErrorCode diagnostic

sourceLanguageDiagnosticMessage :: SourceLanguageDiagnostic -> Text
sourceLanguageDiagnosticMessage diagnostic = detail
  where
    code = sourceLanguageErrorCode diagnostic
    supported = T.intercalate ", " (map languageVersionText (NE.toList (sourceLanguageSupportedVersions diagnostic)))
    token = maybe "<missing>" id (sourceLanguageToken diagnostic)
    detail = case code of
      InvalidLanguageVersion ->
        "invalid language preamble; expected `language keiro-dsl <positive-decimal>`, found `"
          <> token
          <> "`"
      UnsupportedLanguageVersion ->
        "declared keiro-dsl language version "
          <> maybe token languageVersionText (sourceLanguageDeclaredVersion diagnostic)
          <> " is unsupported; supported versions: "
          <> supported
      DuplicateLanguagePreamble ->
        "duplicate language preamble; exactly one may appear before `context`"
      MisplacedLanguagePreamble ->
        "misplaced language preamble; it must be the first significant clause before `context`"
      LanguageFeatureRequiresVersion ->
        "selected syntax requires keiro-dsl language version "
          <> languageVersionText (NE.last (sourceLanguageSupportedVersions diagnostic))
          <> "; selected version "
          <> maybe token languageVersionText (sourceLanguageDeclaredVersion diagnostic)

-- | A parsed document with its source declaration preserved beside its graph.
data ParsedSource = ParsedSource
  { parsedSourceLanguage :: !SourceLanguage,
    parsedSpec :: !Spec
  }
  deriving stock (Eq, Show)

-- | The parse boundary distinguishes source selection from body grammar errors.
data ParseFailure
  = SourceLanguageFailure !SourceLanguageDiagnostic
  | BodyGrammarFailure !Text
  deriving stock (Eq, Show)

renderParseFailure :: ParseFailure -> Text
renderParseFailure (SourceLanguageFailure diagnostic) = renderSourceLanguageDiagnostic diagnostic
renderParseFailure (BodyGrammarFailure message) = message
