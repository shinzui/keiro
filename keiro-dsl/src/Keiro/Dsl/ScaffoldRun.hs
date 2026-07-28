{- | The filesystem-facing scaffold pipeline. It separates pure planning from
execution so every refusal is known before the first output byte is written.
-}
module Keiro.Dsl.ScaffoldRun (
    Refusal (..),
    WriteDisposition (..),
    StaleModule (..),
    MappingDrift (..),
    ScaffoldReport (..),
    scaffoldModules,
    scaffoldModulesWithGoldens,
    planScaffold,
    planScaffoldWithGoldens,
    executeScaffold,
    renderRefusals,
    renderScaffoldReport,
) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.ExplainBindings (BindingHole (..), BindingObligationKind (..), bindingHoles)
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar (Node (..), Spec (..))
import Keiro.Dsl.Harness (harnessForWithGoldens, harnessProcess, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifest)
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), MappingIdentity (..), consumerPlan)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord, recordFileName, renderRecord)
import Keiro.Dsl.TypeGraph (MappedKey (..), TypeGraph (..), UseSite (..), resolveTypeGraph)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))

data Refusal
    = PathCollision !FilePath ![Text]
    | FirewallBreach ![(FilePath, Text, Int)]
    | LoweringRefusal ![Text]
    | MissingGeneratedBanner ![FilePath]
    | ImportCycle ![Text]
    deriving stock (Eq, Show)

data WriteDisposition = Overwritten | Created | Skipped
    deriving stock (Eq, Show)

data StaleModule = StaleModule
    { staleKind :: !ModuleKind
    , stalePath :: !FilePath
    }
    deriving stock (Eq, Show)

data MappingDrift = MappingDrift
    { driftSpecName :: !Text
    , driftPrevious :: !(Maybe MappingIdentity)
    , driftCurrent :: !(Maybe MappingIdentity)
    }
    deriving stock (Eq, Show)

data ScaffoldReport = ScaffoldReport
    { reportSpecPath :: !FilePath
    , reportOutDir :: !FilePath
    , reportContext :: !Context
    , reportDispositions :: ![(ScaffoldModule, WriteDisposition)]
    , reportManifestPath :: !FilePath
    , reportRecordPath :: !FilePath
    , reportPreviousSpecPath :: !(Maybe Text)
    , reportStale :: ![StaleModule]
    , reportConsumerPlan :: !ConsumerPlan
    , reportConstraintPlan :: ![Text]
    , reportMappingDrift :: ![MappingDrift]
    , reportNewHoles :: ![BindingHole]
    }
    deriving stock (Eq, Show)

{- | Produce the complete in-memory module set for a specification. Keeping
this registry in one place prevents the CLI and tests from drifting apart.
-}
scaffoldModules :: Context -> Spec -> [ScaffoldModule]
scaffoldModules = scaffoldModulesWithGoldens []

scaffoldModulesWithGoldens :: [GoldenPayload] -> Context -> Spec -> [ScaffoldModule]
scaffoldModulesWithGoldens goldens ctx spec =
    scaffoldStructural ctx spec
        <> scaffoldReplayAudit ctx spec
        <> concat
            [ case node of
                NAggregate agg -> scaffoldAggregate ctx spec agg <> harnessForWithGoldens goldens ctx spec agg
                NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
                NRouter router -> scaffoldRouter ctx router <> harnessRouter ctx router
                NContract contract -> scaffoldContract ctx contract
                NIntake intake -> scaffoldIntake ctx intake
                NPublisher publisher -> scaffoldPublisher ctx publisher
                NWorkqueue workqueue -> scaffoldWorkqueue ctx workqueue
                NReadModel readModel -> scaffoldReadModel ctx readModel <> harnessReadModel ctx readModel
                NWorkflow workflow -> harnessWorkflow ctx workflow
                NEmit _ -> []
                NPgmqDispatch _ -> []
                NOperation _ -> []
            | node <- specNodes spec
            ]

{- | Run every pure refusal gate. A successful result is the exact write set;
a refusal has no write set and therefore cannot be accidentally executed.
-}
planScaffold :: Context -> Spec -> Either [Refusal] [ScaffoldModule]
planScaffold = planScaffoldWithGoldens []

planScaffoldWithGoldens :: [GoldenPayload] -> Context -> Spec -> Either [Refusal] [ScaffoldModule]
planScaffoldWithGoldens goldens ctx spec =
    let modules = scaffoldModulesWithGoldens goldens ctx spec
        breaches = firewallBreaches modules
        refusals =
            collisionRefusals modules
                <> dependencyRefusals ctx spec modules
                <> [FirewallBreach breaches | not (null breaches)]
                <> [LoweringRefusal lowering | let lowering = scaffoldRefusals spec, not (null lowering)]
     in if null refusals then Right modules else Left refusals

dependencyRefusals :: Context -> Spec -> [ScaffoldModule] -> [Refusal]
dependencyRefusals ctx spec modules = collisionWithConsumers <> namespaceCycles
  where
    plan = consumerPlan spec
    generatedByName = Map.fromList [(moduleNameOf (modulePath moduleValue), moduleValue) | moduleValue <- modules, kind moduleValue == Generated]
    collisionWithConsumers =
        [ PathCollision
            (modulePath generated)
            [origin generated, "consumer module " <> consumerModule]
        | consumerModule <- consumerModules plan
        , Just generated <- [Map.lookup consumerModule generatedByName]
        ]
    namespaceCycles =
        [ ImportCycle [importer, consumerModule, importer]
        | consumerModule <- consumerModules plan
        , generatedNamespaceOwned ctx consumerModule
        , importer <- take 1 (importersOf consumerModule modules <> [contextGeneratedRoot ctx])
        ]

generatedNamespaceOwned :: Context -> Text -> Bool
generatedNamespaceOwned ctx consumerModule = case placement ctx of
    GeneratedPrefix -> contextGeneratedRoot ctx `T.isPrefixOf` consumerModule
    CollocatedLeaf ->
        (root <> contextSegment <> ".") `T.isPrefixOf` consumerModule
            && ".Generated" `T.isInfixOf` consumerModule
  where
    root = if T.null (moduleRoot ctx) then "" else moduleRoot ctx <> "."
    contextSegment = pascalFromKebab (contextName ctx)

contextGeneratedRoot :: Context -> Text
contextGeneratedRoot ctx = case placement ctx of
    GeneratedPrefix -> root <> "Generated." <> contextSegment
    CollocatedLeaf -> root <> contextSegment <> ".Generated"
  where
    root = if T.null (moduleRoot ctx) then "" else moduleRoot ctx <> "."
    contextSegment = pascalFromKebab (contextName ctx)

importersOf :: Text -> [ScaffoldModule] -> [Text]
importersOf imported =
    map (moduleNameOf . modulePath)
        . filter (any (importsModule imported) . T.lines . moduleText)

importsModule :: Text -> Text -> Bool
importsModule expected line = case T.words (T.strip line) of
    "import" : rest -> expected `elem` rest
    _ -> False

collisionRefusals :: [ScaffoldModule] -> [Refusal]
collisionRefusals modules =
    [ PathCollision (modulePath first) (map origin (first : rest))
    | first : rest <- Map.elems grouped
    , not (null rest)
    ]
  where
    grouped =
        Map.fromListWith
            (flip (<>))
            [(T.toCaseFold (T.pack (modulePath m)), [m]) | m <- modules]

{- | Check existing generated paths, then perform the deterministic writes and
manifest rewrite. Banner refusal is evaluated for the complete set before the
output directory is created or any file is changed.
-}
executeScaffold :: FilePath -> Bool -> FilePath -> Context -> Spec -> [ScaffoldModule] -> IO (Either [Refusal] ScaffoldReport)
executeScaffold out forceGeneratedOverwrite specPath ctx spec modules = do
    bannerless <- if forceGeneratedOverwrite then pure [] else missingGeneratedBanners out modules
    if not (null bannerless)
        then pure (Left [MissingGeneratedBanner bannerless])
        else do
            let recordPath = out </> recordFileName (specContext spec)
            previousRecord <- readRecord recordPath
            stale <- maybe (pure []) (existingStale out modules) previousRecord
            let currentConsumerPlan = consumerPlan spec
                drift = maybe [] (mappingDrift (consumerMappings currentConsumerPlan) . recMappings) previousRecord
                currentObligations = either (const []) id (bindingHoles spec)
                newHoles = maybe [] (newBindingObligations currentObligations . recBindingObligations) previousRecord
            createDirectoryIfMissing True out
            dispositions <- mapM (writeModule out) modules
            let manifestPath = out </> ("keiro-dsl-manifest." <> T.unpack (specContext spec) <> ".txt")
            TIO.writeFile manifestPath (renderManifest (T.pack specPath) modules spec)
            TIO.writeFile recordPath (renderRecord (currentRecord specPath ctx spec modules))
            pure $
                Right
                    ScaffoldReport
                        { reportSpecPath = specPath
                        , reportOutDir = out
                        , reportContext = ctx
                        , reportDispositions = dispositions
                        , reportManifestPath = manifestPath
                        , reportRecordPath = recordPath
                        , reportPreviousSpecPath = recSpecPath <$> previousRecord
                        , reportStale = stale
                        , reportConsumerPlan = currentConsumerPlan
                        , reportConstraintPlan = constraintPlan spec currentConsumerPlan
                        , reportMappingDrift = drift
                        , reportNewHoles = newHoles
                        }

constraintPlan :: Spec -> ConsumerPlan -> [Text]
constraintPlan spec plan = case resolveTypeGraph spec of
    Left _ -> []
    Right graph ->
        let registerRoots =
                Set.fromList
                    [ key
                    | RootRegister _ _ key <- tgUseSites graph
                    ]
         in map (constraintFor registerRoots) (consumerMappings plan)
  where
    constraintFor registerRoots mapping =
        mappingSpecName mapping
            <> ": "
            <> T.intercalate ", " (baseConstraints mapping <> registerConstraints registerRoots mapping)
    baseConstraints StructuralMapping{} = ["Eq", "Show", "CanonicalTypeName", "StructuralBinding"]
    baseConstraints OpaqueMapping{} = ["Eq", "Show", "ToJSON", "FromJSON"]
    registerConstraints roots mapping
        | MappedKey (mappingSpecName mapping) `Set.member` roots = ["register initial", "snapshot ToJSON", "snapshot FromJSON"]
        | otherwise = []

mappingDrift :: [MappingIdentity] -> [MappingIdentity] -> [MappingDrift]
mappingDrift current previous =
    [ MappingDrift name old new
    | name <- Set.toAscList (Map.keysSet oldByName <> Map.keysSet newByName)
    , let old = Map.lookup name oldByName
    , let new = Map.lookup name newByName
    , old /= new
    ]
  where
    oldByName = Map.fromList [(mappingSpecName mapping, mapping) | mapping <- previous]
    newByName = Map.fromList [(mappingSpecName mapping, mapping) | mapping <- current]

newBindingObligations :: [BindingHole] -> [BindingHole] -> [BindingHole]
newBindingObligations current previous =
    [ obligation
    | obligation <- current
    , obligation `Set.notMember` previousSet
    ]
  where
    previousSet = Set.fromList previous

readRecord :: FilePath -> IO (Maybe ScaffoldRecord)
readRecord path = do
    exists <- doesFileExist path
    if exists then parseRecord <$> TIO.readFile path else pure Nothing

existingStale :: FilePath -> [ScaffoldModule] -> ScaffoldRecord -> IO [StaleModule]
existingStale out modules record = fmap concat $ mapM stillExists removed
  where
    currentPaths = Set.fromList (map modulePath modules)
    removed = [(fileKind, path) | (fileKind, path) <- recFiles record, path `Set.notMember` currentPaths]
    stillExists (fileKind, path) = do
        exists <- doesFileExist (out </> path)
        pure [StaleModule fileKind path | exists]

currentRecord :: FilePath -> Context -> Spec -> [ScaffoldModule] -> ScaffoldRecord
currentRecord specPath ctx spec modules =
    ScaffoldRecord
        { recSpecPath = T.pack specPath
        , recModuleRoot = moduleRoot ctx
        , recLayout = case placement ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"
        , recFiles = [(kind m, modulePath m) | m <- modules]
        , recMappings = consumerMappings (consumerPlan spec)
        , recBindingObligations = either (const []) id (bindingHoles spec)
        }

missingGeneratedBanners :: FilePath -> [ScaffoldModule] -> IO [FilePath]
missingGeneratedBanners out modules = fmap concat $ mapM check generated
  where
    generated = [m | m <- modules, kind m == Generated]
    check m = do
        let path = out </> modulePath m
        exists <- doesFileExist path
        if not exists
            then pure []
            else do
                contents <- TIO.readFile path
                pure [modulePath m | not (any (T.isPrefixOf "-- @generated") (T.lines contents))]

writeModule :: FilePath -> ScaffoldModule -> IO (ScaffoldModule, WriteDisposition)
writeModule out m = do
    let path = out </> modulePath m
    createDirectoryIfMissing True (takeDirectory path)
    case kind m of
        Generated -> do
            TIO.writeFile path (moduleText m)
            pure (m, Overwritten)
        HoleStub -> do
            exists <- doesFileExist path
            if exists
                then pure (m, Skipped)
                else TIO.writeFile path (moduleText m) >> pure (m, Created)

renderRefusals :: [Refusal] -> [Text]
renderRefusals = concatMap render
  where
    render (PathCollision path origins) =
        [ "error: module path collision -- refusing to scaffold; nothing was written"
        , "  " <> T.pack path
        ]
            <> ["    from " <> source | source <- origins]
    render (FirewallBreach breaches) =
        [ "error: firewall breach -- refusing to scaffold; nothing was written"
        , "firewall: BREACH (" <> tshow (length breaches) <> " forbidden token occurrence(s)):"
        ]
            <> ["  " <> T.pack path <> ":" <> tshow line <> " contains " <> token | (path, token, line) <- breaches]
    render (LoweringRefusal refusals) =
        ["error: scaffold cannot lower this spec faithfully -- refusing; nothing was written"]
            <> map ("  " <>) refusals
    render (MissingGeneratedBanner paths) =
        [ "error: refusing to overwrite " <> tshow (length paths) <> " file(s) at Generated paths that lack the '-- @generated' banner"
        ]
            <> map ("  " <>) (map T.pack paths)
            <> ["  (adopted as hand code? move it, or re-run with --force-generated-overwrite)", "nothing was written"]
    render (ImportCycle path) =
        [ "error: generated/consumer import cycle -- refusing to scaffold; nothing was written"
        , "  " <> T.intercalate " -> " path
        , "  keep bindings in a leaf module that imports only Structural.Shape.* and Keiro.Codec.Structural"
        ]

renderScaffoldReport :: ScaffoldReport -> [Text]
renderScaffoldReport report =
    [ "scaffold: " <> T.pack (reportSpecPath report) <> " -> " <> T.pack (reportOutDir report) <> " (module-root=" <> rootLabel <> ", layout=" <> layoutLabel <> ")"
    ]
        <> map moduleLine dispositions
        <> [ "firewall: OK (" <> tshow generatedCount <> " generated modules scanned, 0 forbidden operators)"
           , harnessLine
           , dependencyLine
           , "manifest: " <> T.pack (reportManifestPath report)
           , "record:   " <> T.pack (reportRecordPath report)
           ]
        <> previousSpecNote
        <> constraintSection
        <> newHolesSection
        <> mappingDriftSection
        <> staleSection
  where
    ctx = reportContext report
    dispositions = reportDispositions report
    rootLabel = if T.null (moduleRoot ctx) then "(none)" else moduleRoot ctx
    layoutLabel = case placement ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"
    names = [moduleNameOf (modulePath m) | (m, _) <- dispositions]
    nameWidth = maximum (1 : map T.length names)
    moduleLine (m, disposition) =
        "  " <> kindTag (kind m) <> "  " <> pad (moduleNameOf (modulePath m)) <> "  " <> dispositionTag disposition
    kindTag Generated = "generated"
    kindTag HoleStub = "hole     "
    dispositionTag Overwritten = "(overwritten)"
    dispositionTag Created = "(created)"
    dispositionTag Skipped = "(skipped: already present)"
    pad name = name <> T.replicate (nameWidth - T.length name) " "
    generatedCount = length [() | (m, _) <- dispositions, kind m == Generated]
    harnesses =
        sortOn
            id
            [ moduleNameOf (modulePath m)
            | (m, _) <- dispositions
            , any (`T.isSuffixOf` moduleNameOf (modulePath m)) [".Harness", ".ProcessHarness", ".WorkflowFacts"]
            ]
    harnessLine = case harnesses of
        [] -> "harness:  (none emitted)"
        _ -> "harness:  run `cabal test <your-component>` over " <> T.unwords harnesses
    dependencyLine =
        "dependency plan: consumer packages "
            <> renderBracketed (consumerPackages (reportConsumerPlan report))
            <> ", consumer modules "
            <> renderBracketed (consumerModules (reportConsumerPlan report))
    constraintSection = case reportConstraintPlan report of
        [] -> []
        constraints -> "constraint plan:" : map ("  " <>) constraints
    newHolesSection = case reportNewHoles report of
        [] -> []
        obligations ->
            ["newly required holes since last scaffold: " <> tshow (length obligations)]
                <> concatMap obligationLines obligations
    obligationLines hole =
        [ "  " <> holeModule hole
        , "    " <> holeSignature hole <> " (" <> obligationKindLabel (holeKind hole) <> ")"
        ]
    previousSpecNote = case reportPreviousSpecPath report of
        Just previous
            | previous /= T.pack (reportSpecPath report) ->
                [ "note: the previous scaffold record used spec " <> previous
                , "      specs sharing context " <> contextName ctx <> " in one --out also share " <> T.pack (reportManifestPath report)
                ]
        _ -> []
    mappingDriftSection = case reportMappingDrift report of
        [] -> []
        drifts ->
            ["mapping drift: " <> tshow (length drifts) <> " declaration(s) changed since the previous scaffold:"]
                <> concatMap driftLines drifts
    driftLines drift =
        [ "  " <> driftSpecName drift
        , "    previous: " <> maybe "(absent)" renderMappingIdentity (driftPrevious drift)
        , "    current:  " <> maybe "(absent)" renderMappingIdentity (driftCurrent drift)
        ]
    staleSection = case reportStale report of
        [] -> []
        stale ->
            [ "stale: " <> tshow (length stale) <> " file(s) from a previous scaffold of context " <> contextName ctx <> " are no longer produced by this spec:"
            ]
                <> map staleLine stale
                <> ["note: keiro-dsl never deletes files."]
    staleLine stale = case staleKind stale of
        Generated -> "  generated " <> T.pack (stalePath stale) <> "  (safe to delete; still on disk)"
        HoleStub -> "  hole      " <> T.pack (stalePath stale) <> "  (hand-owned — review before deleting)"

obligationKindLabel :: BindingObligationKind -> Text
obligationKindLabel BindingValue = "binding"
obligationKindLabel FixtureValue = "fixtures"
obligationKindLabel InitialValue = "initial-value"

renderBracketed :: [Text] -> Text
renderBracketed values = "[" <> T.intercalate ", " values <> "]"

renderMappingIdentity :: MappingIdentity -> Text
renderMappingIdentity StructuralMapping{mappingPackage, mappingModule, mappingType, mappingBindingSymbol, mappingBindingVersion} =
    "structural "
        <> mappingPackage
        <> ":"
        <> mappingModule
        <> "."
        <> mappingType
        <> " binding="
        <> mappingBindingSymbol
        <> " version="
        <> mappingBindingVersion
renderMappingIdentity OpaqueMapping{mappingPackage, mappingModule, mappingType, mappingCodecIdentity, mappingCodecVersion} =
    "opaque "
        <> mappingPackage
        <> ":"
        <> mappingModule
        <> "."
        <> mappingType
        <> " codec="
        <> mappingCodecIdentity
        <> " version="
        <> mappingCodecVersion

tshow :: (Show a) => a -> Text
tshow = T.pack . show
