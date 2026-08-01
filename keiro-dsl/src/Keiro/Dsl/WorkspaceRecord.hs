-- | Versioned persistence for one successful __whole-workspace__ scaffold run.
--
-- A workspace record answers three questions a context-keyed
-- "Keiro.Dsl.ScaffoldRecord" cannot: which service produced this output tree,
-- which member files it was composed from, and __which member produced each
-- emitted module__. The last one is what makes moving an aggregate from one member
-- file to another an ownership move rather than a stale/new pair.
--
-- __Coexistence.__ Workspace history is keyed by the service name in a distinct
-- file-name slot, @keiro-dsl-scaffold-record.workspace.\<service\>.txt@, and never
-- by context. A context name is lexed as letters, digits, @_@ and @-@ and can
-- never contain a dot, so this slot provably cannot collide with a legacy
-- context-keyed name even when a service is named after its context. Legacy
-- records and a workspace record may therefore share one output directory: the
-- workspace path never writes a context-keyed name, and an older keiro-dsl binary
-- is structurally incapable of parsing — and therefore of clobbering — workspace
-- history. The one exception is the explicit adoption step, which /appends/ a
-- @superseded-by:@ line to a legacy record; the v1 parser ignores unknown lines,
-- so old binaries still read it.
--
-- The format is line-oriented like the v1 record, with a distinct header so no
-- reader can confuse the schemas:
--
-- @
-- keiro-dsl workspace scaffold record v1
-- service: demo-project
-- manifest: service.keiro-workspace
-- context: demo-project
-- module-root: Demo.Modules.Project
-- layout: collocated
-- member domain/project.keiro
-- module {"kind":"generated","path":"Demo/Project/Generated/StructuralProjections.hs"}
-- module {"kind":"generated","path":"Demo/Project/Project/Generated/Domain.hs","owner":"domain/project.keiro"}
-- mapping {…}
-- binding {…}
-- adopted {"path":"…","evidence":"record","source":"keiro-dsl-scaffold-record.demo-project.txt"}
-- @
--
-- @module@ rows are canonical single-line JSON, following the precedent set for
-- @mapping@ rows. An /absent/ @owner@ means the module is context-level: emitted
-- once for the whole merged graph (the structural projection facade, the
-- replay-audit assembly, or a binding skeleton shared by declarations from several
-- members). Unknown row kinds and unknown JSON keys are ignored so a later tool
-- version can extend the schema; paths that are absolute or contain @..@ are
-- rejected rather than joined to an output root.
module Keiro.Dsl.WorkspaceRecord
  ( WorkspaceRecord (..),
    WorkspaceModuleRow (..),
    WorkspaceSourceLanguageRow (..),
    AdoptedRow (..),
    renderWorkspaceRecord,
    parseWorkspaceRecord,
    workspaceRecordFileName,
    workspaceManifestFileName,
    workspaceMigrationReportFileName,
    supersededByLine,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Keiro.Dsl.BehaviorCoverage (BehaviorRecordRow (..))
import Keiro.Dsl.ExplainBindings (BindingHole (..))
import Keiro.Dsl.LanguageVersion (SourceLanguage (..), declaredLanguageVersionMaybe, effectiveLanguageVersion, sourceFormText)
import Keiro.Dsl.MappedConsumer (MappingIdentity (..))
import Keiro.Dsl.Scaffold (ModuleKind (..))
import System.FilePath (isAbsolute, splitDirectories)

-- | One emitted module: what kind it is, where it landed relative to the output
-- directory, and which member file produced it ('Nothing' for context-level
-- modules emitted once from the merged graph).
data WorkspaceModuleRow = WorkspaceModuleRow
  { wrmKind :: !ModuleKind,
    wrmPath :: !FilePath,
    wrmOwner :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show)

instance ToJSON WorkspaceModuleRow where
  toJSON row =
    object $
      [ "kind" .= (case wrmKind row of Generated -> "generated" :: Text; HoleStub -> "hole"),
        "path" .= T.pack (wrmPath row)
      ]
        <> ["owner" .= T.pack owner | Just owner <- [wrmOwner row]]

instance FromJSON WorkspaceModuleRow where
  parseJSON = withObject "WorkspaceModuleRow" $ \fields -> do
    kindLabel <- fields .: "kind"
    moduleKind <- case (kindLabel :: Text) of
      "generated" -> pure Generated
      "hole" -> pure HoleStub
      other -> fail ("unknown module kind: " <> T.unpack other)
    path <- fields .: "path"
    owner <- fields .:? "owner"
    pure
      WorkspaceModuleRow
        { wrmKind = moduleKind,
          wrmPath = T.unpack (path :: Text),
          wrmOwner = T.unpack <$> (owner :: Maybe Text)
        }

-- | One member's source-language provenance in a workspace record.
data WorkspaceSourceLanguageRow = WorkspaceSourceLanguageRow
  { wrslPath :: !FilePath,
    wrslSourceLanguage :: !SourceLanguage
  }
  deriving stock (Eq, Show)

instance ToJSON WorkspaceSourceLanguageRow where
  toJSON row =
    object
      [ "path" .= T.pack (wrslPath row),
        "sourceForm" .= sourceFormText sourceLanguage,
        "declaredLanguageVersion" .= declaredLanguageVersionMaybe sourceLanguage,
        "effectiveLanguageVersion" .= effectiveLanguageVersion sourceLanguage
      ]
    where
      sourceLanguage = wrslSourceLanguage row

instance FromJSON WorkspaceSourceLanguageRow where
  parseJSON value@(Aeson.Object fields) = do
    path <- fields .: "path"
    sourceLanguage <- parseJSON value
    pure
      WorkspaceSourceLanguageRow
        { wrslPath = T.unpack (path :: Text),
          wrslSourceLanguage = sourceLanguage
        }
  parseJSON _ = fail "WorkspaceSourceLanguageRow must be an object"

-- | One file imported into workspace history from pre-workspace scaffold
-- output. @adEvidence@ is @record@ when a legacy per-context scaffold record
-- listed the file, or @banner@ when the file sits at a planned Generated path and
-- carries the @-- \@generated@ banner but no surviving record lists it (the orphan
-- case created when one legacy record overwrote another).
data AdoptedRow = AdoptedRow
  { adPath :: !FilePath,
    adEvidence :: !Text,
    -- | The legacy record's file name, when the evidence is @record@.
    adSource :: !(Maybe Text),
    -- | The legacy record's @spec:@ field, when available.
    adSpec :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON AdoptedRow where
  toJSON row =
    object $
      ["path" .= T.pack (adPath row), "evidence" .= adEvidence row]
        <> ["source" .= source | Just source <- [adSource row]]
        <> ["spec" .= specPath | Just specPath <- [adSpec row]]

instance FromJSON AdoptedRow where
  parseJSON = withObject "AdoptedRow" $ \fields -> do
    path <- fields .: "path"
    evidence <- fields .: "evidence"
    source <- fields .:? "source"
    specPath <- fields .:? "spec"
    pure
      AdoptedRow
        { adPath = T.unpack (path :: Text),
          adEvidence = evidence,
          adSource = source,
          adSpec = specPath
        }

-- | Everything one successful whole-workspace scaffold produced.
data WorkspaceRecord = WorkspaceRecord
  { -- | The manifest's @service@ name: the workspace's durable identity.
    wrService :: !Text,
    -- | The manifest's __file name__, not a path. Members are relative to its
    --     directory, so the directory is wherever the manifest currently sits;
    --     recording only the name keeps the record independent of the invoking
    --     working directory, which is what makes byte-identical output provable.
    wrManifest :: !Text,
    wrContext :: !Text,
    wrModuleRoot :: !Text,
    wrLayout :: !Text,
    -- | Canonically ordered manifest-relative member paths.
    wrMembers :: ![FilePath],
    wrSourceLanguages :: ![WorkspaceSourceLanguageRow],
    wrModules :: ![WorkspaceModuleRow],
    wrMappings :: ![MappingIdentity],
    wrBindingObligations :: ![BindingHole],
    wrBehaviorRequirements :: ![BehaviorRecordRow],
    wrAdopted :: ![AdoptedRow]
  }
  deriving stock (Eq, Show)

workspaceRecordHeader :: Text
workspaceRecordHeader = "keiro-dsl workspace scaffold record v1"

renderWorkspaceRecord :: WorkspaceRecord -> Text
renderWorkspaceRecord record =
  T.unlines $
    [ workspaceRecordHeader,
      "service: " <> wrService record,
      "manifest: " <> wrManifest record,
      "context: " <> wrContext record,
      "module-root: " <> rootLabel,
      "layout: " <> wrLayout record
    ]
      <> ["member " <> T.pack path | path <- wrMembers record]
      <> ["source-language " <> encodeRow row | row <- wrSourceLanguages record]
      <> ["module " <> encodeRow row | row <- wrModules record]
      <> [mappingRowPrefix mapping <> encodeRow mapping | mapping <- wrMappings record]
      <> ["binding " <> encodeRow obligation | obligation <- wrBindingObligations record]
      <> ["behavior " <> encodeRow requirement | requirement <- wrBehaviorRequirements record]
      <> ["adopted " <> encodeRow adopted | adopted <- wrAdopted record]
  where
    rootLabel = if T.null (wrModuleRoot record) then "(none)" else wrModuleRoot record

encodeRow :: (ToJSON a) => a -> Text
encodeRow = Text.decodeUtf8 . BL.toStrict . Aeson.encode

-- | Parse a workspace record. The header and the five @key: value@ fields must
-- each appear exactly once; unknown lines are ignored for forward compatibility;
-- unsafe paths are rejected rather than joined to an output root.
parseWorkspaceRecord :: Text -> Maybe WorkspaceRecord
parseWorkspaceRecord contents = case T.lines contents of
  header : rows
    | header == workspaceRecordHeader -> do
        service <- exactlyOne "service: " rows
        manifest <- exactlyOne "manifest: " rows
        context <- exactlyOne "context: " rows
        rootLabel <- exactlyOne "module-root: " rows
        layout <- exactlyOne "layout: " rows
        members <- traverse safePath [path | row <- rows, Just path <- [T.stripPrefix "member " row]]
        sourceLanguages <- parseSourceLanguages members rows
        modules <- traverse (decodeRow "module ") (rowsWith "module " rows)
        checkedModules <- traverse checkedModule modules
        ordinaryMappings <- traverse (decodeRow "mapping ") (rowsWith "mapping " rows)
        nominalMappings <- traverse (decodeRow "nominal-mapping ") (rowsWith "nominal-mapping " rows)
        let mappings = ordinaryMappings <> nominalMappings
        obligations <- traverse (decodeRow "binding ") (rowsWith "binding " rows)
        behaviorRequirements <- traverse (decodeRow "behavior ") (rowsWith "behavior " rows)
        adopted <- traverse (decodeRow "adopted ") (rowsWith "adopted " rows)
        checkedAdopted <- traverse checkedAdoption adopted
        if hasDuplicates members
          || hasDuplicates (map wrmPath checkedModules)
          || hasDuplicates (map mappingSpecName mappings)
          || hasDuplicates (map bindingKey obligations)
          || hasDuplicates (map behaviorRecordKey behaviorRequirements)
          then Nothing
          else
            pure
              WorkspaceRecord
                { wrService = service,
                  wrManifest = manifest,
                  wrContext = context,
                  wrModuleRoot = if rootLabel == "(none)" then "" else rootLabel,
                  wrLayout = layout,
                  wrMembers = members,
                  wrSourceLanguages = sourceLanguages,
                  wrModules = checkedModules,
                  wrMappings = mappings,
                  wrBindingObligations = obligations,
                  wrBehaviorRequirements = behaviorRequirements,
                  wrAdopted = checkedAdopted
                }
  _ -> Nothing
  where
    exactlyOne prefix rows = case [value | row <- rows, Just value <- [T.stripPrefix prefix row]] of
      [value] -> Just value
      _ -> Nothing
    rowsWith prefix rows = [row | row <- rows, prefix `T.isPrefixOf` row]
    decodeRow prefix row = do
      payload <- T.stripPrefix prefix row
      Aeson.decodeStrict' (Text.encodeUtf8 payload)
    checkedModule row = do
      path <- safePath (T.pack (wrmPath row))
      owner <- traverse (safePath . T.pack) (wrmOwner row)
      pure row {wrmPath = path, wrmOwner = owner}
    checkedAdoption row = do
      path <- safePath (T.pack (adPath row))
      pure row {adPath = path}
    parseSourceLanguages members rows = case rowsWith "source-language " rows of
      [] -> Just [WorkspaceSourceLanguageRow path LegacyUnversioned | path <- members]
      sourceRows -> do
        decoded <- traverse (decodeRow "source-language ") sourceRows
        checked <- traverse checkedSourceLanguage decoded
        if hasDuplicates (map wrslPath checked) || sort (map wrslPath checked) /= sort members
          then Nothing
          else Just checked
    checkedSourceLanguage row = do
      path <- safePath (T.pack (wrslPath row))
      pure row {wrslPath = path}
    safePath raw =
      let path = T.unpack raw
       in if null path || isAbsolute path || ".." `elem` splitDirectories path
            then Nothing
            else Just path
    hasDuplicates :: (Eq a) => [a] -> Bool
    hasDuplicates values = length values /= length (nub values)
    bindingKey hole =
      ( holeMappedName hole,
        holeModule hole,
        holeSymbol hole,
        holeKind hole,
        holePath hole
      )

-- | @keiro-dsl-scaffold-record.workspace.\<service\>.txt@ — the workspace
-- history file. See the module header for why the @workspace.@ slot cannot
-- collide with a context-keyed name.
workspaceRecordFileName :: Text -> FilePath
workspaceRecordFileName service = "keiro-dsl-scaffold-record.workspace." <> T.unpack service <> ".txt"

-- | @keiro-dsl-manifest.workspace.\<service\>.txt@ — the Cabal build manifest.
workspaceManifestFileName :: Text -> FilePath
workspaceManifestFileName service = "keiro-dsl-manifest.workspace." <> T.unpack service <> ".txt"

-- | @keiro-dsl-migration-report.workspace.\<service\>.txt@ — the durable review
-- artifact written once, on the run that adopts pre-workspace scaffold output.
workspaceMigrationReportFileName :: Text -> FilePath
workspaceMigrationReportFileName service = "keiro-dsl-migration-report.workspace." <> T.unpack service <> ".txt"

-- | The single line adoption appends to a superseded legacy record. The v1
-- parser ignores unknown lines, so the legacy record keeps parsing for old
-- binaries and stays readable for humans; nothing is renamed or deleted.
supersededByLine :: Text -> Text
supersededByLine service = "superseded-by: " <> T.pack (workspaceRecordFileName service)

mappingRowPrefix :: MappingIdentity -> Text
mappingRowPrefix NominalMapping {} = "nominal-mapping "
mappingRowPrefix _ = "mapping "
