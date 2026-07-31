{- | The released-language contract selected by a @.keiro@ source.

Source-language provenance deliberately wraps the semantic 'Spec' rather than
becoming part of it.  A workspace can therefore merge semantically equivalent
legacy and explicitly versioned members without inventing one declaration for
the merged graph.
-}
module Keiro.Dsl.LanguageVersion (
    LanguageVersion,
    languageVersion,
    languageVersionNumber,
    languageVersionText,
    SourceLanguage (..),
    sourceFormText,
    declaredLanguageVersionMaybe,
    effectiveLanguageVersion,
    LanguageBodyParser (..),
    LanguageDefinition (..),
    languageRegistry,
    supportedLanguageVersions,
    lookupLanguageDefinition,
    SourceLanguageErrorCode (..),
    sourceLanguageErrorCodeText,
    SourceLanguageDiagnostic (..),
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
import Data.Text (Text)
import Data.Text qualified as T
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
        { declaredLanguageVersion :: !LanguageVersion
        , languageVersionLoc :: !Loc
        }
    deriving stock (Eq, Show)

sourceFormText :: SourceLanguage -> Text
sourceFormText LegacyUnversioned = "legacy-unversioned"
sourceFormText DeclaredLanguage{} = "declared"

declaredLanguageVersionMaybe :: SourceLanguage -> Maybe LanguageVersion
declaredLanguageVersionMaybe LegacyUnversioned = Nothing
declaredLanguageVersionMaybe DeclaredLanguage{declaredLanguageVersion = version} = Just version

-- | The body-parser configuration selected by a released version.
data LanguageBodyParser
    = LanguageBodyParserV1
    | LanguageBodyParserV2
    deriving stock (Eq, Show)

-- | One append-only released-language registry entry.
data LanguageDefinition = LanguageDefinition
    { definitionVersion :: !LanguageVersion
    , definitionPredecessor :: !(Maybe LanguageVersion)
    , definitionBodyParser :: !LanguageBodyParser
    }
    deriving stock (Eq, Show)

version1 :: LanguageVersion
version1 = LanguageVersion 1

version2 :: LanguageVersion
version2 = LanguageVersion 2

-- | The authoritative, append-only registry of released language contracts.
languageRegistry :: NonEmpty LanguageDefinition
languageRegistry =
    LanguageDefinition version1 Nothing LanguageBodyParserV1
        :| [LanguageDefinition version2 (Just version1) LanguageBodyParserV2]

-- | Supported versions, derived from 'languageRegistry'.
supportedLanguageVersions :: NonEmpty LanguageVersion
supportedLanguageVersions = definitionVersion <$> languageRegistry

lookupLanguageDefinition :: LanguageVersion -> Maybe LanguageDefinition
lookupLanguageDefinition version =
    find ((== version) . definitionVersion) (NE.toList languageRegistry)

effectiveLanguageVersion :: SourceLanguage -> LanguageVersion
effectiveLanguageVersion LegacyUnversioned = version1
effectiveLanguageVersion DeclaredLanguage{declaredLanguageVersion = version} = version

instance ToJSON SourceLanguage where
    toJSON sourceLanguage =
        object
            [ "sourceForm" .= sourceFormText sourceLanguage
            , "declaredLanguageVersion" .= declaredLanguageVersionMaybe sourceLanguage
            , "effectiveLanguageVersion" .= effectiveLanguageVersion sourceLanguage
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
    { sourceLanguageErrorCode :: !SourceLanguageErrorCode
    , sourceLanguageSource :: !FilePath
    , sourceLanguageLoc :: !Loc
    , sourceLanguageToken :: !(Maybe Text)
    , sourceLanguageDeclaredVersion :: !(Maybe LanguageVersion)
    , sourceLanguageSupportedVersions :: !(NonEmpty LanguageVersion)
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
        <> detail
  where
    Loc line = sourceLanguageLoc diagnostic
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
            "nominal binding syntax requires keiro-dsl language version "
                <> languageVersionText (NE.last (sourceLanguageSupportedVersions diagnostic))
                <> "; selected version "
                <> maybe token languageVersionText (sourceLanguageDeclaredVersion diagnostic)

-- | A parsed document with its source declaration preserved beside its graph.
data ParsedSource = ParsedSource
    { parsedSourceLanguage :: !SourceLanguage
    , parsedSpec :: !Spec
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
