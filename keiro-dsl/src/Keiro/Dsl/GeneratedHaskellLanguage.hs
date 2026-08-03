-- | The Haskell language contract for overwriteable generated modules.
--
-- The manifest and conformance build profile publish the shared baseline.
-- Syntax outside that baseline must be requested through the closed extension
-- type and rendered as a module-local pragma.
module Keiro.Dsl.GeneratedHaskellLanguage
  ( GeneratedHaskellExtension (..),
    generatedHaskellDefaultLanguage,
    generatedHaskellDefaultExtensions,
    renderGeneratedLanguagePragmas,
  )
where

import Data.List (nub, sort)
import Data.Text (Text)

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
generatedHaskellDefaultExtensions = ["OverloadedStrings"]

renderGeneratedLanguagePragmas :: [GeneratedHaskellExtension] -> [Text]
renderGeneratedLanguagePragmas = map renderPragma . sort . nub . map extensionName
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
