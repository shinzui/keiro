{-# LANGUAGE ImportQualifiedPost #-}
-- EP-4 integration: structural keywords never used as identifiers, so a
-- list like @accept A B C@ stops at the next block keyword.
-- EP-5 pgmq structural keywords.
-- EP-6 workflow/operation: reserved so the multi-word result-type parse and
-- node boundaries don't swallow the next block keyword.
-- EP-107 read-model structural words. Clause labels such as table and
-- schema remain usable identifiers because their block parser consumes
-- them with symbol-style matching.
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
{-# LANGUAGE ImportQualifiedPost #-}

-- | Parser primitives shared by every internal grammar concern.
module Keiro.Dsl.Parser.Core
  ( ContextualParseFailure (..),
    P,
    firstContextualFailure,
    contextualFailureAt,
    requireLanguageFeatureAt,
    sc,
    lexeme,
    symbol,
    keyword,
    identChar,
    asciiLetter,
    asciiUpper,
    asciiDigit,
    asciiAlphaNum,
    failAt,
    boundedDecimal,
    checkedDecimal,
    reservedWords,
    ident,
    wireWord,
    patchIdWord,
    getLoc,
    withOwnedSpan,
    spanOf,
    locatedValue,
    optionalLanguageFeature,
    pField,
    pVersion,
    pWindow,
    decimalText,
    signedDecimalText,
    integerLiteral,
    stringLit,
    brackets,
    braces,
    parens,
    pModulePrefix,
  )
where

import Data.Char (isAlpha, isAlphaNum, isAscii, isDigit, isSpace, isUpper)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Source
import Text.Megaparsec
import Text.Megaparsec.Char (char, digitChar, letterChar, space1)
import Text.Megaparsec.Char.Lexer qualified as L
import Prelude hiding (span)

data ContextualParseFailure = ContextualParseFailure
  { contextualFailureCode :: !SourceLanguageErrorCode,
    contextualFailureLine :: !Int
  }
  deriving stock (Eq, Ord, Show)

instance ShowErrorComponent ContextualParseFailure where
  showErrorComponent contextual = T.unpack (sourceLanguageErrorCodeText (contextualFailureCode contextual))

type P = Parsec ContextualParseFailure Text

firstContextualFailure :: ParseErrorBundle Text ContextualParseFailure -> Maybe ContextualParseFailure
firstContextualFailure bundle =
  case [ contextual
       | FancyError _ fancy <- NE.toList (bundleErrors bundle),
         ErrorCustom contextual <- Set.toList fancy
       ] of
    contextual : _ -> Just contextual
    [] -> Nothing

contextualFailureAt :: Loc -> SourceLanguageErrorCode -> P a
contextualFailureAt (Loc line) code = customFailure ContextualParseFailure {contextualFailureCode = code, contextualFailureLine = line}

requireLanguageFeatureAt :: LanguageVersion -> LanguageFeature -> Loc -> P ()
requireLanguageFeatureAt version feature loc
  | languageSupportsFeature version feature = pure ()
  | otherwise = contextualFailureAt loc LanguageFeatureRequiresVersion

-- | Space consumer: spaces, newlines, and @#@ line comments are all whitespace.
sc :: P ()
sc = L.space space1 (L.skipLineComment "#") empty

lexeme :: P a -> P a
lexeme = L.lexeme sc

symbol :: Text -> P Text
symbol = L.symbol sc

-- | A reserved keyword: the literal word not followed by an identifier
-- character (so @goto@ matches @goto@ but not @gotoX@).
keyword :: Text -> P ()
keyword w = (lexeme . try) (string' w *> notFollowedBy (identChar <|> (char '-' *> identChar)))
  where
    string' = chunk

identChar :: P Char
identChar = asciiAlphaNum <|> char '_'

asciiLetter :: P Char
asciiLetter = satisfy (\c -> isAscii c && isAlpha c)

asciiUpper :: P Char
asciiUpper = satisfy (\c -> isAscii c && isUpper c)

asciiDigit :: P Char
asciiDigit = satisfy (\c -> isAscii c && isDigit c)

asciiAlphaNum :: P Char
asciiAlphaNum = satisfy (\c -> isAscii c && isAlphaNum c)

-- | Fail with the diagnostic caret placed at a previously captured offset.
failAt :: Int -> String -> P a
failAt offset message = region (setErrorOffset offset) (fail message)

-- | Parse a decimal as an unbounded Integer, then reject values that cannot be
-- represented as Int. Parsing L.decimal directly at Int silently wraps.
boundedDecimal :: P Int
boundedDecimal = do
  offset <- getOffset
  value <- lexeme (L.decimal :: P Integer)
  checkedDecimal offset value

checkedDecimal :: Int -> Integer -> P Int
checkedDecimal offset value
  | value > fromIntegral (maxBound :: Int) =
      failAt
        offset
        ( "decimal literal "
            <> show value
            <> " is out of range (maximum "
            <> show (maxBound :: Int)
            <> ")"
        )
  | otherwise = pure (fromIntegral value)

-- | Words that may not be used as bare identifiers, because they introduce a
-- different construct and would otherwise be swallowed (e.g. @aggregate@ ending
-- one node and beginning the next).
reservedWords :: [Text]
reservedWords =
  [ "context",
    "module",
    "layout",
    "prefixed",
    "collocated",
    "id",
    "enum",
    "rule",
    "mapped",
    "ex",
    "aggregate",
    "regs",
    "states",
    "command",
    "event",
    "wire",
    "projection",
    "snapshot",
    "category",
    "guard",
    "write",
    "emit",
    "goto",
    "fields",
    "status-map",
    "true",
    "false",
    "retiring",
    "deprecated",
    "upcast",
    "from",
    "HOLE",
    "process",
    "router",
    "dispatch-each",
    "resolve",
    "read-model",
    "dispatch",
    "intake",
    "contract",
    "topic",
    "accept",
    "bind",
    "dedupe",
    "persist",
    "decode",
    "disposition",
    "publisher",
    "map",
    "workqueue",
    "queue",
    "payload",
    "retry",
    "fanout",
    "dedup",
    "enqueue",
    "seenIn",
    "workflow",
    "operation",
    "consistency",
    "body",
    "step",
    "await",
    "sleep",
    "child",
    "patch",
    "continueAsNew",
    "readmodel",
    "columns",
    "feed",
    "scope",
    "shape"
  ]

-- | A CamelCase / snake_case identifier (no dashes): type names, register
-- names, command\/event\/state names, enum constructors, projection keys.
ident :: P Name
ident = (lexeme . try) $ do
  c <- asciiLetter <|> char '_'
  cs <- many identChar
  let w = T.pack (c : cs)
  if w `elem` reservedWords
    then fail ("unexpected reserved word " <> T.unpack w)
    else pure w

-- | A wire-spelling token, which may contain dashes (@partial-divert@,
-- @hospital-capacity@). Used for the context name, id prefixes, enum wire
-- spellings, and status-map values.
wireWord :: P Text
wireWord = lexeme $ do
  c <- asciiLetter <|> asciiDigit
  cs <- many (identChar <|> char '-')
  pure (T.pack (c : cs))

-- | Patch ids use wire-word spelling, but admit @:@ so the validator can emit
-- the domain-specific 'WorkflowPatchIdInvalid' diagnostic at the owning item.
patchIdWord :: P Text
patchIdWord = lexeme $ do
  c <- asciiLetter <|> asciiDigit
  cs <- many (identChar <|> char '-' <|> char ':')
  pure (T.pack (c : cs))

getLoc :: P Loc
getLoc = (Loc . unPos . sourceLine) <$> getSourcePos

-- | Attach the exact syntax owned by a production. Existing token parsers
-- consume following trivia, so the consumed slice is scanned to exclude final
-- whitespace and @#@ comments from the half-open end point.
withOwnedSpan :: P a -> P (Located a)
withOwnedSpan parser = do
  startOffset <- getOffset
  startPosition <- getSourcePos
  startState <- getParserState
  inputBefore <- getInput
  value <- parser
  inputAfter <- getInput
  let consumedLength = T.length inputBefore - T.length inputAfter
      ownedLength = ownedSyntaxLength (T.take consumedLength inputBefore)
      endOffset = startOffset + ownedLength
      endPosition = pstateSourcePos (reachOffsetNoLine endOffset (statePosState startState))
      span =
        SourceSpan
          { source = sourceName startPosition,
            start = sourcePointAt startOffset startPosition,
            end = sourcePointAt endOffset endPosition
          }
  pure Located {span, value}

sourcePointAt :: Int -> SourcePos -> SourcePoint
sourcePointAt offset position =
  SourcePoint
    { offset,
      line = unPos (sourceLine position),
      column = unPos (sourceColumn position)
    }

spanOf :: Located a -> SourceSpan
spanOf Located {span} = span

locatedValue :: Located a -> a
locatedValue Located {value} = value

data TriviaScan
  = InSyntax
  | InString !Bool
  | InComment

ownedSyntaxLength :: Text -> Int
ownedSyntaxLength = go 0 InSyntax 0 . T.unpack
  where
    go _ _ lastOwned [] = lastOwned
    go index mode lastOwned (character : rest) =
      case mode of
        InComment
          | character == '\n' || character == '\r' -> go (index + 1) InSyntax lastOwned rest
          | otherwise -> go (index + 1) InComment lastOwned rest
        InString escaped
          | escaped -> go (index + 1) (InString False) (index + 1) rest
          | character == '\\' -> go (index + 1) (InString True) (index + 1) rest
          | character == '"' -> go (index + 1) InSyntax (index + 1) rest
          | otherwise -> go (index + 1) (InString False) (index + 1) rest
        InSyntax
          | character == '#' -> go (index + 1) InComment lastOwned rest
          | character == '"' -> go (index + 1) (InString False) (index + 1) rest
          | isSpace character -> go (index + 1) InSyntax lastOwned rest
          | otherwise -> go (index + 1) InSyntax (index + 1) rest

optionalLanguageFeature :: LanguageVersion -> LanguageFeature -> Text -> P a -> P (Maybe a)
optionalLanguageFeature version feature marker parser
  | languageSupportsFeature version feature = optional parser
  | otherwise = reject <|> pure Nothing
  where
    reject = do
      loc <- getLoc
      _ <- try (keyword marker)
      contextualFailureAt loc LanguageFeatureRequiresVersion

pField :: P Field
pField = do
  n <- ident
  mty <- optional (symbol ":" *> ident)
  pure Field {fieldName = n, fieldType = mty}

pVersion :: P Int
pVersion = do
  offset <- getOffset
  value <- lexeme (try (char 'v' *> (L.decimal :: P Integer) <* notFollowedBy identChar))
  checkedDecimal offset value

pWindow :: P Text
pWindow = lexeme $ do
  ds <- some digitChar
  u <- choice [char 's', char 'm', char 'h'] <?> "time unit: s, m, or h"
  notFollowedBy letterChar <?> "time unit: s, m, or h"
  pure (T.pack (ds <> [u]))

decimalText :: P Text
decimalText = lexeme $ do
  whole <- some digitChar
  fractional <- optional (char '.' *> some digitChar)
  pure (T.pack (whole <> maybe "" ('.' :) fractional))

signedDecimalText :: P Text
signedDecimalText = lexeme $ do
  sign <- optional (char '-')
  digits <- some digitChar
  fractional <- optional (char '.' *> some digitChar)
  pure (T.pack (maybe "" pure sign <> digits <> maybe "" ('.' :) fractional))

integerLiteral :: P Integer
integerLiteral = lexeme (L.signed (pure ()) L.decimal)

stringLit :: P Text
stringLit = lexeme $ do
  _ <- char '"'
  s <- many strChar
  _ <- char '"'
  pure (T.pack s)
  where
    strChar =
      choice
        [ char '\\' *> escapeCode,
          char '\n' *> fail "unescaped newline in string literal (write \\n)",
          anySingleBut '"'
        ]
    escapeCode =
      choice
        [ '"' <$ char '"',
          '\\' <$ char '\\',
          '\n' <$ char 'n',
          '\t' <$ char 't',
          '\r' <$ char 'r',
          anySingle >>= \c -> fail ("unknown escape sequence \\" <> [c] <> " in string literal")
        ]

brackets :: P a -> P a
brackets = between (symbol "[") (symbol "]")

braces :: P a -> P a
braces = between (symbol "{") (symbol "}")

parens :: P a -> P a
parens = between (symbol "(") (symbol ")")

-- | A dotted module prefix with one or more PascalCase segments.
pModulePrefix :: P Text
pModulePrefix = lexeme $ do
  seg0 <- pSeg
  segs <- many (char '.' *> pSeg)
  pure (T.intercalate "." (seg0 : segs))
  where
    pSeg = do
      c <- asciiUpper
      cs <- many identChar
      pure (T.pack (c : cs))
