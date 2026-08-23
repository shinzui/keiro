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
modernizeGeneratedHaskellSource = T.pack . go Code . T.unpack
  where
    go _ [] = []
    go Code ('-' : '-' : rest) = '-' : '-' : go LineComment rest
    go Code ('{' : '-' : rest) = '{' : '-' : go (BlockComment 1) rest
    go Code ('"' : rest) = '"' : go StringLiteral rest
    go Code ('\'' : rest) = '\'' : go CharacterLiteral rest
    go Code input@(character : rest)
      | identifierStart character =
          let (token, remaining) = span identifierCharacter input
              replacement = Map.findWithDefault (T.pack token) (T.pack token) idiomaticV2Labels
           in T.unpack replacement <> go Code remaining
      | otherwise = character : go Code rest
    go LineComment ('\n' : rest) = '\n' : go Code rest
    go LineComment (character : rest) = character : go LineComment rest
    go (BlockComment depth) ('{' : '-' : rest) = '{' : '-' : go (BlockComment (depth + 1)) rest
    go (BlockComment 1) ('-' : '}' : rest) = '-' : '}' : go Code rest
    go (BlockComment depth) ('-' : '}' : rest) = '-' : '}' : go (BlockComment (depth - 1)) rest
    go (BlockComment depth) (character : rest) = character : go (BlockComment depth) rest
    go StringLiteral ('\\' : escaped : rest) = '\\' : escaped : go StringLiteral rest
    go StringLiteral ('"' : rest) = '"' : go Code rest
    go StringLiteral (character : rest) = character : go StringLiteral rest
    go CharacterLiteral ('\\' : escaped : rest) = '\\' : escaped : go CharacterLiteral rest
    go CharacterLiteral ('\'' : rest) = '\'' : go Code rest
    go CharacterLiteral (character : rest) = character : go CharacterLiteral rest

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
