-- | Versioned persistence for the files and mapped consumer identities used by
-- one successful scaffold run. Unknown header fields are ignored so v1 readers
-- can consume records extended by later tool versions. Mapping rows are canonical
-- single-line JSON after a @mapping @ prefix; old readers ignore that row kind.
module Keiro.Dsl.ScaffoldRecord
  ( ScaffoldRecord (..),
    ScaffoldModuleRoleRow (..),
    GeneratedHaskellNamingEdition (..),
    renderRecord,
    parseRecord,
    recordFileName,
    projectionCatalogFacts,
    projectionCatalogFactsForService,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.List (nub, sort)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Keiro.Dsl.BehaviorCoverage (BehaviorRecordRow (..))
import Keiro.Dsl.CoordinationImpact (RouterSelectionSnapshot (..))
import Keiro.Dsl.ExplainBindings (BindingHole (..))
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellName (GeneratedHaskellNamingEdition (..), parseGeneratedHaskellNamingEdition, renderGeneratedHaskellNamingEdition)
import Keiro.Dsl.LanguageVersion (SourceLanguage (..))
import Keiro.Dsl.MappedConsumer (MappingIdentity (..))
import Keiro.Dsl.ProjectionSupply
import Keiro.Dsl.ReadModelQueryContract (QueryContractIdentity, queryContractIdentityKey)
import Keiro.Dsl.Scaffold (ModuleKind (..), ModuleRole (..))
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract, checkedProjectionSupplies, checkedSpec, effectiveLanguageContract)
import Keiro.Dsl.SemanticImpact (SemanticImpactSnapshot)
import Keiro.Dsl.SidecarNames (contextLedgerFileName)
import System.FilePath (isAbsolute, splitDirectories)

data ScaffoldRecord = ScaffoldRecord
  { specPath :: !Text,
    moduleRoot :: !Text,
    layout :: !Text,
    sourceLanguage :: !SourceLanguage,
    languageContract :: !EffectiveLanguageContract,
    namingEdition :: !GeneratedHaskellNamingEdition,
    moduleRoles :: ![ScaffoldModuleRoleRow],
    files :: ![(ModuleKind, FilePath)],
    mappings :: ![MappingIdentity],
    idDomains :: ![Text],
    nominalEqualities :: ![Text],
    bindingObligations :: ![BindingHole],
    behaviorRequirements :: ![BehaviorRecordRow],
    projectionCatalogFacts :: ![Text],
    queryContractBaseline :: !Bool,
    queryContracts :: ![QueryContractIdentity],
    routerSelections :: ![RouterSelectionSnapshot],
    semanticImpact :: !(Maybe SemanticImpactSnapshot)
  }
  deriving stock (Eq, Show)

data ScaffoldModuleRoleRow = ScaffoldModuleRoleRow
  { role :: !ModuleRole,
    kind :: !ModuleKind,
    path :: !FilePath
  }
  deriving stock (Eq, Show)

instance Aeson.ToJSON ScaffoldModuleRoleRow where
  toJSON row =
    Aeson.object
      [ "ownerKind" .= (.ownerKind) role,
        "ownerName" .= (.ownerName) role,
        "family" .= (.family) role,
        "kind" .= (case (.kind) row of Generated -> "generated" :: Text; HoleStub -> "hole"),
        "path" .= T.pack ((.path) row)
      ]
    where
      role = (.role) row

instance Aeson.FromJSON ScaffoldModuleRoleRow where
  parseJSON = Aeson.withObject "ScaffoldModuleRoleRow" $ \fields -> do
    ownerKind <- fields .: "ownerKind"
    ownerName <- fields .: "ownerName"
    family <- fields .: "family"
    kindLabel <- fields .: "kind"
    rowKind <- case (kindLabel :: Text) of
      "generated" -> pure Generated
      "hole" -> pure HoleStub
      other -> fail ("unknown module kind: " <> T.unpack other)
    rowPath <- fields .: "path"
    pure
      ScaffoldModuleRoleRow
        { role = ModuleRole ownerKind ownerName family,
          kind = rowKind,
          path = T.unpack (rowPath :: Text)
        }

renderRecord :: ScaffoldRecord -> Text
renderRecord record =
  T.unlines $
    [ "keiro-dsl scaffold record v1",
      "spec: " <> (.specPath) record,
      "module-root: " <> rootLabel,
      "layout: " <> (.layout) record,
      "source-language " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode ((.sourceLanguage) record))),
      "semantic-contract " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode ((.languageContract) record))),
      "naming-edition " <> renderGeneratedHaskellNamingEdition ((.namingEdition) record)
    ]
      <> map ("module-role " <>) (map (Text.decodeUtf8 . BL.toStrict . Aeson.encode) ((.moduleRoles) record))
      <> map renderFile ((.files) record)
      <> map renderMapping ((.mappings) record)
      <> map ("id-domain " <>) ((.idDomains) record)
      <> map ("nominal-equality " <>) ((.nominalEqualities) record)
      <> map renderBindingObligation ((.bindingObligations) record)
      <> map renderBehaviorRequirement ((.behaviorRequirements) record)
      <> map ("projection-catalog-fact " <>) ((.projectionCatalogFacts) record)
      <> ["query-contract-baseline v1" | (.queryContractBaseline) record]
      <> map ("query-contract " <>) (map (Text.decodeUtf8 . BL.toStrict . Aeson.encode) ((.queryContracts) record))
      <> map ("router-selection " <>) (map (Text.decodeUtf8 . BL.toStrict . Aeson.encode) ((.routerSelections) record))
      <> ["semantic-impact " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode snapshot)) | Just snapshot <- [(.semanticImpact) record]]
  where
    rootLabel = if T.null ((.moduleRoot) record) then "(none)" else (.moduleRoot) record
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
        languageContract <- parseLanguageContract sourceLanguage rows
        namingEdition <- parseNamingEdition rows
        moduleRoles <- traverse parseModuleRole (filter ("module-role " `T.isPrefixOf`) rows)
        files <- traverse parseFile (filter isFileRow rows)
        ordinaryMappings <- traverse (parseMapping "mapping ") (filter ("mapping " `T.isPrefixOf`) rows)
        nominalMappings <- traverse (parseMapping "nominal-mapping ") (filter ("nominal-mapping " `T.isPrefixOf`) rows)
        let mappings = ordinaryMappings <> nominalMappings
        let idDomains = [identity | row <- rows, Just identity <- [T.stripPrefix "id-domain " row]]
        let nominalEqualities = [identity | row <- rows, Just identity <- [T.stripPrefix "nominal-equality " row]]
        bindingEntries <- traverse parseBindingObligation (filter ("binding " `T.isPrefixOf`) rows)
        behaviorEntries <- traverse parseBehaviorRequirement (filter ("behavior " `T.isPrefixOf`) rows)
        let catalogFacts = [fact | row <- rows, Just fact <- [T.stripPrefix "projection-catalog-fact " row]]
        queryContractBaseline <- parseQueryContractBaseline rows
        queryContracts <- traverse parseQueryContract (filter ("query-contract " `T.isPrefixOf`) rows)
        routerSelections <- traverse parseRouterSelection (filter ("router-selection " `T.isPrefixOf`) rows)
        semanticImpact <- parseSemanticImpact rows
        if hasDuplicateMappingNames mappings || hasDuplicates idDomains || hasDuplicates nominalEqualities || hasDuplicateBindingObligations bindingEntries || hasDuplicateBehaviorRequirements behaviorEntries || hasDuplicates catalogFacts || hasDuplicates (map queryContractIdentityKey queryContracts) || hasDuplicates (map (.router) routerSelections)
          then Nothing
          else
            pure
              ScaffoldRecord
                { specPath = specPath,
                  moduleRoot = if rootLabel == "(none)" then "" else rootLabel,
                  layout = layout,
                  sourceLanguage = sourceLanguage,
                  languageContract = languageContract,
                  namingEdition = namingEdition,
                  moduleRoles = moduleRoles,
                  files = files,
                  mappings = mappings,
                  idDomains = idDomains,
                  nominalEqualities = nominalEqualities,
                  bindingObligations = bindingEntries,
                  behaviorRequirements = behaviorEntries,
                  projectionCatalogFacts = catalogFacts,
                  queryContractBaseline = queryContractBaseline,
                  queryContracts = queryContracts,
                  routerSelections = routerSelections,
                  semanticImpact = semanticImpact
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
    parseQueryContract row = do
      payload <- T.stripPrefix "query-contract " row
      Aeson.decodeStrict' (Text.encodeUtf8 payload)
    parseRouterSelection row = do
      payload <- T.stripPrefix "router-selection " row
      Aeson.decodeStrict' (Text.encodeUtf8 payload)
    parseQueryContractBaseline rows = case filter ("query-contract-baseline " `T.isPrefixOf`) rows of
      [] -> Just False
      ["query-contract-baseline v1"] -> Just True
      _ -> Nothing
    parseSemanticImpact rows = case filter ("semantic-impact " `T.isPrefixOf`) rows of
      [] -> Just Nothing
      [row] -> do
        payload <- T.stripPrefix "semantic-impact " row
        Just <$> Aeson.decodeStrict' (Text.encodeUtf8 payload)
      _ -> Nothing
    parseModuleRole :: Text -> Maybe ScaffoldModuleRoleRow
    parseModuleRole row = do
      payload <- T.stripPrefix "module-role " row
      decoded <- Aeson.decodeStrict' (Text.encodeUtf8 payload)
      checkedRole decoded
    checkedRole :: ScaffoldModuleRoleRow -> Maybe ScaffoldModuleRoleRow
    checkedRole roleRow = do
      path <- checkedPath (T.pack ((.path) roleRow))
      pure
        ScaffoldModuleRoleRow
          { role = (.role) roleRow,
            kind = (.kind) roleRow,
            path = path
          }
    checkedPath pathText =
      let path = T.unpack pathText
       in if null path || isAbsolute path || ".." `elem` splitDirectories path
            then Nothing
            else Just path
    parseSourceLanguage rows = case filter ("source-language " `T.isPrefixOf`) rows of
      [] -> Just LegacyUnversioned
      [row] -> do
        payload <- T.stripPrefix "source-language " row
        Aeson.decodeStrict' (Text.encodeUtf8 payload)
      _ -> Nothing
    parseLanguageContract sourceLanguage rows = case filter ("semantic-contract " `T.isPrefixOf`) rows of
      [] -> Just (effectiveLanguageContract sourceLanguage)
      [row] -> do
        payload <- T.stripPrefix "semantic-contract " row
        contract <- Aeson.decodeStrict' (Text.encodeUtf8 payload)
        if contract == effectiveLanguageContract sourceLanguage then Just contract else Nothing
      _ -> Nothing
    parseNamingEdition rows = case filter ("naming-edition " `T.isPrefixOf`) rows of
      [] -> Just LegacyNamingV1
      [row] -> T.stripPrefix "naming-edition " row >>= parseGeneratedHaskellNamingEdition
      _ -> Nothing
    hasDuplicateMappingNames mappings =
      let names = map (.specName) mappings
       in length names /= length (nub names)
    hasDuplicates values = length values /= length (nub values)
    hasDuplicateBindingObligations obligations =
      let keys = map bindingKey obligations
       in length keys /= length (nub keys)
    bindingKey hole =
      ( (.mappedName) hole,
        (.moduleName) hole,
        (.symbol) hole,
        (.kind) hole,
        (.path) hole
      )
    hasDuplicateBehaviorRequirements requirements =
      let keys = map (.key) requirements
       in length keys /= length (nub keys)

recordFileName :: Text -> FilePath
recordFileName = contextLedgerFileName

mappingRowPrefix :: MappingIdentity -> Text
mappingRowPrefix NominalMapping {} = "nominal-mapping "
mappingRowPrefix _ = "mapping "

-- | Canonical durable catalog identities used when a declaration disappears
-- from the next graph. Source lines remain part of the attribution evidence.
projectionCatalogFacts :: Spec -> [Text]
projectionCatalogFacts spec = projectionCatalogFactsWith spec (analyzeProjectionSupplies spec)

projectionCatalogFactsForService :: CheckedService -> [Text]
projectionCatalogFactsForService service =
  projectionCatalogFactsWith (checkedSpec service) (checkedProjectionSupplies service)

projectionCatalogFactsWith :: Spec -> ProjectionSupplyAnalysis -> [Text]
projectionCatalogFactsWith spec supplyAnalysis = sort (concatMap nodeFacts ((.nodes) spec) <> map supplyFact supplies)
  where
    supplies = (.resolvedProjectionSupplies) supplyAnalysis
    owners = [owner | NProjectionOwner owner <- (.nodes) spec]
    nodeFacts (NProjectionTarget target) =
      [T.intercalate "|" ["target", (.name) target, (.schema) target, (.table) target, resetText ((.reset) target), T.intercalate "," ((.dependsOn) target), lineText ((.loc) target)]]
    nodeFacts (NRebuildGroup groupNode) =
      [T.intercalate "|" ["group", (.name) groupNode, T.intercalate "," (sort ((.targets) groupNode)), T.intercalate "," ((.order) groupNode), lineText ((.loc) groupNode)]]
    nodeFacts (NProjectionRevision revision) =
      [ T.intercalate
          "|"
          [ "revision",
            (.name) revision,
            (.group) revision,
            T.intercalate ";" (map revisionTargetText ((.targets) revision)),
            lineText ((.loc) revision)
          ]
      ]
    nodeFacts (NExternalRead externalRead) =
      [ T.intercalate
          "|"
          [ "external-read",
            (.name) externalRead,
            T.pack (show ((.version) externalRead)),
            (.queryModel) externalRead,
            (.resultSchema) externalRead <> "." <> (.resultType) externalRead,
            externalReadShape externalRead,
            T.intercalate "," (sort ((.compatibleRevisions) externalRead)),
            T.pack (show ((.surfaceGeneration) externalRead)),
            lineText ((.loc) externalRead)
          ]
      ]
    nodeFacts (NProjectionOwner owner) =
      [ T.intercalate
          "|"
          [ "owner",
            (.name) owner,
            T.intercalate "," (map sourceText ((.sources) owner)),
            (.group) owner,
            T.intercalate "," (sort ((.targets) owner)),
            T.pack (show ((.order) owner)),
            maybe "" id ((.subscription) owner),
            maybe "" id ((.dedup) owner),
            T.intercalate "," (map checkpointOnMissingText ((.checkpointOnMissing) owner)),
            replayText ((.replay) owner),
            lineText ((.loc) owner)
          ],
        T.intercalate
          "|"
          [ "delivery",
            (.name) owner,
            deliveryText ((.delivery) owner),
            lineText ((.loc) owner)
          ]
      ]
    nodeFacts (NReadModel readModel)
      | Just groupName <- (.group) readModel =
          [ T.intercalate
              "|"
              [ "query",
                (.name) readModel,
                groupName,
                T.intercalate "," (sort ((.observedTargets) readModel)),
                fromMaybe "" (effectiveBacking readModel),
                lineText ((.loc) readModel)
              ],
            T.intercalate
              "|"
              [ "freshness",
                (.name) readModel,
                freshnessText ((.freshness) readModel),
                lineText ((.loc) readModel)
              ],
            T.intercalate
              "|"
              [ "cursor",
                (.name) readModel,
                fromMaybe "none" (resolvedCursor readModel),
                lineText ((.loc) readModel)
              ]
          ]
    nodeFacts _ = []
    externalReadShape externalRead = case [(.shape) readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == (.queryModel) externalRead] of
      shape : _ -> shape
      [] -> "missing-query"
    revisionTargetText target =
      T.intercalate
        ","
        [ (.target) target,
          (.schemaVersion) target,
          (.provisioner) target,
          T.pack (show ((.provisionerVersion) target)),
          (.expectedShape) target,
          (.validator) target,
          T.pack (show ((.validatorVersion) target)),
          T.intercalate ":" (map promotionText ((.promotionObjects) target))
        ]
    promotionText promotionObject =
      T.intercalate
        ">"
        [ promotionKindText ((.kind) promotionObject),
          (.generationName) promotionObject,
          (.canonicalName) promotionObject
        ]
    promotionKindText PromotionIndexNode = "index"
    promotionKindText PromotionConstraintNode = "constraint"
    promotionKindText PromotionOwnedSequenceNode = "owned-sequence"
    supplyFact supply =
      T.intercalate
        "|"
        [ "supply",
          (.queryModel) supply,
          (.projectionOwner) supply,
          (.rebuildGroup) supply,
          T.intercalate "," (NE.toList ((.observedTargets) supply)),
          lineText ((.queryLoc) supply),
          lineText ((.ownerLoc) supply)
        ]
    effectiveBacking readModel = case (.backingTarget) readModel of
      Just targetName -> Just targetName
      Nothing -> case sort ((.observedTargets) readModel) of
        [targetName] -> Just targetName
        _ -> Nothing
    resetText TargetClear = "clear"
    resetText TargetPreserve = "preserve"
    sourceText CatalogAll = "all"
    sourceText (CatalogCategory categoryName) = "category:" <> categoryName
    sourceText (CatalogAggregate aggregateName) = "aggregate:" <> aggregateName
    deliveryText DeliveryInline = "inline"
    deliveryText DeliverySubscription = "subscription"
    freshnessText FreshnessImmediate = "immediate"
    freshnessText (FreshnessWaitForHead RmEntireLog) = "wait-for-head:entire-log"
    freshnessText (FreshnessWaitForHead (RmCategory categoryName)) = "wait-for-head:category:" <> categoryName
    resolvedCursor readModel = do
      ownerName <- case [ (.projectionOwner) supply
                        | supply <- supplies,
                          (.queryModel) supply == (.name) readModel
                        ] of
        [name] -> Just name
        _ -> Nothing
      owner <- case [candidate | candidate <- owners, (.name) candidate == ownerName] of
        [candidate] -> Just candidate
        _ -> Nothing
      case (.delivery) owner of
        DeliveryInline -> Nothing
        DeliverySubscription -> (.subscription) owner
    checkpointOnMissingText CheckpointFromBeginning = "from-beginning"
    checkpointOnMissingText CheckpointFromCurrentHead = "from-current-head"
    checkpointOnMissingText CheckpointFail = "fail"
    replayText ProjectionReplayExplicit = "explicit"
    replayText (ProjectionLiveOnly reason) = "live-only:" <> reason
    lineText (Loc lineNumber) = T.pack (show lineNumber)
