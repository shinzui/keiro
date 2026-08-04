-- | Pure planning and token-aware rewriting for generated-Haskell name moves.
module Keiro.Dsl.HaskellSourceMove
  ( SourceMove (..),
    SourceMoveError (..),
    planSourceMoves,
    rewriteHaskellModuleReferences,
    moduleNameFromPath,
  )
where

import Data.List (sortBy, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.Scaffold (ModuleKind, ModuleRole, ScaffoldModule, modulePath, moduleRole)

data SourceMove = SourceMove
  { moveRole :: !ModuleRole,
    moveKind :: !ModuleKind,
    moveOldModule :: !Text,
    moveNewModule :: !Text,
    moveOldPath :: !FilePath,
    moveNewPath :: !FilePath,
    moveBackupPath :: !FilePath
  }
  deriving stock (Eq, Show)

data SourceMoveError
  = AmbiguousLegacyModule !FilePath ![FilePath]
  | AmbiguousModuleRole !ModuleRole ![FilePath]
  | MalformedHaskellLexicalInput !Text
  deriving stock (Eq, Show)

-- | Pair prior paths with the current artifact plan.  New records provide a
-- stable role; historical records fall back to exact legacy-name
-- normalization.  Only actual path changes become moves.
planSourceMoves ::
  [(Maybe ModuleRole, ModuleKind, FilePath)] ->
  [ScaffoldModule] ->
  Either (NonEmpty SourceMoveError) [SourceMove]
planSourceMoves previous current =
  case errors of
    first : rest -> Left (first :| rest)
    [] -> Right (sortOn moveOldPath moves)
  where
    currentByRole = Map.fromListWith (<>) [(moduleRole scaffoldModule, [scaffoldModule]) | scaffoldModule <- current]
    currentByModule = Map.fromListWith (<>) [(moduleNameFromPath (modulePath scaffoldModule), [scaffoldModule]) | scaffoldModule <- current]
    planned = map pair previous
    errors = [err | Left err <- planned]
    moves = [move | Right (Just move) <- planned]

    pair (previousRole, previousKind, previousPath) = do
      candidate <- case previousRole of
        Just role -> uniqueRole role (Map.findWithDefault [] role currentByRole)
        Nothing ->
          let normalized = normalizeLegacyModuleName (moduleNameFromPath previousPath)
           in uniqueLegacy previousPath (Map.findWithDefault [] normalized currentByModule)
      case candidate of
        Nothing -> Right Nothing
        Just currentModule
          | modulePath currentModule == previousPath -> Right Nothing
          | otherwise ->
              Right . Just $
                SourceMove
                  { moveRole = moduleRole currentModule,
                    moveKind = previousKind,
                    moveOldModule = moduleNameFromPath previousPath,
                    moveNewModule = moduleNameFromPath (modulePath currentModule),
                    moveOldPath = previousPath,
                    moveNewPath = modulePath currentModule,
                    moveBackupPath = ".keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/" <> previousPath
                  }

    uniqueRole _ [] = Right Nothing
    uniqueRole _ [candidate] = Right (Just candidate)
    uniqueRole role candidates = Left (AmbiguousModuleRole role (map modulePath candidates))
    uniqueLegacy _ [] = Right Nothing
    uniqueLegacy _ [candidate] = Right (Just candidate)
    uniqueLegacy path candidates = Left (AmbiguousLegacyModule path (map modulePath candidates))

moduleNameFromPath :: FilePath -> Text
moduleNameFromPath = T.replace "/" "." . T.dropEnd 3 . T.pack

normalizeLegacyModuleName :: Text -> Text
normalizeLegacyModuleName = T.intercalate "." . map normalizeSegment . T.splitOn "."
  where
    normalizeSegment segment =
      case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
        Right derived -> HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
        Left _ -> segment
      where
        site =
          HaskellName.NameSite
            { HaskellName.siteKind = HaskellName.NodeModuleSite,
              HaskellName.siteLogicalName = segment,
              HaskellName.siteOwner = "legacy-module-segment",
              HaskellName.siteLine = 0
            }

data LexState
  = Code
  | LineComment
  | BlockComment !Int
  | StringLiteral
  | CharacterLiteral
  deriving stock (Eq, Show)

-- | Rewrite exact module token sequences in Haskell code while preserving
-- comments, strings, character literals, and nested block comments byte for
-- byte.  Longer old modules win when one is a prefix of another.
rewriteHaskellModuleReferences :: Map Text Text -> Text -> Either SourceMoveError Text
rewriteHaskellModuleReferences replacements source =
  fmap (T.pack . reverse) (go Code Nothing (T.unpack source) [])
  where
    ordered =
      sortBy
        (comparing (Down . length . fst))
        [(T.unpack old, T.unpack new) | (old, new) <- Map.toAscList replacements, old /= new]

    go state previous input output = case (state, input) of
      (Code, []) -> Right output
      (LineComment, []) -> Right output
      (BlockComment _, []) -> Left (MalformedHaskellLexicalInput "unterminated block comment")
      (StringLiteral, []) -> Left (MalformedHaskellLexicalInput "unterminated string literal")
      (CharacterLiteral, []) -> Left (MalformedHaskellLexicalInput "unterminated character literal")
      (Code, '-' : '-' : rest) -> go LineComment (Just '-') rest ('-' : '-' : output)
      (Code, '{' : '-' : rest) -> go (BlockComment 1) (Just '-') rest ('-' : '{' : output)
      (Code, '"' : rest) -> go StringLiteral (Just '"') rest ('"' : output)
      (Code, '\'' : rest)
        | looksLikeCharacterLiteral rest -> go CharacterLiteral (Just '\'') rest ('\'' : output)
      (Code, remaining@(character : rest)) -> case firstReplacement previous remaining ordered of
        Just (old, new) ->
          let untouched = drop (length old) remaining
              newOutput = reverse new <> output
              newPrevious = case reverse old of oldLast : _ -> Just oldLast; [] -> previous
           in go Code newPrevious untouched newOutput
        Nothing -> go Code (Just character) rest (character : output)
      (LineComment, '\n' : rest) -> go Code (Just '\n') rest ('\n' : output)
      (LineComment, character : rest) -> go LineComment (Just character) rest (character : output)
      (BlockComment depth, '{' : '-' : rest) -> go (BlockComment (depth + 1)) (Just '-') rest ('-' : '{' : output)
      (BlockComment 1, '-' : '}' : rest) -> go Code (Just '}') rest ('}' : '-' : output)
      (BlockComment depth, '-' : '}' : rest) -> go (BlockComment (depth - 1)) (Just '}') rest ('}' : '-' : output)
      (BlockComment depth, character : rest) -> go (BlockComment depth) (Just character) rest (character : output)
      (StringLiteral, '\\' : escaped : rest) -> go StringLiteral (Just escaped) rest (escaped : '\\' : output)
      (StringLiteral, '"' : rest) -> go Code (Just '"') rest ('"' : output)
      (StringLiteral, character : rest) -> go StringLiteral (Just character) rest (character : output)
      (CharacterLiteral, '\\' : escaped : rest) -> go CharacterLiteral (Just escaped) rest (escaped : '\\' : output)
      (CharacterLiteral, '\'' : rest) -> go Code (Just '\'') rest ('\'' : output)
      (CharacterLiteral, character : rest) -> go CharacterLiteral (Just character) rest (character : output)

    firstReplacement previous remaining = firstMatch
      where
        firstMatch [] = Nothing
        firstMatch ((old, new) : rest)
          | old `isPrefixOfString` remaining,
            maybe True (not . moduleTokenCharacter) previous,
            afterBoundary old remaining =
              Just (old, new)
          | otherwise = firstMatch rest

    afterBoundary old remaining = case drop (length old) remaining of
      [] -> True
      next : _ -> not (identifierCharacter next)

    moduleTokenCharacter character = identifierCharacter character || character == '.'
    identifierCharacter character =
      (character >= 'A' && character <= 'Z')
        || (character >= 'a' && character <= 'z')
        || (character >= '0' && character <= '9')
        || character == '_'
        || character == '\''

    looksLikeCharacterLiteral rest = case rest of
      '\\' : _escaped : '\'' : _ -> True
      _character : '\'' : _ -> True
      _ -> False

isPrefixOfString :: String -> String -> Bool
isPrefixOfString [] _ = True
isPrefixOfString _ [] = False
isPrefixOfString (left : leftRest) (right : rightRest) = left == right && isPrefixOfString leftRest rightRest
