{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

{- | Reporting-only structural coverage over the checked mapped-type graph.

The report intentionally has no aggregate percentage. Private persisted event
payloads and mapped register cache boundaries have different authorities, and
queue/public-contract payloads are not represented by this graph at all.
-}
module Keiro.Dsl.Coverage (
    CoverageSurface (..),
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
    coverageDiffReport,
    failOnOpaque,
    failOnOpaqueIncrease,
    coverageSucceeded,
    renderCoverageSummary,
    renderCoverageFinding,
    writeCoverageReport,
) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (DiagnosticCode (..), Severity (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

data CoverageSurface = PrivateEventPayload | SnapshotRegister
    deriving stock (Eq, Ord, Show)

data CoverageMode = StructuralCoverage | OpaqueCoverage
    deriving stock (Eq, Ord, Show)

data CoverageRoot = CoverageRoot
    { rootSurface :: !CoverageSurface
    , rootPath :: !Text
    , rootMappedType :: !Text
    , rootMode :: !CoverageMode
    , rootCanonicalType :: !(Maybe Text)
    , rootCodecIdentity :: !(Maybe Text)
    , rootCodecVersion :: !(Maybe Text)
    , rootWireFingerprint :: !Text
    }
    deriving stock (Eq, Ord, Show)

data StructuralBoundary = StructuralBoundary
    { structuralRoot :: !Text
    , structuralPath :: !Text
    , structuralMappedType :: !Text
    , structuralCanonicalType :: !Text
    , structuralWireFingerprint :: !Text
    }
    deriving stock (Eq, Ord, Show)

data OpaqueBoundary = OpaqueBoundary
    { opaqueRoot :: !Text
    , opaquePath :: !Text
    , opaqueMappedType :: !Text
    , opaqueCodecIdentity :: !Text
    , opaqueCodecVersion :: !Text
    }
    deriving stock (Eq, Ord, Show)

data JsonBoundary = JsonBoundary
    { jsonRoot :: !Text
    , jsonPath :: !Text
    }
    deriving stock (Eq, Ord, Show)

data SnapshotBoundary = SnapshotBoundary
    { snapshotRoot :: !Text
    , snapshotAggregate :: !Text
    , snapshotRegister :: !Text
    , snapshotMappedType :: !Text
    , snapshotMode :: !CoverageMode
    , snapshotEncoding :: !Text
    , snapshotInvalidation :: !Text
    , snapshotWireFingerprint :: !Text
    , snapshotEnabled :: !Bool
    }
    deriving stock (Eq, Ord, Show)

data UnsupportedSurface = UnsupportedSurface
    { unsupportedSurface :: !Text
    , unsupportedSupport :: !Text
    , unsupportedReason :: !Text
    }
    deriving stock (Eq, Ord, Show)

data CoverageCounts = CoverageCounts
    { totalRoots :: !Int
    , structuralRoots :: !Int
    , opaqueRoots :: !Int
    , jsonBoundaries :: !Int
    }
    deriving stock (Eq, Show)

data CoverageSummary = CoverageSummary
    { privateEventPayloads :: !CoverageCounts
    , snapshotRegisters :: !CoverageCounts
    }
    deriving stock (Eq, Show)

data CoverageFinding = CoverageFinding
    { findingSeverity :: !Severity
    , findingCode :: !DiagnosticCode
    , findingRoots :: ![Text]
    , findingMessage :: !Text
    }
    deriving stock (Eq, Show)

data CoveragePrevious = CoveragePrevious
    { previousReference :: !Text
    , previousSummary :: !CoverageSummary
    , previousOpaqueBoundaries :: ![OpaqueBoundary]
    }
    deriving stock (Eq, Show)

data CoverageDelta = CoverageDelta
    { privateEventRootDelta :: !Int
    , snapshotRegisterRootDelta :: !Int
    , opaqueBoundaryDelta :: !Int
    , addedOpaqueBoundaries :: ![OpaqueBoundary]
    , removedOpaqueBoundaries :: ![OpaqueBoundary]
    }
    deriving stock (Eq, Show)

data CoverageReport = CoverageReport
    { coverageSpec :: !FilePath
    , coverageRoots :: ![CoverageRoot]
    , coverageStructuralBoundaries :: ![StructuralBoundary]
    , coverageOpaqueBoundaries :: ![OpaqueBoundary]
    , coverageJsonBoundaries :: ![JsonBoundary]
    , coverageSnapshotBoundaries :: ![SnapshotBoundary]
    , coverageUnsupportedSurfaces :: ![UnsupportedSurface]
    , coverageSummary :: !CoverageSummary
    , coverageFindings :: ![CoverageFinding]
    , coveragePrevious :: !(Maybe CoveragePrevious)
    , coverageDelta :: !(Maybe CoverageDelta)
    }
    deriving stock (Eq, Show)

coverageReport :: FilePath -> Spec -> Either (NonEmpty TypeGraphError) CoverageReport
coverageReport specPath spec = do
    graph <- resolveTypeGraph spec
    let roots = sortOn rootPath (map (coverageRoot graph) (persistedSites graph))
        structural = structuralBoundaryInventory graph
        opaque = opaqueBoundaryInventory graph
        json = jsonBoundaryInventory graph
        snapshots = snapshotBoundaryInventory spec graph
        summary = summarize roots json
        findings = opaqueSurfaceFindings opaque
    pure
        CoverageReport
            { coverageSpec = specPath
            , coverageRoots = roots
            , coverageStructuralBoundaries = structural
            , coverageOpaqueBoundaries = opaque
            , coverageJsonBoundaries = json
            , coverageSnapshotBoundaries = snapshots
            , coverageUnsupportedSurfaces = unsupportedInventory
            , coverageSummary = summary
            , coverageFindings = findings
            , coveragePrevious = Nothing
            , coverageDelta = Nothing
            }

coverageDiffReport :: FilePath -> Text -> Spec -> Spec -> Either (NonEmpty TypeGraphError) CoverageReport
coverageDiffReport specPath reference oldSpec newSpec = do
    oldReport <- coverageReport (T.unpack reference <> ":" <> specPath) oldSpec
    newReport <- coverageReport specPath newSpec
    let oldOpaque = Set.fromList (coverageOpaqueBoundaries oldReport)
        newOpaque = Set.fromList (coverageOpaqueBoundaries newReport)
        added = Set.toAscList (newOpaque `Set.difference` oldOpaque)
        removed = Set.toAscList (oldOpaque `Set.difference` newOpaque)
        oldSummary = coverageSummary oldReport
        newSummary = coverageSummary newReport
        delta =
            CoverageDelta
                { privateEventRootDelta = totalRoots (privateEventPayloads newSummary) - totalRoots (privateEventPayloads oldSummary)
                , snapshotRegisterRootDelta = totalRoots (snapshotRegisters newSummary) - totalRoots (snapshotRegisters oldSummary)
                , opaqueBoundaryDelta = length added - length removed
                , addedOpaqueBoundaries = added
                , removedOpaqueBoundaries = removed
                }
        addedFindings =
            [ CoverageFinding
                { findingSeverity = Warning
                , findingCode = CoverageOpaqueBoundaryAdded
                , findingRoots = [opaqueRoot boundary]
                , findingMessage = "opaque boundary added at " <> opaquePath boundary
                }
            | boundary <- added
            ]
    pure
        newReport
            { coverageFindings = coverageFindings newReport <> addedFindings
            , coveragePrevious =
                Just
                    CoveragePrevious
                        { previousReference = reference
                        , previousSummary = oldSummary
                        , previousOpaqueBoundaries = coverageOpaqueBoundaries oldReport
                        }
            , coverageDelta = Just delta
            }

failOnOpaque :: CoverageReport -> CoverageReport
failOnOpaque report
    | null boundaries = report
    | otherwise = report{coverageFindings = coverageFindings report <> [gateFinding "opaque persisted boundaries are forbidden by --fail-on-opaque" boundaries]}
  where
    boundaries = coverageOpaqueBoundaries report

failOnOpaqueIncrease :: CoverageReport -> CoverageReport
failOnOpaqueIncrease report = case coverageDelta report of
    Just delta
        | not (null (addedOpaqueBoundaries delta)) ->
            report
                { coverageFindings =
                    coverageFindings report
                        <> [gateFinding "new opaque persisted boundaries are forbidden by --fail-on-opaque-increase" (addedOpaqueBoundaries delta)]
                }
    _ -> report

coverageSucceeded :: CoverageReport -> Bool
coverageSucceeded = all ((/= Error) . findingSeverity) . coverageFindings

renderCoverageSummary :: CoverageReport -> Text
renderCoverageSummary report =
    T.unlines
        [ "structural/opaque boundaries (reporting only):"
        , "  private-event-payloads: " <> renderCounts (privateEventPayloads summary)
        , "  snapshot-registers: " <> renderCounts (snapshotRegisters summary) <> "; encoding=consumer-json-cache; invalidation=tracked"
        , "  queue-payloads: unsupported"
        , "  public-contracts: not-applicable (separately owned grammar)"
        ]
  where
    summary = coverageSummary report
    renderCounts counts =
        T.pack (show (totalRoots counts))
            <> " mapped roots ("
            <> T.pack (show (structuralRoots counts))
            <> " structural, "
            <> T.pack (show (opaqueRoots counts))
            <> " opaque, "
            <> T.pack (show (jsonBoundaries counts))
            <> " Json boundaries)"

renderCoverageFinding :: FilePath -> CoverageFinding -> Text
renderCoverageFinding specPath finding =
    T.pack specPath
        <> ":0: "
        <> severityText (findingSeverity finding)
        <> "["
        <> T.pack (show (findingCode finding))
        <> "]: "
        <> findingMessage finding
        <> rootsSuffix
  where
    severityText Error = "error"
    severityText Warning = "warning"
    rootsSuffix = case findingRoots finding of
        [] -> ""
        roots -> " (roots: " <> T.intercalate ", " roots <> ")"

writeCoverageReport :: FilePath -> CoverageReport -> IO ()
writeCoverageReport path report = do
    createDirectoryIfMissing True (takeDirectory path)
    Aeson.encodeFile path report

persistedSites :: TypeGraph -> [UseSite]
persistedSites = filter isPersisted . tgUseSites
  where
    isPersisted RootEventField{} = True
    isPersisted RootRegister{} = True
    isPersisted RootCommandField{} = False

coverageRoot :: TypeGraph -> UseSite -> CoverageRoot
coverageRoot graph site =
    let key = useSiteKey site
        path = renderUsePath (UsePath site [])
        fingerprint = wireFingerprint graph (unMappedKey key)
     in case Map.lookup key (tgDeclarations graph) of
            Just (ResolvedStructural declaration _) ->
                CoverageRoot
                    { rootSurface = useSiteSurface site
                    , rootPath = path
                    , rootMappedType = unMappedKey key
                    , rootMode = StructuralCoverage
                    , rootCanonicalType = Just (unCanonicalTypeId (sdCanonical declaration))
                    , rootCodecIdentity = Nothing
                    , rootCodecVersion = Nothing
                    , rootWireFingerprint = fingerprint
                    }
            Just (ResolvedOpaque declaration) ->
                CoverageRoot
                    { rootSurface = useSiteSurface site
                    , rootPath = path
                    , rootMappedType = unMappedKey key
                    , rootMode = OpaqueCoverage
                    , rootCanonicalType = Nothing
                    , rootCodecIdentity = Just (unCodecIdentity (odCodecIdentity declaration))
                    , rootCodecVersion = Just (unCodecVersion (odCodecVersion declaration))
                    , rootWireFingerprint = fingerprint
                    }
            Nothing -> error "coverageRoot: resolved use-site key missing from graph"

structuralBoundaryInventory :: TypeGraph -> [StructuralBoundary]
structuralBoundaryInventory graph =
    sortOn
        structuralPath
        [ StructuralBoundary
            { structuralRoot = rootText (upRoot path)
            , structuralPath = renderUsePath path
            , structuralMappedType = sdName declaration
            , structuralCanonicalType = unCanonicalTypeId (sdCanonical declaration)
            , structuralWireFingerprint = wireFingerprint graph (sdName declaration)
            }
        | ResolvedStructural declaration _ <- Map.elems (tgDeclarations graph)
        , path <- usePaths graph (sdName declaration)
        , isEventSite (upRoot path)
        ]

opaqueBoundaryInventory :: TypeGraph -> [OpaqueBoundary]
opaqueBoundaryInventory graph =
    sortOn
        opaquePath
        [ OpaqueBoundary
            { opaqueRoot = rootText (upRoot path)
            , opaquePath = renderUsePath path
            , opaqueMappedType = odName declaration
            , opaqueCodecIdentity = unCodecIdentity (odCodecIdentity declaration)
            , opaqueCodecVersion = unCodecVersion (odCodecVersion declaration)
            }
        | ResolvedOpaque declaration <- Map.elems (tgDeclarations graph)
        , path <- usePaths graph (odName declaration)
        , isEventSite (upRoot path)
        ]

jsonBoundaryInventory :: TypeGraph -> [JsonBoundary]
jsonBoundaryInventory graph =
    sortOn
        jsonPath
        [ JsonBoundary
            { jsonRoot = rootText site
            , jsonPath = renderUsePath (UsePath site segments)
            }
        | site <- persistedSites graph
        , isEventSite site
        , segments <- jsonPathsFromDecl graph Set.empty (useSiteKey site)
        ]

snapshotBoundaryInventory :: Spec -> TypeGraph -> [SnapshotBoundary]
snapshotBoundaryInventory spec graph =
    sortOn
        snapshotRoot
        [ SnapshotBoundary
            { snapshotRoot = renderUsePath (UsePath site [])
            , snapshotAggregate = aggregate
            , snapshotRegister = register
            , snapshotMappedType = unMappedKey key
            , snapshotMode = declarationMode declaration
            , snapshotEncoding = "consumer-json-cache"
            , snapshotInvalidation = "tracked-by-mapped-wire-fingerprint"
            , snapshotWireFingerprint = wireFingerprint graph (unMappedKey key)
            , snapshotEnabled = aggregateHasSnapshot aggregate
            }
        | site@(RootRegister aggregate register key) <- persistedSites graph
        , Just declaration <- [Map.lookup key (tgDeclarations graph)]
        ]
  where
    aggregateHasSnapshot name =
        any
            (\case NAggregate aggregate -> aggName aggregate == name && maybe False (const True) (aggSnapshot aggregate); _ -> False)
            (specNodes spec)

jsonPathsFromDecl :: TypeGraph -> Set.Set MappedKey -> MappedKey -> [[PathSeg]]
jsonPathsFromDecl graph visited key
    | key `Set.member` visited = []
    | otherwise = case Map.lookup key (tgDeclarations graph) of
        Nothing -> []
        Just declaration ->
            foldMappedDecl
                MappedDeclAlgebra
                    { onStructuralDecl = \_ shape -> jsonPathsFromShape graph (Set.insert key visited) shape
                    , onOpaqueDecl = const []
                    }
                declaration

jsonPathsFromShape :: TypeGraph -> Set.Set MappedKey -> ResolvedMappedShape -> [[PathSeg]]
jsonPathsFromShape graph visited =
    foldMappedShape
        MappedShapeAlgebra
            { onRecord = \_ _ fields ->
                concat
                    [ map (SegField (rwfHaskell field) (rwfKey field) :) (jsonPathsFromExpr graph visited (rwfType field))
                    | field <- fields
                    ]
            , onEnum = const []
            , onUnion = \_ arms ->
                concat
                    [ map (SegArm (rwaCtor arm) (rwaTag arm) :) (maybe [] (jsonPathsFromExpr graph visited) (rwaPayload arm))
                    | arm <- arms
                    ]
            }

jsonPathsFromExpr :: TypeGraph -> Set.Set MappedKey -> ResolvedTypeExpr -> [[PathSeg]]
jsonPathsFromExpr graph visited =
    foldTypeExpr
        TypeExprAlgebra
            { onText = []
            , onInt = []
            , onBool = []
            , onNatural = []
            , onTime = []
            , onJson = [[]]
            , onOptional = map (SegOptional :)
            , onList = map (SegElem :)
            , onMap = map (SegMapValue :)
            , onRef = \key -> map (SegDecl (unMappedKey key) :) (jsonPathsFromDecl graph visited key)
            }

summarize :: [CoverageRoot] -> [JsonBoundary] -> CoverageSummary
summarize roots json =
    CoverageSummary
        { privateEventPayloads = countsFor PrivateEventPayload
        , snapshotRegisters = countsFor SnapshotRegister
        }
  where
    countsFor surface =
        let matching = filter ((== surface) . rootSurface) roots
            jsonCount = case surface of
                PrivateEventPayload -> length json
                SnapshotRegister -> 0
         in CoverageCounts
                { totalRoots = length matching
                , structuralRoots = length (filter ((== StructuralCoverage) . rootMode) matching)
                , opaqueRoots = length (filter ((== OpaqueCoverage) . rootMode) matching)
                , jsonBoundaries = jsonCount
                }

opaqueSurfaceFindings :: [OpaqueBoundary] -> [CoverageFinding]
opaqueSurfaceFindings boundaries =
    [ CoverageFinding
        { findingSeverity = Warning
        , findingCode = CoverageOpaqueSurface
        , findingRoots = [root]
        , findingMessage = "persisted private-event root contains opaque mapped boundaries"
        }
    | root <- Set.toAscList (Set.fromList (map opaqueRoot boundaries))
    ]

gateFinding :: Text -> [OpaqueBoundary] -> CoverageFinding
gateFinding message boundaries =
    CoverageFinding
        { findingSeverity = Error
        , findingCode = CoverageOpaqueGateExceeded
        , findingRoots = Set.toAscList (Set.fromList (map opaqueRoot boundaries))
        , findingMessage = message
        }

unsupportedInventory :: [UnsupportedSurface]
unsupportedInventory =
    [ UnsupportedSurface
        { unsupportedSurface = "queue-payloads"
        , unsupportedSupport = "unsupported"
        , unsupportedReason = "queue payloads are not roots in the mapped-type graph"
        }
    , UnsupportedSurface
        { unsupportedSurface = "public-contracts"
        , unsupportedSupport = "not-applicable"
        , unsupportedReason = "public contracts have a separately owned grammar and compatibility surface"
        }
    ]

useSiteKey :: UseSite -> MappedKey
useSiteKey (RootCommandField _ _ _ key) = key
useSiteKey (RootEventField _ _ _ key) = key
useSiteKey (RootRegister _ _ key) = key

useSiteSurface :: UseSite -> CoverageSurface
useSiteSurface RootEventField{} = PrivateEventPayload
useSiteSurface RootRegister{} = SnapshotRegister
useSiteSurface RootCommandField{} = error "command fields are not persisted coverage roots"

isEventSite :: UseSite -> Bool
isEventSite RootEventField{} = True
isEventSite RootRegister{} = False
isEventSite RootCommandField{} = False

rootText :: UseSite -> Text
rootText site = renderUsePath (UsePath site [])

declarationMode :: ResolvedMappedDecl -> CoverageMode
declarationMode =
    foldMappedDecl
        MappedDeclAlgebra
            { onStructuralDecl = \_ _ -> StructuralCoverage
            , onOpaqueDecl = const OpaqueCoverage
            }

instance ToJSON CoverageSurface where
    toJSON PrivateEventPayload = toJSON ("private-event-payload" :: Text)
    toJSON SnapshotRegister = toJSON ("snapshot-register" :: Text)

instance ToJSON CoverageMode where
    toJSON StructuralCoverage = toJSON ("structural" :: Text)
    toJSON OpaqueCoverage = toJSON ("opaque" :: Text)

instance ToJSON CoverageRoot where
    toJSON root =
        object
            [ "surface" .= rootSurface root
            , "path" .= rootPath root
            , "mappedType" .= rootMappedType root
            , "mode" .= rootMode root
            , "canonicalType" .= rootCanonicalType root
            , "codecIdentity" .= rootCodecIdentity root
            , "codecVersion" .= rootCodecVersion root
            , "wireFingerprint" .= rootWireFingerprint root
            ]

instance ToJSON StructuralBoundary where
    toJSON boundary =
        object
            [ "root" .= structuralRoot boundary
            , "path" .= structuralPath boundary
            , "mappedType" .= structuralMappedType boundary
            , "canonicalType" .= structuralCanonicalType boundary
            , "wireFingerprint" .= structuralWireFingerprint boundary
            ]

instance ToJSON OpaqueBoundary where
    toJSON boundary =
        object
            [ "root" .= opaqueRoot boundary
            , "path" .= opaquePath boundary
            , "mappedType" .= opaqueMappedType boundary
            , "codecIdentity" .= opaqueCodecIdentity boundary
            , "codecVersion" .= opaqueCodecVersion boundary
            ]

instance ToJSON JsonBoundary where
    toJSON boundary = object ["root" .= jsonRoot boundary, "path" .= jsonPath boundary]

instance ToJSON SnapshotBoundary where
    toJSON boundary =
        object
            [ "root" .= snapshotRoot boundary
            , "aggregate" .= snapshotAggregate boundary
            , "register" .= snapshotRegister boundary
            , "mappedType" .= snapshotMappedType boundary
            , "mode" .= snapshotMode boundary
            , "snapshotEncoding" .= snapshotEncoding boundary
            , "invalidation" .= snapshotInvalidation boundary
            , "wireFingerprint" .= snapshotWireFingerprint boundary
            , "snapshotEnabled" .= snapshotEnabled boundary
            ]

instance ToJSON UnsupportedSurface where
    toJSON surface =
        object
            [ "surface" .= unsupportedSurface surface
            , "support" .= unsupportedSupport surface
            , "reason" .= unsupportedReason surface
            ]

instance ToJSON CoverageCounts where
    toJSON counts =
        object
            [ "totalRoots" .= totalRoots counts
            , "structuralRoots" .= structuralRoots counts
            , "opaqueRoots" .= opaqueRoots counts
            , "jsonBoundaries" .= jsonBoundaries counts
            ]

instance ToJSON CoverageSummary where
    toJSON summary =
        object
            [ "privateEventPayloads" .= privateEventPayloads summary
            , "snapshotRegisters" .= snapshotRegisters summary
            ]

instance ToJSON CoverageFinding where
    toJSON finding =
        object
            [ "severity" .= severityValue (findingSeverity finding)
            , "code" .= show (findingCode finding)
            , "roots" .= findingRoots finding
            , "message" .= findingMessage finding
            ]
      where
        severityValue Error = "error" :: Text
        severityValue Warning = "advisory"

instance ToJSON CoveragePrevious where
    toJSON previous =
        object
            [ "reference" .= previousReference previous
            , "summary" .= previousSummary previous
            , "opaqueBoundaries" .= previousOpaqueBoundaries previous
            ]

instance ToJSON CoverageDelta where
    toJSON delta =
        object
            [ "privateEventRootDelta" .= privateEventRootDelta delta
            , "snapshotRegisterRootDelta" .= snapshotRegisterRootDelta delta
            , "opaqueBoundaryDelta" .= opaqueBoundaryDelta delta
            , "addedOpaqueBoundaries" .= addedOpaqueBoundaries delta
            , "removedOpaqueBoundaries" .= removedOpaqueBoundaries delta
            ]

instance ToJSON CoverageReport where
    toJSON report =
        object
            [ "schema" .= ("keiro-dsl/coverage-report/1" :: Text)
            , "spec" .= coverageSpec report
            , "roots" .= coverageRoots report
            , "structuralBoundaries" .= coverageStructuralBoundaries report
            , "opaqueBoundaries" .= coverageOpaqueBoundaries report
            , "jsonBoundaries" .= coverageJsonBoundaries report
            , "snapshotBoundaries" .= coverageSnapshotBoundaries report
            , "unsupportedSurfaces" .= coverageUnsupportedSurfaces report
            , "summary" .= coverageSummary report
            , "findings" .= coverageFindings report
            , "previous" .= coveragePrevious report
            , "delta" .= coverageDelta report
            ]
