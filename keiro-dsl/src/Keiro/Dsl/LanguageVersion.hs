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

import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar (Loc (..), Spec)
import Numeric.Natural (Natural)

-- | A positive released Keiro DSL language version.
newtype LanguageVersion = LanguageVersion Natural
    deriving stock (Eq, Ord)

instance Show LanguageVersion where
    show = T.unpack . languageVersionText

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

-- | The body-parser configuration selected by a released version.
data LanguageBodyParser = LanguageBodyParserV1
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

-- | The authoritative, append-only registry of released language contracts.
languageRegistry :: NonEmpty LanguageDefinition
languageRegistry = LanguageDefinition version1 Nothing LanguageBodyParserV1 :| []

-- | Supported versions, derived from 'languageRegistry'.
supportedLanguageVersions :: NonEmpty LanguageVersion
supportedLanguageVersions = definitionVersion <$> languageRegistry

lookupLanguageDefinition :: LanguageVersion -> Maybe LanguageDefinition
lookupLanguageDefinition version =
    find ((== version) . definitionVersion) (NE.toList languageRegistry)

effectiveLanguageVersion :: SourceLanguage -> LanguageVersion
effectiveLanguageVersion LegacyUnversioned = version1
effectiveLanguageVersion DeclaredLanguage{declaredLanguageVersion = version} = version

-- | Stable codes for failures detected before a body grammar is selected.
data SourceLanguageErrorCode
    = InvalidLanguageVersion
    | UnsupportedLanguageVersion
    | DuplicateLanguagePreamble
    | MisplacedLanguagePreamble
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
