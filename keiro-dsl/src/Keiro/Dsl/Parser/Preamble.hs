{-# LANGUAGE ImportQualifiedPost #-}

-- | Released-language preamble recognition and source selection.
module Keiro.Dsl.Parser.Preamble
  ( contextualDiagnostic,
    pDeclaredPreamble,
    selectSourceLanguage,
    unsupportedDiagnostic,
  )
where

import Data.Char (isAscii, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Keiro.Dsl.Grammar (Loc (..))
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Core
import Numeric.Natural (Natural)
import Text.Megaparsec
import Text.Megaparsec.Char (char)

contextualDiagnostic :: FilePath -> SourceLanguage -> ContextualParseFailure -> SourceLanguageDiagnostic
contextualDiagnostic src sourceLanguage contextual =
  SourceLanguageDiagnostic
    { sourceLanguageErrorCode = code,
      sourceLanguageSource = src,
      sourceLanguageLoc = Loc (contextualFailureLine contextual),
      sourceLanguageToken = case code of
        LanguageFeatureRequiresVersion -> Just (languageVersionText effectiveVersion)
        _ -> Nothing,
      sourceLanguageDeclaredVersion = case code of
        LanguageFeatureRequiresVersion -> Just effectiveVersion
        _ -> Nothing,
      sourceLanguageSupportedVersions = supportedLanguageVersions
    }
  where
    code = contextualFailureCode contextual
    effectiveVersion = effectiveLanguageVersion sourceLanguage

-- | Consume a preamble already validated by 'selectSourceLanguage'. This
-- parser is also reused at grammar boundaries to recognize only complete
-- preamble syntax, never a nested identifier whose spelling is @language@.
pDeclaredPreamble :: P ()
pDeclaredPreamble = do
  keyword "language"
  keyword "keiro-dsl"
  _ <- lexeme (some asciiDigit)
  pure ()

-- | The source-selection pass inspects only the first grammar clause after
-- leading whitespace and comments. Body lines are left entirely to
-- 'pSurfaceSpec'.
data InitialLanguageClause = InitialLanguageClause
  { initialLanguageLine :: !Int,
    initialLanguageText :: !Text
  }

selectSourceLanguage :: FilePath -> Text -> Either ParseFailure SourceLanguage
selectSourceLanguage src input = do
  initialClause <- case runParser pInitialLanguageClause src input of
    Left bundle -> Left (BodyGrammarFailure (T.pack (errorBundlePretty bundle)))
    Right value -> Right value
  case initialClause of
    Nothing -> Right LegacyUnversioned
    Just languageClause -> do
      version <- parsePreamble languageClause
      case lookupLanguageDefinition version of
        Nothing -> Left (sourceFailure UnsupportedLanguageVersion languageClause (Just (languageVersionText version)) (Just version))
        Just _ -> Right (DeclaredLanguage version (Loc (initialLanguageLine languageClause)))
  where
    sourceFailure code line tokenText declared =
      SourceLanguageFailure
        SourceLanguageDiagnostic
          { sourceLanguageErrorCode = code,
            sourceLanguageSource = src,
            sourceLanguageLoc = Loc (initialLanguageLine line),
            sourceLanguageToken = tokenText,
            sourceLanguageDeclaredVersion = declared,
            sourceLanguageSupportedVersions = supportedLanguageVersions
          }

    parsePreamble line = case T.words (initialLanguageText line) of
      ["language", "keiro-dsl", tokenText]
        | T.all (\c -> isAscii c && isDigit c) tokenText && not (T.null tokenText) ->
            case TR.decimal tokenText :: Either String (Natural, Text) of
              Right (value, "") -> case languageVersion value of
                Just version -> Right version
                Nothing -> invalid line tokenText
              _ -> invalid line tokenText
      wordsFound -> invalid line (T.unwords wordsFound)

    invalid line tokenText =
      Left (sourceFailure InvalidLanguageVersion line (Just tokenText) Nothing)

pInitialLanguageClause :: P (Maybe InitialLanguageClause)
pInitialLanguageClause = sc *> optional pLanguageClause
  where
    pLanguageClause = do
      position <- getSourcePos
      _ <- lookAhead (chunk "language" *> notFollowedBy (identChar <|> (char '-' *> identChar)))
      rawLine <- takeWhileP (Just "language preamble") (\c -> c /= '\n' && c /= '\r')
      let content = T.strip (T.takeWhile (/= '#') rawLine)
      pure InitialLanguageClause {initialLanguageLine = unPos (sourceLine position), initialLanguageText = content}

unsupportedDiagnostic :: FilePath -> SourceLanguage -> ParseFailure
unsupportedDiagnostic src sourceLanguage =
  SourceLanguageFailure
    SourceLanguageDiagnostic
      { sourceLanguageErrorCode = UnsupportedLanguageVersion,
        sourceLanguageSource = src,
        sourceLanguageLoc = case sourceLanguage of
          LegacyUnversioned -> Loc 1
          DeclaredLanguage {languageVersionLoc = loc} -> loc,
        sourceLanguageToken = Just (languageVersionText (effectiveLanguageVersion sourceLanguage)),
        sourceLanguageDeclaredVersion = Just (effectiveLanguageVersion sourceLanguage),
        sourceLanguageSupportedVersions = supportedLanguageVersions
      }
