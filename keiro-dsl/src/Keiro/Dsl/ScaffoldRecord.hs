-- | Versioned persistence for the files and mapped consumer identities used by
-- one successful scaffold run. Unknown header fields are ignored so v1 readers
-- can consume records extended by later tool versions. Mapping rows are canonical
-- single-line JSON after a @mapping @ prefix; old readers ignore that row kind.
module Keiro.Dsl.ScaffoldRecord
  ( ScaffoldRecord (..),
    renderRecord,
    parseRecord,
    recordFileName,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Keiro.Dsl.BehaviorCoverage (BehaviorRecordRow (..))
import Keiro.Dsl.ExplainBindings (BindingHole (..))
import Keiro.Dsl.LanguageVersion (SourceLanguage (..))
import Keiro.Dsl.MappedConsumer (MappingIdentity (..))
import Keiro.Dsl.Scaffold (ModuleKind (..))
import System.FilePath (isAbsolute, splitDirectories)

data ScaffoldRecord = ScaffoldRecord
  { recSpecPath :: !Text,
    recModuleRoot :: !Text,
    recLayout :: !Text,
    recSourceLanguage :: !SourceLanguage,
    recFiles :: ![(ModuleKind, FilePath)],
    recMappings :: ![MappingIdentity],
    recBindingObligations :: ![BindingHole],
    recBehaviorRequirements :: ![BehaviorRecordRow]
  }
  deriving stock (Eq, Show)

renderRecord :: ScaffoldRecord -> Text
renderRecord record =
  T.unlines $
    [ "keiro-dsl scaffold record v1",
      "spec: " <> recSpecPath record,
      "module-root: " <> rootLabel,
      "layout: " <> recLayout record,
      "source-language " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode (recSourceLanguage record)))
    ]
      <> map renderFile (recFiles record)
      <> map renderMapping (recMappings record)
      <> map renderBindingObligation (recBindingObligations record)
      <> map renderBehaviorRequirement (recBehaviorRequirements record)
  where
    rootLabel = if T.null (recModuleRoot record) then "(none)" else recModuleRoot record
    renderFile (Generated, path) = "generated " <> T.pack path
    renderFile (HoleStub, path) = "hole " <> T.pack path
    renderMapping mapping =
      mappingRowPrefix mapping <> Text.decodeUtf8 (BL.toStrict (Aeson.encode mapping))
    renderBindingObligation obligation =
      "binding " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode obligation))
    renderBehaviorRequirement requirement =
      "behavior " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode requirement))

-- | Parse a v1 record. The version header and the three required fields must
-- be present exactly once. Unknown lines are ignored for forward compatibility;
-- unsafe file paths are rejected rather than joined to a scaffold output root.
parseRecord :: Text -> Maybe ScaffoldRecord
parseRecord contents = case T.lines contents of
  header : rows
    | header == "keiro-dsl scaffold record v1" -> do
        specPath <- exactlyOne "spec: " rows
        rootLabel <- exactlyOne "module-root: " rows
        layout <- exactlyOne "layout: " rows
        sourceLanguage <- parseSourceLanguage rows
        files <- traverse parseFile (filter isFileRow rows)
        ordinaryMappings <- traverse (parseMapping "mapping ") (filter ("mapping " `T.isPrefixOf`) rows)
        nominalMappings <- traverse (parseMapping "nominal-mapping ") (filter ("nominal-mapping " `T.isPrefixOf`) rows)
        let mappings = ordinaryMappings <> nominalMappings
        bindingEntries <- traverse parseBindingObligation (filter ("binding " `T.isPrefixOf`) rows)
        behaviorEntries <- traverse parseBehaviorRequirement (filter ("behavior " `T.isPrefixOf`) rows)
        if hasDuplicateMappingNames mappings || hasDuplicateBindingObligations bindingEntries || hasDuplicateBehaviorRequirements behaviorEntries
          then Nothing
          else
            pure
              ScaffoldRecord
                { recSpecPath = specPath,
                  recModuleRoot = if rootLabel == "(none)" then "" else rootLabel,
                  recLayout = layout,
                  recSourceLanguage = sourceLanguage,
                  recFiles = files,
                  recMappings = mappings,
                  recBindingObligations = bindingEntries,
                  recBehaviorRequirements = behaviorEntries
                }
  _ -> Nothing
  where
    exactlyOne prefix rows = case [value | row <- rows, Just value <- [T.stripPrefix prefix row]] of
      [value] -> Just value
      _ -> Nothing
    isFileRow row = "generated " `T.isPrefixOf` row || "hole " `T.isPrefixOf` row
    parseFile row
      | Just path <- T.stripPrefix "generated " row = checkedFile Generated path
      | Just path <- T.stripPrefix "hole " row = checkedFile HoleStub path
      | otherwise = Nothing
    checkedFile fileKind pathText =
      let path = T.unpack pathText
       in if null path || isAbsolute path || ".." `elem` splitDirectories path
            then Nothing
            else Just (fileKind, path)
    parseMapping prefix row = do
      payload <- T.stripPrefix prefix row
      Aeson.decodeStrict' (Text.encodeUtf8 payload)
    parseBindingObligation row = do
      payload <- T.stripPrefix "binding " row
      Aeson.decodeStrict' (Text.encodeUtf8 payload)
    parseBehaviorRequirement row = do
      payload <- T.stripPrefix "behavior " row
      Aeson.decodeStrict' (Text.encodeUtf8 payload)
    parseSourceLanguage rows = case filter ("source-language " `T.isPrefixOf`) rows of
      [] -> Just LegacyUnversioned
      [row] -> do
        payload <- T.stripPrefix "source-language " row
        Aeson.decodeStrict' (Text.encodeUtf8 payload)
      _ -> Nothing
    hasDuplicateMappingNames mappings =
      let names = map mappingSpecName mappings
       in length names /= length (nub names)
    hasDuplicateBindingObligations obligations =
      let keys = map bindingKey obligations
       in length keys /= length (nub keys)
    bindingKey hole =
      ( holeMappedName hole,
        holeModule hole,
        holeSymbol hole,
        holeKind hole,
        holePath hole
      )
    hasDuplicateBehaviorRequirements requirements =
      let keys = map behaviorRecordKey requirements
       in length keys /= length (nub keys)

recordFileName :: Text -> FilePath
recordFileName context = "keiro-dsl-scaffold-record." <> T.unpack context <> ".txt"

mappingRowPrefix :: MappingIdentity -> Text
mappingRowPrefix NominalMapping {} = "nominal-mapping "
mappingRowPrefix _ = "mapping "
