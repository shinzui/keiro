{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Reporting-only structural coverage over the checked mapped-type graph.
--
-- The report intentionally has no aggregate percentage. Private persisted event
-- payloads, mapped register cache boundaries, and queued-job history have
-- different authorities. Public contracts remain separately owned.
module Keiro.Dsl.Coverage
  ( CoverageSurface (..),
    CoverageMode (..),
    CoverageRoot (..),
    StructuralBoundary (..),
    OpaqueBoundary (..),
    JsonBoundary (..),
    SnapshotBoundary (..),
    UnsupportedSurface (..),
    CoverageCounts (..),
    CoverageSummary (..),
    CoverageFinding (..),
    CoveragePrevious (..),
    CoverageDelta (..),
    CoverageReport (..),
    coverageReport,
    coverageReportForService,
    coverageDiffReport,
    failOnOpaque,
    failOnOpaqueIncrease,
    coverageSucceeded,
    renderCoverageSummary,
    renderCoverageFinding,
    coverageFindingMessage,
    writeCoverageReport,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.SemanticContract (CheckedService, checkedSpec, checkedTypeGraph, legacyCheckedService)
import Keiro.Dsl.SemanticImpact
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (DiagnosticCode (..), Severity (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

data CoverageSurface
  = AggregateCommandPayload
  | PrivateEventPayload
  | SnapshotRegister
  | WorkqueuePayload
  | ReadModelQueryInput
  | ReadModelQueryResult
  | ProjectionTypedConsumer
  deriving stock (Eq, Ord, Show)

data CoverageMode = StructuralCoverage | OpaqueCoverage
  deriving stock (Eq, Ord, Show)

data CoverageRoot = CoverageRoot
  { surface :: !CoverageSurface,
    consumer :: !Text,
    path :: !Text,
    mappedType :: !Text,
    mode :: !CoverageMode,
    canonicalType :: !(Maybe Text),
    codecIdentity :: !(Maybe Text),
    codecVersion :: !(Maybe Text),
    wireFingerprint :: !Text
  }
  deriving stock (Eq, Ord, Show)

data StructuralBoundary = StructuralBoundary
  { root :: !Text,
    path :: !Text,
    mappedType :: !Text,
    canonicalType :: !Text,
    wireFingerprint :: !Text
  }
  deriving stock (Eq, Ord, Show)

data OpaqueBoundary = OpaqueBoundary
  { root :: !Text,
    path :: !Text,
    mappedType :: !Text,
    codecIdentity :: !Text,
    codecVersion :: !Text
  }
  deriving stock (Eq, Ord, Show)

data JsonBoundary = JsonBoundary
  { surface :: !CoverageSurface,
    root :: !Text,
    path :: !Text
  }
  deriving stock (Eq, Ord, Show)

data SnapshotBoundary = SnapshotBoundary
  { root :: !Text,
    aggregate :: !Text,
    register :: !Text,
    mappedType :: !Text,
    mode :: !CoverageMode,
    encoding :: !Text,
    invalidation :: !Text,
    wireFingerprint :: !Text,
    enabled :: !Bool
  }
  deriving stock (Eq, Ord, Show)

data UnsupportedSurface = UnsupportedSurface
  { surface :: !Text,
    support :: !Text,
    reason :: !Text
  }
  deriving stock (Eq, Ord, Show)

data CoverageCounts = CoverageCounts
  { totalRoots :: !Int,
    structuralRoots :: !Int,
    opaqueRoots :: !Int,
    jsonBoundaries :: !Int
  }
  deriving stock (Eq, Show)

data CoverageSummary = CoverageSummary
  { aggregateCommandPayloads :: !CoverageCounts,
    privateEventPayloads :: !CoverageCounts,
    snapshotRegisters :: !CoverageCounts,
    workqueuePayloads :: !CoverageCounts,
    readModelQueryInputs :: !CoverageCounts,
    readModelQueryResults :: !CoverageCounts,
    projectionTypedConsumers :: !CoverageCounts
  }
  deriving stock (Eq, Show)

data CoverageFinding = CoverageFinding
  { severity :: !Severity,
    code :: !DiagnosticCode,
    roots :: ![Text],
    message :: !Text
  }
  deriving stock (Eq, Show)

data CoveragePrevious = CoveragePrevious
  { reference :: !Text,
    summary :: !CoverageSummary,
    opaqueBoundaries :: ![OpaqueBoundary]
  }
  deriving stock (Eq, Show)

data CoverageDelta = CoverageDelta
  { aggregateCommandRootDelta :: !Int,
    privateEventRootDelta :: !Int,
    snapshotRegisterRootDelta :: !Int,
    workqueuePayloadRootDelta :: !Int,
    readModelQueryInputRootDelta :: !Int,
    readModelQueryResultRootDelta :: !Int,
    projectionTypedConsumerRootDelta :: !Int,
    opaqueBoundaryDelta :: !Int,
    addedOpaqueBoundaries :: ![OpaqueBoundary],
    removedOpaqueBoundaries :: ![OpaqueBoundary]
  }
  deriving stock (Eq, Show)

data CoverageReport = CoverageReport
  { spec :: !FilePath,
    roots :: ![CoverageRoot],
    structuralBoundaries :: ![StructuralBoundary],
    opaqueBoundaries :: ![OpaqueBoundary],
    jsonBoundaries :: ![JsonBoundary],
    snapshotBoundaries :: ![SnapshotBoundary],
    unsupportedSurfaces :: ![UnsupportedSurface],
    summary :: !CoverageSummary,
    findings :: ![CoverageFinding],
    previous :: !(Maybe CoveragePrevious),
    delta :: !(Maybe CoverageDelta)
  }
  deriving stock (Eq, Show)

coverageReport :: FilePath -> Spec -> Either (NonEmpty TypeGraphError) CoverageReport
coverageReport specPath = coverageReportForService specPath . legacyCheckedService

coverageReportForService :: FilePath -> CheckedService -> Either (NonEmpty TypeGraphError) CoverageReport
coverageReportForService specPath service = do
  graph <- checkedTypeGraph service
  let spec = checkedSpec service
  let impact = semanticImpact graph
      roots = sortOn (\root -> ((.path) root, (.consumer) root, (.surface) root)) (map (coverageRoot graph) ((.roots) impact))
      structural = structuralBoundaryInventory graph
      opaque = opaqueBoundaryInventory graph
      json = sortOn (.path) (jsonBoundaryInventory graph <> queueExplicitJsonBoundaries spec)
      snapshots = snapshotBoundaryInventory spec graph
      summary = summarize roots json
      findings = opaqueSurfaceFindings opaque
  pure
    CoverageReport
      { spec = specPath,
        roots = roots,
        structuralBoundaries = structural,
        opaqueBoundaries = opaque,
        jsonBoundaries = json,
        snapshotBoundaries = snapshots,
        unsupportedSurfaces = unsupportedInventory graph,
        summary = summary,
        findings = findings,
        previous = Nothing,
        delta = Nothing
      }

coverageDiffReport :: FilePath -> Text -> Spec -> Spec -> Either (NonEmpty TypeGraphError) CoverageReport
coverageDiffReport specPath reference oldSpec newSpec = do
  oldReport <- coverageReport (T.unpack reference <> ":" <> specPath) oldSpec
  newReport <- coverageReport specPath newSpec
  let oldOpaque = Set.fromList ((.opaqueBoundaries) oldReport)
      newOpaque = Set.fromList ((.opaqueBoundaries) newReport)
      added = Set.toAscList (newOpaque `Set.difference` oldOpaque)
      removed = Set.toAscList (oldOpaque `Set.difference` newOpaque)
      oldSummary = (.summary) oldReport
      newSummary = (.summary) newReport
      delta =
        CoverageDelta
          { aggregateCommandRootDelta = (.totalRoots) ((.aggregateCommandPayloads) newSummary) - (.totalRoots) ((.aggregateCommandPayloads) oldSummary),
            privateEventRootDelta = (.totalRoots) ((.privateEventPayloads) newSummary) - (.totalRoots) ((.privateEventPayloads) oldSummary),
            snapshotRegisterRootDelta = (.totalRoots) ((.snapshotRegisters) newSummary) - (.totalRoots) ((.snapshotRegisters) oldSummary),
            workqueuePayloadRootDelta = (.totalRoots) ((.workqueuePayloads) newSummary) - (.totalRoots) ((.workqueuePayloads) oldSummary),
            readModelQueryInputRootDelta = (.totalRoots) ((.readModelQueryInputs) newSummary) - (.totalRoots) ((.readModelQueryInputs) oldSummary),
            readModelQueryResultRootDelta = (.totalRoots) ((.readModelQueryResults) newSummary) - (.totalRoots) ((.readModelQueryResults) oldSummary),
            projectionTypedConsumerRootDelta = (.totalRoots) ((.projectionTypedConsumers) newSummary) - (.totalRoots) ((.projectionTypedConsumers) oldSummary),
            opaqueBoundaryDelta = length added - length removed,
            addedOpaqueBoundaries = added,
            removedOpaqueBoundaries = removed
          }
      addedFindings =
        [ CoverageFinding
            { severity = Warning,
              code = CoverageOpaqueBoundaryAdded,
              roots = [(.root) boundary],
              message = "opaque boundary added at " <> (.path) boundary
            }
        | boundary <- added
        ]
  pure $
    replaceCoverageReportComparison
      (newReport.findings <> addedFindings)
      ( Just
          CoveragePrevious
            { reference = reference,
              summary = oldSummary,
              opaqueBoundaries = oldReport.opaqueBoundaries
            }
      )
      (Just delta)
      newReport

failOnOpaque :: CoverageReport -> CoverageReport
failOnOpaque report
  | null boundaries = report
  | otherwise = replaceCoverageReportFindings (report.findings <> [gateFinding "opaque persisted boundaries are forbidden by --fail-on-opaque" boundaries]) report
  where
    boundaries = (.opaqueBoundaries) report

failOnOpaqueIncrease :: CoverageReport -> CoverageReport
failOnOpaqueIncrease report = case (.delta) report of
  Just delta
    | not (null ((.addedOpaqueBoundaries) delta)) ->
        replaceCoverageReportFindings
          (report.findings <> [gateFinding "new opaque persisted boundaries are forbidden by --fail-on-opaque-increase" delta.addedOpaqueBoundaries])
          report
  _ -> report

replaceCoverageReportFindings :: [CoverageFinding] -> CoverageReport -> CoverageReport
replaceCoverageReportFindings findings report =
  replaceCoverageReportComparison findings report.previous report.delta report

replaceCoverageReportComparison :: [CoverageFinding] -> Maybe CoveragePrevious -> Maybe CoverageDelta -> CoverageReport -> CoverageReport
replaceCoverageReportComparison findings previous delta report =
  CoverageReport
    { spec = report.spec,
      roots = report.roots,
      structuralBoundaries = report.structuralBoundaries,
      opaqueBoundaries = report.opaqueBoundaries,
      jsonBoundaries = report.jsonBoundaries,
      snapshotBoundaries = report.snapshotBoundaries,
      unsupportedSurfaces = report.unsupportedSurfaces,
      summary = report.summary,
      findings,
      previous,
      delta
    }

coverageSucceeded :: CoverageReport -> Bool
coverageSucceeded = all ((/= Error) . (.severity)) . (.findings)

renderCoverageSummary :: CoverageReport -> Text
renderCoverageSummary report =
  T.unlines
    [ "structural/opaque boundaries (reporting only):",
      "  aggregate-command-payloads: " <> renderCounts ((.aggregateCommandPayloads) summary) <> "; encoding=consumer-build-only",
      "  private-event-payloads: " <> renderCounts ((.privateEventPayloads) summary),
      "  snapshot-registers: " <> renderCounts ((.snapshotRegisters) summary) <> "; encoding=consumer-json-cache; invalidation=tracked",
      "  queue-payloads: " <> renderCounts ((.workqueuePayloads) summary) <> "; encoding=queue-envelope-v1; migration=drain-or-transitional-codec",
      "  read-model-query-inputs: " <> renderCounts ((.readModelQueryInputs) summary) <> "; encoding=generated-haskell-api",
      "  read-model-query-results: " <> renderCounts ((.readModelQueryResults) summary) <> "; encoding=generated-haskell-api",
      "  projection-typed-consumers: " <> renderCounts ((.projectionTypedConsumers) summary) <> "; encoding=inherited-event-source",
      "  public-contracts: not-applicable (separately owned grammar)"
    ]
  where
    summary = (.summary) report
    renderCounts counts =
      T.pack (show ((.totalRoots) counts))
        <> " mapped roots ("
        <> T.pack (show ((.structuralRoots) counts))
        <> " structural, "
        <> T.pack (show ((.opaqueRoots) counts))
        <> " opaque, "
        <> T.pack (show ((.jsonBoundaries) counts))
        <> " Json boundaries)"

renderCoverageFinding :: FilePath -> CoverageFinding -> Text
renderCoverageFinding specPath finding =
  T.pack specPath
    <> ":0: "
    <> severityText ((.severity) finding)
    <> "["
    <> T.pack (show ((.code) finding))
    <> "]: "
    <> coverageFindingMessage finding
  where
    severityText Error = "error"
    severityText Warning = "warning"

-- | The finding's message with its root list appended, shared by the rendered
-- stderr line and the machine check-report entry so both say the same thing.
coverageFindingMessage :: CoverageFinding -> Text
coverageFindingMessage finding = (.message) finding <> rootsSuffix
  where
    rootsSuffix = case (.roots) finding of
      [] -> ""
      roots -> " (roots: " <> T.intercalate ", " roots <> ")"

writeCoverageReport :: FilePath -> CoverageReport -> IO ()
writeCoverageReport path report = do
  createDirectoryIfMissing True (takeDirectory path)
  Aeson.encodeFile path report

persistedSites :: TypeGraph -> [UseSite]
persistedSites = filter isPersisted . (.useSites)
  where
    isPersisted RootEventField {} = True
    isPersisted RootRegister {} = True
    isPersisted RootCommandField {} = False
    isPersisted RootWorkqueueField {} = True
    isPersisted RootReadModelQueryInput {} = False
    isPersisted RootReadModelQueryResult {} = False

coverageRoot :: TypeGraph -> MappedRoot -> CoverageRoot
coverageRoot graph mappedRoot =
  let site = (.useSite) mappedRoot
      key = (.declaration) mappedRoot
      path = renderUsePath (UsePath site (useSiteSegments graph site))
      fingerprint = wireFingerprint graph (unMappedKey key)
   in case Map.lookup key ((.declarations) graph) of
        Just (ResolvedStructural declaration _) ->
          CoverageRoot
            { surface = rootKindSurface ((.kind) mappedRoot),
              consumer = mappedConsumerIdentity ((.consumer) mappedRoot),
              path = path,
              mappedType = unMappedKey key,
              mode = StructuralCoverage,
              canonicalType = Just (unCanonicalTypeId ((.canonical) declaration)),
              codecIdentity = Nothing,
              codecVersion = Nothing,
              wireFingerprint = fingerprint
            }
        Just (ResolvedOpaque declaration) ->
          CoverageRoot
            { surface = rootKindSurface ((.kind) mappedRoot),
              consumer = mappedConsumerIdentity ((.consumer) mappedRoot),
              path = path,
              mappedType = unMappedKey key,
              mode = OpaqueCoverage,
              canonicalType = Nothing,
              codecIdentity = Just (unCodecIdentity ((.codecIdentity) declaration)),
              codecVersion = Just (unCodecVersion ((.codecVersion) declaration)),
              wireFingerprint = fingerprint
            }
        Nothing -> error "coverageRoot: resolved use-site key missing from graph"

structuralBoundaryInventory :: TypeGraph -> [StructuralBoundary]
structuralBoundaryInventory graph =
  sortOn
    (.path)
    [ StructuralBoundary
        { root = rootText ((.root) path),
          path = renderUsePath path,
          mappedType = (.name) declaration,
          canonicalType = unCanonicalTypeId ((.canonical) declaration),
          wireFingerprint = wireFingerprint graph ((.name) declaration)
        }
    | ResolvedStructural declaration _ <- Map.elems ((.declarations) graph),
      path <- usePaths graph ((.name) declaration),
      isWireSite ((.root) path)
    ]

opaqueBoundaryInventory :: TypeGraph -> [OpaqueBoundary]
opaqueBoundaryInventory graph =
  sortOn
    (.path)
    [ OpaqueBoundary
        { root = rootText ((.root) path),
          path = renderUsePath path,
          mappedType = (.name) declaration,
          codecIdentity = unCodecIdentity ((.codecIdentity) declaration),
          codecVersion = unCodecVersion ((.codecVersion) declaration)
        }
    | ResolvedOpaque declaration <- Map.elems ((.declarations) graph),
      path <- usePaths graph ((.name) declaration),
      isWireSite ((.root) path)
    ]

jsonBoundaryInventory :: TypeGraph -> [JsonBoundary]
jsonBoundaryInventory graph =
  sortOn
    (.path)
    [ boundary site completeSegments
    | site <- persistedSites graph,
      isWireSite site,
      segments <- jsonPathsFromDecl graph Set.empty (useSiteKey site),
      let completeSegments = useSiteSegments graph site <> segments
    ]
  where
    boundary site segments =
      JsonBoundary
        { surface = useSiteSurface site,
          root = rootText site,
          path = renderUsePath (UsePath site segments)
        }

queueExplicitJsonBoundaries :: Spec -> [JsonBoundary]
queueExplicitJsonBoundaries spec =
  [ JsonBoundary
      { surface = WorkqueuePayload,
        root = root,
        path = root <> renderSegments segments
      }
  | NWorkqueue workqueue <- (.nodes) spec,
    field <- (.payload) workqueue,
    TypedQueueExpression expression <- [(.valueType) field],
    segments <- explicitJsonPaths expression,
    let root = "workqueue " <> (.name) workqueue <> " payload ." <> (.name) field
  ]
  where
    explicitJsonPaths TJson = [[]]
    explicitJsonPaths (TOptional value) = map (SegOptional :) (explicitJsonPaths value)
    explicitJsonPaths (TList value) = map (SegElem :) (explicitJsonPaths value)
    explicitJsonPaths (TMap value) = map (SegMapValue :) (explicitJsonPaths value)
    explicitJsonPaths _ = []
    renderSegments = T.concat . map renderSegment
    renderSegment SegOptional = " optional"
    renderSegment SegElem = " []"
    renderSegment SegMapValue = " {}"
    renderSegment (SegField name key)
      | name == key = " ." <> name
      | otherwise = " ." <> name <> " as " <> T.pack (show key)
    renderSegment (SegArm _ tag) = " arm " <> T.pack (show tag)
    renderSegment (SegDecl name) = " : " <> name

snapshotBoundaryInventory :: Spec -> TypeGraph -> [SnapshotBoundary]
snapshotBoundaryInventory spec graph =
  sortOn
    (.root)
    [ SnapshotBoundary
        { root = renderUsePath (UsePath site []),
          aggregate = aggregate,
          register = register,
          mappedType = unMappedKey key,
          mode = declarationMode declaration,
          encoding = "consumer-json-cache",
          invalidation = "tracked-by-mapped-wire-fingerprint",
          wireFingerprint = wireFingerprint graph (unMappedKey key),
          enabled = aggregateHasSnapshot aggregate
        }
    | site@(RootRegister aggregate register key) <- persistedSites graph,
      Just declaration <- [Map.lookup key ((.declarations) graph)]
    ]
  where
    aggregateHasSnapshot name =
      any
        (\case NAggregate aggregate -> (.name) aggregate == name && maybe False (const True) ((.snapshot) aggregate); _ -> False)
        ((.nodes) spec)

jsonPathsFromDecl :: TypeGraph -> Set.Set MappedKey -> MappedKey -> [[PathSeg]]
jsonPathsFromDecl graph visited key
  | key `Set.member` visited = []
  | otherwise = case Map.lookup key ((.declarations) graph) of
      Nothing -> []
      Just declaration ->
        foldMappedDecl
          MappedDeclAlgebra
            { onStructuralDecl = \_ shape -> jsonPathsFromShape graph (Set.insert key visited) shape,
              onOpaqueDecl = const []
            }
          declaration

jsonPathsFromShape :: TypeGraph -> Set.Set MappedKey -> ResolvedMappedShape -> [[PathSeg]]
jsonPathsFromShape graph visited =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields ->
          concat
            [ map (SegField ((.haskell) field) ((.key) field) :) (jsonPathsFromExpr graph visited ((.valueType) field))
            | field <- fields
            ],
        onEnum = const [],
        onUnion = \_ arms ->
          concat
            [ map (SegArm ((.ctor) arm) ((.tag) arm) :) (maybe [] (jsonPathsFromExpr graph visited) ((.payload) arm))
            | arm <- arms
            ]
      }

jsonPathsFromExpr :: TypeGraph -> Set.Set MappedKey -> ResolvedTypeExpr -> [[PathSeg]]
jsonPathsFromExpr graph visited =
  foldTypeExpr
    TypeExprAlgebra
      { onText = [],
        onInt = [],
        onInteger = [],
        onBool = [],
        onNatural = [],
        onTime = [],
        onJson = [[]],
        onOptional = map (SegOptional :),
        onList = map (SegElem :),
        onMap = map (SegMapValue :),
        onRef = \key -> map (SegDecl (unMappedKey key) :) (jsonPathsFromDecl graph visited key)
      }

summarize :: [CoverageRoot] -> [JsonBoundary] -> CoverageSummary
summarize roots json =
  CoverageSummary
    { aggregateCommandPayloads = countsFor AggregateCommandPayload,
      privateEventPayloads = countsFor PrivateEventPayload,
      snapshotRegisters = countsFor SnapshotRegister,
      workqueuePayloads = countsFor WorkqueuePayload,
      readModelQueryInputs = countsFor ReadModelQueryInput,
      readModelQueryResults = countsFor ReadModelQueryResult,
      projectionTypedConsumers = countsFor ProjectionTypedConsumer
    }
  where
    countsFor surface =
      let matching = filter ((== surface) . (.surface)) roots
          jsonCount = length (filter ((== surface) . (.surface)) json)
       in CoverageCounts
            { totalRoots = length matching,
              structuralRoots = length (filter ((== StructuralCoverage) . (.mode)) matching),
              opaqueRoots = length (filter ((== OpaqueCoverage) . (.mode)) matching),
              jsonBoundaries = jsonCount
            }

opaqueSurfaceFindings :: [OpaqueBoundary] -> [CoverageFinding]
opaqueSurfaceFindings boundaries =
  [ CoverageFinding
      { severity = Warning,
        code = CoverageOpaqueSurface,
        roots = [root],
        message = "persisted mapped root contains opaque mapped boundaries"
      }
  | root <- Set.toAscList (Set.fromList (map (.root) boundaries))
  ]

gateFinding :: Text -> [OpaqueBoundary] -> CoverageFinding
gateFinding message boundaries =
  CoverageFinding
    { severity = Error,
      code = CoverageOpaqueGateExceeded,
      roots = Set.toAscList (Set.fromList (map (.root) boundaries)),
      message = message
    }

unsupportedInventory :: TypeGraph -> [UnsupportedSurface]
unsupportedInventory graph =
  [ UnsupportedSurface
      { surface = "public-contracts",
        support = "not-applicable",
        reason = "public contracts have a separately owned grammar and compatibility surface"
      }
  ]
    <> [ UnsupportedSurface
           { surface = unsupportedProjectionIdentity boundary,
             support = "operational-only",
             reason = "heterogeneous projection sources have no single generated event type or mapped declaration root"
           }
       | boundary <- (.unsupportedProjectionSources) graph
       ]
  where
    unsupportedProjectionIdentity (UnsupportedCatalogCategory owner categoryName) = "projection-category:" <> owner <> ":" <> categoryName
    unsupportedProjectionIdentity (UnsupportedCatalogAll owner) = "projection-all:" <> owner

useSiteKey :: UseSite -> MappedKey
useSiteKey (RootCommandField _ _ _ key) = key
useSiteKey (RootEventField _ _ _ key) = key
useSiteKey (RootRegister _ _ key) = key
useSiteKey (RootWorkqueueField _ _ key) = key
useSiteKey (RootReadModelQueryInput _ key) = key
useSiteKey (RootReadModelQueryResult _ key) = key

useSiteSurface :: UseSite -> CoverageSurface
useSiteSurface RootCommandField {} = AggregateCommandPayload
useSiteSurface RootEventField {} = PrivateEventPayload
useSiteSurface RootRegister {} = SnapshotRegister
useSiteSurface RootWorkqueueField {} = WorkqueuePayload
useSiteSurface RootReadModelQueryInput {} = ReadModelQueryInput
useSiteSurface RootReadModelQueryResult {} = ReadModelQueryResult

rootKindSurface :: MappedRootKind -> CoverageSurface
rootKindSurface MappedCommandFieldRoot = AggregateCommandPayload
rootKindSurface MappedEventFieldRoot = PrivateEventPayload
rootKindSurface MappedRegisterRoot = SnapshotRegister
rootKindSurface MappedWorkqueueFieldRoot = WorkqueuePayload
rootKindSurface MappedReadModelQueryInputRoot = ReadModelQueryInput
rootKindSurface MappedReadModelQueryResultRoot = ReadModelQueryResult
rootKindSurface MappedRouterSelectionQueryInputRoot = ReadModelQueryInput
rootKindSurface MappedRouterSelectionPredicateRoot = ReadModelQueryResult
rootKindSurface MappedRouterSelectionRecipientRoot = ReadModelQueryResult
rootKindSurface MappedRouterSelectionCommandFieldRoot = ReadModelQueryResult
rootKindSurface MappedProjectionEventRoot = ProjectionTypedConsumer

isWireSite :: UseSite -> Bool
isWireSite RootEventField {} = True
isWireSite RootWorkqueueField {} = True
isWireSite RootRegister {} = False
isWireSite RootCommandField {} = False
isWireSite RootReadModelQueryInput {} = False
isWireSite RootReadModelQueryResult {} = False

rootText :: UseSite -> Text
rootText site = renderUsePath (UsePath site [])

declarationMode :: ResolvedMappedDecl -> CoverageMode
declarationMode =
  foldMappedDecl
    MappedDeclAlgebra
      { onStructuralDecl = \_ _ -> StructuralCoverage,
        onOpaqueDecl = const OpaqueCoverage
      }

instance ToJSON CoverageSurface where
  toJSON AggregateCommandPayload = toJSON ("aggregate-command-payload" :: Text)
  toJSON PrivateEventPayload = toJSON ("private-event-payload" :: Text)
  toJSON SnapshotRegister = toJSON ("snapshot-register" :: Text)
  toJSON WorkqueuePayload = toJSON ("workqueue-payload" :: Text)
  toJSON ReadModelQueryInput = toJSON ("read-model-query-input" :: Text)
  toJSON ReadModelQueryResult = toJSON ("read-model-query-result" :: Text)
  toJSON ProjectionTypedConsumer = toJSON ("projection-typed-consumer" :: Text)

instance ToJSON CoverageMode where
  toJSON StructuralCoverage = toJSON ("structural" :: Text)
  toJSON OpaqueCoverage = toJSON ("opaque" :: Text)

instance ToJSON CoverageRoot where
  toJSON root =
    object
      [ "surface" .= (.surface) root,
        "consumer" .= (.consumer) root,
        "path" .= (.path) root,
        "mappedType" .= (.mappedType) root,
        "mode" .= (.mode) root,
        "canonicalType" .= (.canonicalType) root,
        "codecIdentity" .= (.codecIdentity) root,
        "codecVersion" .= (.codecVersion) root,
        "wireFingerprint" .= (.wireFingerprint) root
      ]

instance ToJSON StructuralBoundary where
  toJSON boundary =
    object
      [ "root" .= (.root) boundary,
        "path" .= (.path) boundary,
        "mappedType" .= (.mappedType) boundary,
        "canonicalType" .= (.canonicalType) boundary,
        "wireFingerprint" .= (.wireFingerprint) boundary
      ]

instance ToJSON OpaqueBoundary where
  toJSON boundary =
    object
      [ "root" .= (.root) boundary,
        "path" .= (.path) boundary,
        "mappedType" .= (.mappedType) boundary,
        "codecIdentity" .= (.codecIdentity) boundary,
        "codecVersion" .= (.codecVersion) boundary
      ]

instance ToJSON JsonBoundary where
  toJSON boundary = object ["surface" .= (.surface) boundary, "root" .= (.root) boundary, "path" .= (.path) boundary]

instance ToJSON SnapshotBoundary where
  toJSON boundary =
    object
      [ "root" .= (.root) boundary,
        "aggregate" .= (.aggregate) boundary,
        "register" .= (.register) boundary,
        "mappedType" .= (.mappedType) boundary,
        "mode" .= (.mode) boundary,
        "snapshotEncoding" .= (.encoding) boundary,
        "invalidation" .= (.invalidation) boundary,
        "wireFingerprint" .= (.wireFingerprint) boundary,
        "snapshotEnabled" .= (.enabled) boundary
      ]

instance ToJSON UnsupportedSurface where
  toJSON surface =
    object
      [ "surface" .= (.surface) surface,
        "support" .= (.support) surface,
        "reason" .= (.reason) surface
      ]

instance ToJSON CoverageCounts where
  toJSON counts =
    object
      [ "totalRoots" .= (.totalRoots) counts,
        "structuralRoots" .= (.structuralRoots) counts,
        "opaqueRoots" .= (.opaqueRoots) counts,
        "jsonBoundaries" .= (.jsonBoundaries) counts
      ]

instance ToJSON CoverageSummary where
  toJSON summary =
    object
      [ "aggregateCommandPayloads" .= (.aggregateCommandPayloads) summary,
        "privateEventPayloads" .= (.privateEventPayloads) summary,
        "snapshotRegisters" .= (.snapshotRegisters) summary,
        "workqueuePayloads" .= (.workqueuePayloads) summary,
        "readModelQueryInputs" .= (.readModelQueryInputs) summary,
        "readModelQueryResults" .= (.readModelQueryResults) summary,
        "projectionTypedConsumers" .= (.projectionTypedConsumers) summary
      ]

instance ToJSON CoverageFinding where
  toJSON finding =
    object
      [ "severity" .= severityValue ((.severity) finding),
        "code" .= show ((.code) finding),
        "roots" .= (.roots) finding,
        "message" .= (.message) finding
      ]
    where
      -- One severity vocabulary across every keiro-dsl JSON report. The check
      -- report has always spelled this "warning"; coverage spelled the same
      -- severity "advisory" until ExecPlan 199 unified them.
      severityValue Error = "error" :: Text
      severityValue Warning = "warning"

instance ToJSON CoveragePrevious where
  toJSON previous =
    object
      [ "reference" .= (.reference) previous,
        "summary" .= (.summary) previous,
        "opaqueBoundaries" .= (.opaqueBoundaries) previous
      ]

instance ToJSON CoverageDelta where
  toJSON delta =
    object
      [ "aggregateCommandRootDelta" .= (.aggregateCommandRootDelta) delta,
        "privateEventRootDelta" .= (.privateEventRootDelta) delta,
        "snapshotRegisterRootDelta" .= (.snapshotRegisterRootDelta) delta,
        "workqueuePayloadRootDelta" .= (.workqueuePayloadRootDelta) delta,
        "readModelQueryInputRootDelta" .= (.readModelQueryInputRootDelta) delta,
        "readModelQueryResultRootDelta" .= (.readModelQueryResultRootDelta) delta,
        "projectionTypedConsumerRootDelta" .= (.projectionTypedConsumerRootDelta) delta,
        "opaqueBoundaryDelta" .= (.opaqueBoundaryDelta) delta,
        "addedOpaqueBoundaries" .= (.addedOpaqueBoundaries) delta,
        "removedOpaqueBoundaries" .= (.removedOpaqueBoundaries) delta
      ]

instance ToJSON CoverageReport where
  toJSON report =
    object
      [ "schema" .= ("keiro-dsl/coverage-report/1" :: Text),
        "spec" .= (.spec) report,
        "roots" .= (.roots) report,
        "structuralBoundaries" .= (.structuralBoundaries) report,
        "opaqueBoundaries" .= (.opaqueBoundaries) report,
        "jsonBoundaries" .= (.jsonBoundaries) report,
        "snapshotBoundaries" .= (.snapshotBoundaries) report,
        "unsupportedSurfaces" .= (.unsupportedSurfaces) report,
        "summary" .= (.summary) report,
        "findings" .= (.findings) report,
        "previous" .= (.previous) report,
        "delta" .= (.delta) report
      ]
