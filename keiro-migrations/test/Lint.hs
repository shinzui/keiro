module Lint (
    LintConfig (..),
    lintViolations,
) where

import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.Encoding.Error (lenientDecode)

{- | Pure migration-body lint, ported from codd-extras (Codd.Extras.Guards) when the
codd toolchain moved behind the legacy-codd-tools flag. The codd-era CONCURRENTLY
check is deliberately dropped: pg-migrate runs transactional migrations inside a
single transaction, and PostgreSQL rejects CREATE INDEX CONCURRENTLY in a
transaction block, so the mistake fails the first fresh-database test run instead
of needing a lint. Genuinely non-transactional migrations must carry pg-migrate's
"-- pg-migrate: no-transaction" leading comment, which review gates.
-}
data LintConfig = LintConfig
    { requiredQualifier :: Text
    , exemptFiles :: [FilePath]
    }
    deriving stock (Eq, Show)

-- | Lint migration bodies with intentionally simple SQL heuristics.
lintViolations :: LintConfig -> [(FilePath, ByteString)] -> [Text]
lintViolations config sources =
    concatMap lintOne (sortOn fst sources)
  where
    lintOne (file, bytes)
        | file `elem` exemptFiles config = []
        | otherwise =
            searchPathViolation file body
                <> concatMap (statementViolations file) statements
      where
        body = Text.Encoding.decodeUtf8With lenientDecode bytes
        statements = map Text.strip . Text.splitOn ";" $ stripCommentLines body

    requiredLower = Text.toCaseFold (requiredQualifier config)

    searchPathViolation file body =
        [ "migration body mentions search_path: " <> Text.pack file
        | "search_path" `Text.isInfixOf` Text.toCaseFold (stripCommentLines body)
        ]

    statementViolations file statement =
        case statementTarget statement of
            Nothing -> []
            Just target
                | requiredLower `Text.isPrefixOf` Text.toCaseFold (cleanTarget target) -> []
                | otherwise ->
                    [ "migration DDL target is not qualified with "
                        <> requiredQualifier config
                        <> " in "
                        <> Text.pack file
                        <> ": "
                        <> Text.take 120 (oneLine statement)
                    ]

statementTarget :: Text -> Maybe Text
statementTarget statement
    | Text.null trimmed = Nothing
    | lower `startsWithWords` ["create", "table"] =
        targetAfter ["create", "table"] wordsOriginal
    | lower `startsWithWords` ["alter", "table"] =
        targetAfter ["alter", "table"] wordsOriginal
    | lower `startsWithWords` ["drop", "index"] =
        targetAfter ["drop", "index"] wordsOriginal
    | lower `startsWithWords` ["create", "index"] =
        targetAfterToken "on" wordsOriginal
    | lower `startsWithWords` ["create", "unique", "index"] =
        targetAfterToken "on" wordsOriginal
    | lower `startsWithWords` ["create", "function"] =
        targetAfter ["create", "function"] wordsOriginal
    | lower `startsWithWords` ["create", "or", "replace", "function"] =
        targetAfter ["create", "or", "replace", "function"] wordsOriginal
    | lower `startsWithWords` ["create", "trigger"] =
        targetAfterToken "on" wordsOriginal
    | otherwise = Nothing
  where
    trimmed = Text.strip statement
    lower = Text.toCaseFold trimmed
    wordsOriginal = Text.words trimmed

startsWithWords :: Text -> [Text] -> Bool
startsWithWords statement wordsExpected =
    wordsExpected == take (length wordsExpected) (Text.words statement)

targetAfter :: [Text] -> [Text] -> Maybe Text
targetAfter prefix wordsOriginal =
    skipIfNotExists (drop (length prefix) wordsOriginal)

targetAfterToken :: Text -> [Text] -> Maybe Text
targetAfterToken token wordsOriginal =
    skipIfNotExists . drop 1 $ dropWhile ((/= token) . Text.toCaseFold) wordsOriginal

skipIfNotExists :: [Text] -> Maybe Text
skipIfNotExists (first : second : third : target : _)
    | map Text.toCaseFold [first, second, third] == ["if", "not", "exists"] = Just target
skipIfNotExists (first : second : target : _)
    | map Text.toCaseFold [first, second] == ["if", "exists"] = Just target
skipIfNotExists (target : _) = Just target
skipIfNotExists [] = Nothing

stripCommentLines :: Text -> Text
stripCommentLines =
    Text.unlines . filter (not . Text.isPrefixOf "--" . Text.strip) . Text.lines

cleanTarget :: Text -> Text
cleanTarget =
    Text.dropAround (`elem` ("\"(),;" :: String))

oneLine :: Text -> Text
oneLine =
    Text.unwords . Text.words
