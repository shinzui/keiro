-- | Versioned persistence for one successful __whole-workspace__ scaffold run.
--
-- A workspace record answers three questions a context-keyed
-- "Keiro.Dsl.ScaffoldRecord" cannot: which service produced this output tree,
-- which member files it was composed from, and __which member produced each
-- emitted module__. The last one is what makes moving an aggregate from one member
-- file to another an ownership move rather than a stale/new pair.
--
-- __Coexistence.__ Workspace history is keyed by the service name in the explicit
-- @keiro-dsl-ledger.workspace.\<service\>.txt@ slot, while standalone history uses
-- @keiro-dsl-ledger.context.\<context\>.txt@. The distinct literal slot segments
-- make collision impossible by construction, including for a context literally
-- named @workspace@. Legacy records can coexist during adoption because their
-- @keiro-dsl-scaffold-record.*@ stem is distinct. The one exception to ordinary
-- workspace isolation is the explicit adoption step, which /appends/ a
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
-- adopted {"path":"…","evidence":"record","source":"keiro-dsl-ledger.context.demo-project.txt"}
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
import Keiro.Dsl.CoordinationImpact (RouterSelectionSnapshot (..))
import Keiro.Dsl.ExplainBindings (BindingHole (..))
import Keiro.Dsl.HaskellName (GeneratedHaskellNamingEdition (..), parseGeneratedHaskellNamingEdition, renderGeneratedHaskellNamingEdition)
import Keiro.Dsl.LanguageVersion (SourceLanguage (..), declaredLanguageVersionMaybe, effectiveLanguageVersion, sourceFormText)
import Keiro.Dsl.MappedConsumer (MappingIdentity (..))
import Keiro.Dsl.ReadModelQueryContract (QueryContractIdentity, queryContractIdentityKey)
import Keiro.Dsl.Scaffold (ModuleKind (..), ModuleRole (..))
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract, effectiveLanguageContract)
import Keiro.Dsl.SemanticImpact (SemanticImpactSnapshot)
import Keiro.Dsl.SidecarNames qualified as SidecarNames
import System.FilePath (isAbsolute, splitDirectories)

-- | One emitted module: what kind it is, where it landed relative to the output
-- directory, and which member file produced it ('Nothing' for context-level
-- modules emitted once from the merged graph).
data WorkspaceModuleRow = WorkspaceModuleRow
  { kind :: !ModuleKind,
    path :: !FilePath,
    owner :: !(Maybe FilePath),
    role :: !(Maybe ModuleRole)
  }
  deriving stock (Eq, Show)

instance ToJSON WorkspaceModuleRow where
  toJSON row =
    object $
      [ "kind" .= (case (.kind) row of Generated -> "generated" :: Text; HoleStub -> "hole"),
        "path" .= T.pack ((.path) row)
      ]
        <> ["owner" .= T.pack owner | Just owner <- [(.owner) row]]
        <> ["roleOwnerKind" .= (.ownerKind) role | Just role <- [(.role) row]]
        <> ["roleOwnerName" .= (.ownerName) role | Just role <- [(.role) row]]
        <> ["roleFamily" .= (.family) role | Just role <- [(.role) row]]

instance FromJSON WorkspaceModuleRow where
  parseJSON = withObject "WorkspaceModuleRow" $ \fields -> do
    kindLabel <- fields .: "kind"
    moduleKind <- case (kindLabel :: Text) of
      "generated" -> pure Generated
      "hole" -> pure HoleStub
      other -> fail ("unknown module kind: " <> T.unpack other)
    path <- fields .: "path"
    owner <- fields .:? "owner"
    roleOwnerKindValue <- fields .:? "roleOwnerKind"
    roleOwnerNameValue <- fields .:? "roleOwnerName"
    roleFamilyValue <- fields .:? "roleFamily"
    moduleRoleValue <- case (roleOwnerKindValue, roleOwnerNameValue, roleFamilyValue) of
      (Nothing, Nothing, Nothing) -> pure Nothing
      (Just ownerKind, Just ownerName, Just family) -> pure (Just (ModuleRole ownerKind ownerName family))
      _ -> fail "module role fields must be all present or all absent"
    pure
      WorkspaceModuleRow
        { kind = moduleKind,
          path = T.unpack (path :: Text),
          owner = T.unpack <$> (owner :: Maybe Text),
          role = moduleRoleValue
        }

-- | One member's source-language provenance in a workspace record.
data WorkspaceSourceLanguageRow = WorkspaceSourceLanguageRow
  { path :: !FilePath,
    sourceLanguage :: !SourceLanguage
  }
  deriving stock (Eq, Show)

instance ToJSON WorkspaceSourceLanguageRow where
  toJSON row =
    object
      [ "path" .= T.pack ((.path) row),
        "sourceForm" .= sourceFormText sourceLanguage,
        "declaredLanguageVersion" .= declaredLanguageVersionMaybe sourceLanguage,
        "effectiveLanguageVersion" .= effectiveLanguageVersion sourceLanguage
      ]
    where
      sourceLanguage = (.sourceLanguage) row

instance FromJSON WorkspaceSourceLanguageRow where
  parseJSON value@(Aeson.Object fields) = do
    path <- fields .: "path"
    sourceLanguage <- parseJSON value
    pure
      WorkspaceSourceLanguageRow
        { path = T.unpack (path :: Text),
          sourceLanguage = sourceLanguage
        }
  parseJSON _ = fail "WorkspaceSourceLanguageRow must be an object"

-- | One file imported into workspace history from pre-workspace scaffold
-- output. @adEvidence@ is @record@ when a legacy per-context scaffold record
-- listed the file, or @banner@ when the file sits at a planned Generated path and
-- carries the @-- \@generated@ banner but no surviving record lists it (the orphan
-- case created when one legacy record overwrote another).
data AdoptedRow = AdoptedRow
  { path :: !FilePath,
    evidence :: !Text,
    -- | The legacy record's file name, when the evidence is @record@.
    source :: !(Maybe Text),
    -- | The legacy record's @spec:@ field, when available.
    spec :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON AdoptedRow where
  toJSON row =
    object $
      ["path" .= T.pack ((.path) row), "evidence" .= (.evidence) row]
        <> ["source" .= source | Just source <- [(.source) row]]
        <> ["spec" .= specPath | Just specPath <- [(.spec) row]]

instance FromJSON AdoptedRow where
  parseJSON = withObject "AdoptedRow" $ \fields -> do
    path <- fields .: "path"
    evidence <- fields .: "evidence"
    source <- fields .:? "source"
    specPath <- fields .:? "spec"
    pure
      AdoptedRow
        { path = T.unpack (path :: Text),
          evidence = evidence,
          source = source,
          spec = specPath
        }

-- | Everything one successful whole-workspace scaffold produced.
data WorkspaceRecord = WorkspaceRecord
  { -- | The manifest's @service@ name: the workspace's durable identity.
    service :: !Text,
    -- | The manifest's __file name__, not a path. Members are relative to its
    --     directory, so the directory is wherever the manifest currently sits;
    --     recording only the name keeps the record independent of the invoking
    --     working directory, which is what makes byte-identical output provable.
    manifest :: !Text,
    context :: !Text,
    moduleRoot :: !Text,
    layout :: !Text,
    -- | Canonically ordered manifest-relative member paths.
    members :: ![FilePath],
    sourceLanguages :: ![WorkspaceSourceLanguageRow],
    languageContract :: !EffectiveLanguageContract,
    namingEdition :: !GeneratedHaskellNamingEdition,
    modules :: ![WorkspaceModuleRow],
    mappings :: ![MappingIdentity],
    idDomains :: ![Text],
    nominalEqualities :: ![Text],
    bindingObligations :: ![BindingHole],
    requirements :: ![BehaviorRecordRow],
    projectionCatalogFacts :: ![Text],
    queryContractBaseline :: !Bool,
    queryContracts :: ![QueryContractIdentity],
    routerSelections :: ![RouterSelectionSnapshot],
    adopted :: ![AdoptedRow],
    semanticImpact :: !(Maybe SemanticImpactSnapshot)
  }
  deriving stock (Eq, Show)

workspaceRecordHeader :: Text
workspaceRecordHeader = "keiro-dsl workspace scaffold record v1"

renderWorkspaceRecord :: WorkspaceRecord -> Text
renderWorkspaceRecord record =
  T.unlines $
    [ workspaceRecordHeader,
      "service: " <> (.service) record,
      "manifest: " <> (.manifest) record,
      "context: " <> (.context) record,
      "module-root: " <> rootLabel,
      "layout: " <> (.layout) record,
      "naming-edition " <> renderGeneratedHaskellNamingEdition ((.namingEdition) record)
    ]
      <> ["member " <> T.pack path | path <- (.members) record]
      <> ["source-language " <> encodeRow row | row <- (.sourceLanguages) record]
      <> ["semantic-contract " <> encodeRow ((.languageContract) record)]
      <> ["module " <> encodeRow row | row <- (.modules) record]
      <> [mappingRowPrefix mapping <> encodeRow mapping | mapping <- (.mappings) record]
      <> ["id-domain " <> identity | identity <- (.idDomains) record]
      <> ["nominal-equality " <> identity | identity <- (.nominalEqualities) record]
      <> ["binding " <> encodeRow obligation | obligation <- (.bindingObligations) record]
      <> ["behavior " <> encodeRow requirement | requirement <- (.requirements) record]
      <> ["projection-catalog-fact " <> fact | fact <- (.projectionCatalogFacts) record]
      <> ["query-contract-baseline v1" | (.queryContractBaseline) record]
      <> ["query-contract " <> encodeRow identity | identity <- (.queryContracts) record]
      <> ["router-selection " <> encodeRow selection | selection <- (.routerSelections) record]
      <> ["semantic-impact " <> encodeRow snapshot | Just snapshot <- [(.semanticImpact) record]]
      <> ["adopted " <> encodeRow adopted | adopted <- (.adopted) record]
  where
    rootLabel = if T.null ((.moduleRoot) record) then "(none)" else (.moduleRoot) record

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
        languageContract <- parseLanguageContract sourceLanguages rows
        namingEdition <- parseNamingEdition rows
        modules <- traverse (decodeRow "module ") (rowsWith "module " rows)
        checkedModules <- traverse checkedModule modules
        ordinaryMappings <- traverse (decodeRow "mapping ") (rowsWith "mapping " rows)
        nominalMappings <- traverse (decodeRow "nominal-mapping ") (rowsWith "nominal-mapping " rows)
        let mappings = ordinaryMappings <> nominalMappings
        let idDomains = [identity | row <- rows, Just identity <- [T.stripPrefix "id-domain " row]]
        let nominalEqualities = [identity | row <- rows, Just identity <- [T.stripPrefix "nominal-equality " row]]
        obligations <- traverse (decodeRow "binding ") (rowsWith "binding " rows)
        requirements <- traverse (decodeRow "behavior ") (rowsWith "behavior " rows)
        let catalogFacts = [fact | row <- rows, Just fact <- [T.stripPrefix "projection-catalog-fact " row]]
        queryContractBaseline <- parseQueryContractBaseline rows
        queryContracts <- traverse (decodeRow "query-contract ") (rowsWith "query-contract " rows)
        routerSelections <- traverse (decodeRow "router-selection ") (rowsWith "router-selection " rows)
        semanticImpact <- parseSemanticImpact rows
        adopted <- (traverse (decodeRow "adopted ") (rowsWith "adopted " rows) :: Maybe [AdoptedRow])
        checkedAdopted <- traverse checkedAdoption adopted
        if hasDuplicates members
          || hasDuplicates (map (.path) checkedModules)
          || hasDuplicates (map (.specName) mappings)
          || hasDuplicates idDomains
          || hasDuplicates nominalEqualities
          || hasDuplicates (map bindingKey obligations)
          || hasDuplicates (map (.key) requirements)
          || hasDuplicates catalogFacts
          || hasDuplicates (map queryContractIdentityKey queryContracts)
          || hasDuplicates (map (.router) routerSelections)
          then Nothing
          else
            pure
              WorkspaceRecord
                { service = service,
                  manifest = manifest,
                  context = context,
                  moduleRoot = if rootLabel == "(none)" then "" else rootLabel,
                  layout = layout,
                  members = members,
                  sourceLanguages = sourceLanguages,
                  languageContract = languageContract,
                  namingEdition = namingEdition,
                  modules = checkedModules,
                  mappings = mappings,
                  idDomains = idDomains,
                  nominalEqualities = nominalEqualities,
                  bindingObligations = obligations,
                  requirements = requirements,
                  projectionCatalogFacts = catalogFacts,
                  queryContractBaseline = queryContractBaseline,
                  queryContracts = queryContracts,
                  routerSelections = routerSelections,
                  adopted = checkedAdopted,
                  semanticImpact = semanticImpact
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
    checkedModule :: WorkspaceModuleRow -> Maybe WorkspaceModuleRow
    checkedModule row = do
      path <- safePath (T.pack ((.path) row))
      owner <- traverse (safePath . T.pack) ((.owner) row)
      pure
        WorkspaceModuleRow
          { kind = (.kind) row,
            path = path,
            owner = owner,
            role = (.role) row
          }
    checkedAdoption :: AdoptedRow -> Maybe AdoptedRow
    checkedAdoption row = do
      path <- safePath (T.pack ((.path) row))
      pure
        AdoptedRow
          { path = path,
            evidence = (.evidence) row,
            source = (.source) row,
            spec = (.spec) row
          }
    parseSourceLanguages members rows = case rowsWith "source-language " rows of
      [] -> Just [WorkspaceSourceLanguageRow path LegacyUnversioned | path <- members]
      sourceRows -> do
        decoded <- traverse (decodeRow "source-language ") sourceRows
        checked <- traverse checkedSourceLanguage decoded
        if hasDuplicates (map (.path) checked) || sort (map (.path) checked) /= sort members
          then Nothing
          else Just checked
    parseLanguageContract sourceLanguages rows = do
      let inferred = nub [effectiveLanguageContract ((.sourceLanguage) row) | row <- sourceLanguages]
      common <- case inferred of
        [contract] -> Just contract
        [] -> Just (effectiveLanguageContract LegacyUnversioned)
        _ -> Nothing
      case rowsWith "semantic-contract " rows of
        [] -> Just common
        [row] -> do
          contract <- decodeRow "semantic-contract " row
          if contract == common then Just contract else Nothing
        _ -> Nothing
    parseNamingEdition rows = case rowsWith "naming-edition " rows of
      [] -> Just LegacyNamingV1
      [row] -> T.stripPrefix "naming-edition " row >>= parseGeneratedHaskellNamingEdition
      _ -> Nothing
    parseSemanticImpact rows = case rowsWith "semantic-impact " rows of
      [] -> Just Nothing
      [row] -> Just <$> decodeRow "semantic-impact " row
      _ -> Nothing
    parseQueryContractBaseline rows = case rowsWith "query-contract-baseline " rows of
      [] -> Just False
      ["query-contract-baseline v1"] -> Just True
      _ -> Nothing
    checkedSourceLanguage :: WorkspaceSourceLanguageRow -> Maybe WorkspaceSourceLanguageRow
    checkedSourceLanguage row = do
      path <- safePath (T.pack ((.path) row))
      pure
        WorkspaceSourceLanguageRow
          { path = path,
            sourceLanguage = (.sourceLanguage) row
          }
    safePath raw =
      let path = T.unpack raw
       in if null path || isAbsolute path || ".." `elem` splitDirectories path
            then Nothing
            else Just path
    hasDuplicates :: (Eq a) => [a] -> Bool
    hasDuplicates values = length values /= length (nub values)
    bindingKey hole =
      ( (.mappedName) hole,
        (.moduleName) hole,
        (.symbol) hole,
        (.kind) hole,
        (.path) hole
      )

-- | @keiro-dsl-ledger.workspace.\<service\>.txt@ — the machine-owned workspace
-- history ledger.
workspaceRecordFileName :: Text -> FilePath
workspaceRecordFileName = SidecarNames.workspaceLedgerFileName

-- | @keiro-dsl-cabal-fragment.workspace.\<service\>.txt@ — the human-facing
-- Cabal fragment. Kept under the historical helper name for API compatibility.
workspaceManifestFileName :: Text -> FilePath
workspaceManifestFileName = SidecarNames.workspaceCabalFragmentFileName

-- | @keiro-dsl-migration-report.workspace.\<service\>.txt@ — the durable review
-- artifact written once, on the run that adopts pre-workspace scaffold output.
workspaceMigrationReportFileName :: Text -> FilePath
workspaceMigrationReportFileName = SidecarNames.workspaceMigrationReportFileName

-- | The single line adoption appends to a superseded legacy record. The v1
-- parser ignores unknown lines, so the legacy record keeps parsing for old
-- binaries and stays readable for humans; nothing is renamed or deleted.
supersededByLine :: Text -> Text
supersededByLine service = "superseded-by: " <> T.pack (workspaceRecordFileName service)

mappingRowPrefix :: MappingIdentity -> Text
mappingRowPrefix NominalMapping {} = "nominal-mapping "
mappingRowPrefix _ = "mapping "
