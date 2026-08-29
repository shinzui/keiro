-- | The Haskell language contract for overwriteable generated modules.
--
-- The manifest and conformance build profile publish the shared baseline.
-- Syntax outside that baseline must be requested through the closed extension
-- type and rendered as a module-local pragma.
module Keiro.Dsl.GeneratedHaskellLanguage
  ( GeneratedHaskellExtension (..),
    generatedHaskellDefaultLanguage,
    generatedHaskellDefaultExtensions,
    idiomaticV2LabelMigrations,
    modernizeGeneratedHaskellSource,
    modernizeGeneratedHaskellSourceWithState,
    RewriteState (..),
    renderGeneratedLanguagePragmas,
  )
where

import Data.Char (isAlphaNum)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

data GeneratedHaskellExtension
  = ExtBlockArguments
  | ExtDeriveAnyClass
  | ExtDuplicateRecordFields
  | ExtOverloadedLabels
  | ExtOverloadedRecordDot
  | ExtQualifiedDo
  | ExtTemplateHaskell
  | ExtTypeFamilies
  deriving (Eq, Ord, Show)

generatedHaskellDefaultLanguage :: Text
generatedHaskellDefaultLanguage = "GHC2024"

generatedHaskellDefaultExtensions :: [Text]
generatedHaskellDefaultExtensions =
  [ "DuplicateRecordFields",
    "NoFieldSelectors",
    "OverloadedRecordDot",
    "OverloadedStrings"
  ]

renderGeneratedLanguagePragmas :: [GeneratedHaskellExtension] -> [Text]
renderGeneratedLanguagePragmas =
  map renderPragma
    . filter (`notElem` generatedHaskellDefaultExtensions)
    . sort
    . nub
    . map extensionName
  where
    renderPragma name = "{-# LANGUAGE " <> name <> " #-}"

extensionName :: GeneratedHaskellExtension -> Text
extensionName extension = case extension of
  ExtBlockArguments -> "BlockArguments"
  ExtDeriveAnyClass -> "DeriveAnyClass"
  ExtDuplicateRecordFields -> "DuplicateRecordFields"
  ExtOverloadedLabels -> "OverloadedLabels"
  ExtOverloadedRecordDot -> "OverloadedRecordDot"
  ExtQualifiedDo -> "QualifiedDo"
  ExtTemplateHaskell -> "TemplateHaskell"
  ExtTypeFamilies -> "TypeFamilies"

-- | Apply the idiomatic-v2 product-label mapping to Haskell identifiers while
-- preserving comments and literals byte for byte. The emitter templates still
-- use the released idiomatic-v1 labels as their semantic vocabulary; keeping
-- the presentation rewrite here makes the edition boundary complete and keeps
-- wire strings, diagnostics, and generated comments outside that boundary.
modernizeGeneratedHaskellSource :: Text -> Text
modernizeGeneratedHaskellSource = fst . modernizeGeneratedHaskellSourceWithState

modernizeGeneratedHaskellSourceWithState :: Text -> (Text, RewriteState)
modernizeGeneratedHaskellSourceWithState source =
  let (output, finalState) = go Code (T.unpack source)
   in (T.pack output, finalState)
  where
    go Code [] = ([], Code)
    go LineComment [] = ([], Code)
    go state [] = ([], state)
    go Code input@('-' : '-' : _) =
      let (dashes, remaining) = span (== '-') input
          startsComment = case remaining of
            [] -> True
            character : _ -> not (isHaskellSymbol character)
       in emit dashes (go (if startsComment then LineComment else Code) remaining)
    go Code ('{' : '-' : rest) = emit "{-" (go (BlockComment 1) rest)
    go Code ('"' : rest) = emit "\"" (go StringLiteral rest)
    go Code ('\'' : rest)
      | startsCharacterLiteral rest = emit "'" (go CharacterLiteral rest)
      | otherwise = emit "'" (go Code rest)
    go Code sourceText@(character : rest)
      | identifierStart character =
          let (token, remaining) = span identifierCharacter sourceText
              replacement = Map.findWithDefault (T.pack token) (T.pack token) idiomaticV2Labels
           in emit (T.unpack replacement) (go Code remaining)
      | otherwise = emit [character] (go Code rest)
    go LineComment ('\n' : rest) = emit "\n" (go Code rest)
    go LineComment (character : rest) = emit [character] (go LineComment rest)
    go (BlockComment depth) ('{' : '-' : rest) = emit "{-" (go (BlockComment (depth + 1)) rest)
    go (BlockComment 1) ('-' : '}' : rest) = emit "-}" (go Code rest)
    go (BlockComment depth) ('-' : '}' : rest) = emit "-}" (go (BlockComment (depth - 1)) rest)
    go (BlockComment depth) (character : rest) = emit [character] (go (BlockComment depth) rest)
    go StringLiteral ('\\' : escaped : rest) = emit ['\\', escaped] (go StringLiteral rest)
    go StringLiteral ('"' : rest) = emit "\"" (go Code rest)
    go StringLiteral (character : rest) = emit [character] (go StringLiteral rest)
    go CharacterLiteral ('\\' : escaped : rest) = emit ['\\', escaped] (go CharacterLiteral rest)
    go CharacterLiteral ('\'' : rest) = emit "'" (go Code rest)
    go CharacterLiteral (character : rest) = emit [character] (go CharacterLiteral rest)

    emit prefix (output, state) = (prefix <> output, state)
    startsCharacterLiteral ('\\' : _) = True
    startsCharacterLiteral (_ : '\'' : _) = True
    startsCharacterLiteral _ = False
    isHaskellSymbol character = character `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)
    identifierStart character = character == '_' || character >= 'A' && character <= 'Z' || character >= 'a' && character <= 'z'
    identifierCharacter character = identifierStart character || isAlphaNum character || character == '\''

data RewriteState
  = Code
  | LineComment
  | BlockComment !Int
  | StringLiteral
  | CharacterLiteral
  deriving stock (Eq, Show)

idiomaticV2Labels :: Map.Map Text Text
idiomaticV2Labels = Map.fromList idiomaticV2LabelMigrations

idiomaticV2LabelMigrations :: [(Text, Text)]
idiomaticV2LabelMigrations =
  [ ("failureCode", "code"),
    ("failureDetail", "detail"),
    ("failureKey", "key"),
    ("failureSubject", "subject"),
    ("inboxFailureAttempt", "attempt"),
    ("inboxFailureReason", "reason"),
    ("reportDuplicate", "duplicate"),
    ("reportFailed", "failed"),
    ("reportFilled", "filled"),
    ("reportMissing", "missing"),
    ("reportPending", "pending"),
    ("reportRequired", "required"),
    ("reportStale", "stale"),
    ("reportUnverified", "unverified"),
    ("reportVerified", "verified"),
    ("requirementCommandName", "commandName"),
    ("requirementEventKinds", "eventKinds"),
    ("requirementEvidence", "evidence"),
    ("requirementExpectedEdge", "expectedEdge"),
    ("requirementGuardCoverage", "guardCoverage"),
    ("requirementKey", "key"),
    ("requirementKind", "kind"),
    ("requirementLine", "line"),
    ("requirementSource", "source"),
    ("requirementTarget", "target"),
    ("sourceColumn", "column"),
    ("sourceFile", "file"),
    ("sourceLine", "line"),
    ("witnessCommand", "command"),
    ("witnessExpected", "expected"),
    ("witnessHistory", "history"),
    ("witnessHistoryPrefix", "historyPrefix"),
    ("witnessKey", "key"),
    ("witnessObservedChunk", "observedChunk"),
    ("workflowFactAwaitLabels", "awaitLabels"),
    ("workflowFactBody", "body"),
    ("workflowFactIdField", "idField"),
    ("workflowFactIdVia", "idVia"),
    ("workflowFactName", "name"),
    ("workflowFactPatchIds", "patchIds")
  ]
