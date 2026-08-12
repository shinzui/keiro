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
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract, checkedSpec, effectiveLanguageContract)
import Keiro.Dsl.SemanticImpact (SemanticImpactSnapshot)
import Keiro.Dsl.SidecarNames (contextLedgerFileName)
import System.FilePath (isAbsolute, splitDirectories)

data ScaffoldRecord = ScaffoldRecord
  { recSpecPath :: !Text,
    recModuleRoot :: !Text,
    recLayout :: !Text,
    recSourceLanguage :: !SourceLanguage,
    recLanguageContract :: !EffectiveLanguageContract,
    recNamingEdition :: !GeneratedHaskellNamingEdition,
    recModuleRoles :: ![ScaffoldModuleRoleRow],
    recFiles :: ![(ModuleKind, FilePath)],
    recMappings :: ![MappingIdentity],
    recIdDomains :: ![Text],
    recNominalEqualities :: ![Text],
    recBindingObligations :: ![BindingHole],
    recBehaviorRequirements :: ![BehaviorRecordRow],
    recProjectionCatalogFacts :: ![Text],
    recQueryContractBaseline :: !Bool,
    recQueryContracts :: ![QueryContractIdentity],
    recRouterSelections :: ![RouterSelectionSnapshot],
    recSemanticImpact :: !(Maybe SemanticImpactSnapshot)
  }
  deriving stock (Eq, Show)

data ScaffoldModuleRoleRow = ScaffoldModuleRoleRow
  { srrRole :: !ModuleRole,
    srrKind :: !ModuleKind,
    srrPath :: !FilePath
  }
  deriving stock (Eq, Show)

instance Aeson.ToJSON ScaffoldModuleRoleRow where
  toJSON row =
    Aeson.object
      [ "ownerKind" .= roleOwnerKind role,
        "ownerName" .= roleOwnerName role,
        "family" .= roleFamily role,
        "kind" .= (case srrKind row of Generated -> "generated" :: Text; HoleStub -> "hole"),
        "path" .= T.pack (srrPath row)
      ]
    where
      role = srrRole row

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
        { srrRole = ModuleRole ownerKind ownerName family,
          srrKind = rowKind,
          srrPath = T.unpack (rowPath :: Text)
        }

renderRecord :: ScaffoldRecord -> Text
renderRecord record =
  T.unlines $
    [ "keiro-dsl scaffold record v1",
      "spec: " <> recSpecPath record,
      "module-root: " <> rootLabel,
      "layout: " <> recLayout record,
      "source-language " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode (recSourceLanguage record))),
      "semantic-contract " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode (recLanguageContract record))),
      "naming-edition " <> renderGeneratedHaskellNamingEdition (recNamingEdition record)
    ]
      <> map ("module-role " <>) (map (Text.decodeUtf8 . BL.toStrict . Aeson.encode) (recModuleRoles record))
      <> map renderFile (recFiles record)
      <> map renderMapping (recMappings record)
      <> map ("id-domain " <>) (recIdDomains record)
      <> map ("nominal-equality " <>) (recNominalEqualities record)
      <> map renderBindingObligation (recBindingObligations record)
      <> map renderBehaviorRequirement (recBehaviorRequirements record)
      <> map ("projection-catalog-fact " <>) (recProjectionCatalogFacts record)
      <> ["query-contract-baseline v1" | recQueryContractBaseline record]
      <> map ("query-contract " <>) (map (Text.decodeUtf8 . BL.toStrict . Aeson.encode) (recQueryContracts record))
      <> map ("router-selection " <>) (map (Text.decodeUtf8 . BL.toStrict . Aeson.encode) (recRouterSelections record))
      <> ["semantic-impact " <> Text.decodeUtf8 (BL.toStrict (Aeson.encode snapshot)) | Just snapshot <- [recSemanticImpact record]]
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
        if hasDuplicateMappingNames mappings || hasDuplicates idDomains || hasDuplicates nominalEqualities || hasDuplicateBindingObligations bindingEntries || hasDuplicateBehaviorRequirements behaviorEntries || hasDuplicates catalogFacts || hasDuplicates (map queryContractIdentityKey queryContracts) || hasDuplicates (map selectionRouter routerSelections)
          then Nothing
          else
            pure
              ScaffoldRecord
                { recSpecPath = specPath,
                  recModuleRoot = if rootLabel == "(none)" then "" else rootLabel,
                  recLayout = layout,
                  recSourceLanguage = sourceLanguage,
                  recLanguageContract = languageContract,
                  recNamingEdition = namingEdition,
                  recModuleRoles = moduleRoles,
                  recFiles = files,
                  recMappings = mappings,
                  recIdDomains = idDomains,
                  recNominalEqualities = nominalEqualities,
                  recBindingObligations = bindingEntries,
                  recBehaviorRequirements = behaviorEntries,
                  recProjectionCatalogFacts = catalogFacts,
                  recQueryContractBaseline = queryContractBaseline,
                  recQueryContracts = queryContracts,
                  recRouterSelections = routerSelections,
                  recSemanticImpact = semanticImpact
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
    parseModuleRole row = do
      payload <- T.stripPrefix "module-role " row
      decoded <- Aeson.decodeStrict' (Text.encodeUtf8 payload)
      checkedRole decoded
    checkedRole roleRow = do
      path <- checkedPath (T.pack (srrPath roleRow))
      pure roleRow {srrPath = path}
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
      let names = map mappingSpecName mappings
       in length names /= length (nub names)
    hasDuplicates values = length values /= length (nub values)
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
  projectionCatalogFactsWith (checkedSpec service) (analyzeProjectionSupplies (checkedSpec service))

projectionCatalogFactsWith :: Spec -> ProjectionSupplyAnalysis -> [Text]
projectionCatalogFactsWith spec supplyAnalysis = sort (concatMap nodeFacts (specNodes spec) <> map supplyFact (resolvedProjectionSupplies supplyAnalysis))
  where
    nodeFacts (NProjectionTarget target) =
      [T.intercalate "|" ["target", ptName target, ptSchema target, ptTable target, resetText (ptReset target), T.intercalate "," (ptDependsOn target), lineText (ptLoc target)]]
    nodeFacts (NRebuildGroup groupNode) =
      [T.intercalate "|" ["group", rgName groupNode, T.intercalate "," (sort (rgTargets groupNode)), T.intercalate "," (rgOrder groupNode), lineText (rgLoc groupNode)]]
    nodeFacts (NProjectionOwner owner) =
      [ T.intercalate
          "|"
          [ "owner",
            poName owner,
            T.intercalate "," (map sourceText (poSources owner)),
            feedText (poFeed owner),
            poGroup owner,
            T.intercalate "," (sort (poTargets owner)),
            T.pack (show (poOrder owner)),
            maybe "" id (poSubscription owner),
            maybe "" id (poDedup owner),
            T.intercalate "," (map checkpointOnMissingText (poCheckpointOnMissing owner)),
            replayText (poReplay owner),
            lineText (poLoc owner)
          ]
      ]
    nodeFacts (NReadModel readModel)
      | Just groupName <- rmGroup readModel =
          [ T.intercalate
              "|"
              [ "query",
                rmName readModel,
                groupName,
                T.intercalate "," (sort (rmObservedTargets readModel)),
                fromMaybe "" (effectiveBacking readModel),
                lineText (rmLoc readModel)
              ]
          ]
    nodeFacts _ = []
    supplyFact supply =
      T.intercalate
        "|"
        [ "supply",
          supplyQueryModel supply,
          supplyProjectionOwner supply,
          supplyRebuildGroup supply,
          T.intercalate "," (NE.toList (supplyObservedTargets supply)),
          lineText (supplyQueryLoc supply),
          lineText (supplyOwnerLoc supply)
        ]
    effectiveBacking readModel = case rmBackingTarget readModel of
      Just targetName -> Just targetName
      Nothing -> case sort (rmObservedTargets readModel) of
        [targetName] -> Just targetName
        _ -> Nothing
    resetText TargetClear = "clear"
    resetText TargetPreserve = "preserve"
    sourceText CatalogAll = "all"
    sourceText (CatalogCategory categoryName) = "category:" <> categoryName
    sourceText (CatalogAggregate aggregateName) = "aggregate:" <> aggregateName
    feedText RmInline = "inline"
    feedText RmSubscription = "subscription"
    checkpointOnMissingText CheckpointFromBeginning = "from-beginning"
    checkpointOnMissingText CheckpointFromCurrentHead = "from-current-head"
    checkpointOnMissingText CheckpointFail = "fail"
    replayText ProjectionReplayExplicit = "explicit"
    replayText (ProjectionLiveOnly reason) = "live-only:" <> reason
    lineText (Loc lineNumber) = T.pack (show lineNumber)
