{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Reviewable coordination consequences for router selection evolution.
--
-- The aggregate replay report deliberately remains separate. Declarative
-- selection metadata describes drain/redelivery coordination around the frozen
-- target-keyed command identity; custom resolvers are reported honestly as
-- unverified rather than assigned invented semantic metadata.
module Keiro.Dsl.CoordinationImpact
  ( SelectionVerification (..),
    CoordinationSeverity (..),
    CoordinationReason (..),
    RouterSelectionSnapshot (..),
    RouterSelectionDrift (..),
    CoordinationImpact (..),
    routerSelectionSnapshots,
    routerSelectionDrift,
    renderRouterSelectionDrift,
    coordinationImpact,
    renderCoordinationImpact,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.RouterSelection
import Keiro.Dsl.SemanticContract (CheckedService (..))
import Keiro.Dsl.SemanticImpact (MappedConsumer (..), MappedImpactDelta (..))
import Keiro.Dsl.TypeGraph (UsePath (..), UseSite, renderUsePath, resolveTypeGraph)
import Numeric.Natural (Natural)

data SelectionVerification = DeclarativeVerified | CustomUnverified
  deriving stock (Eq, Ord, Show, Generic)

data CoordinationSeverity = CoordinationAdvisory | CoordinationBreaking
  deriving stock (Eq, Ord, Show, Generic)

data CoordinationReason
  = SelectionIdentityChanged
  | SelectionVersionDecreased
  | SelectionFingerprintChangedWithoutVersionBump
  | SelectionFingerprintChangedWithVersionBump
  | SelectionVersionMetadataOnly
  | SelectionVerificationBoundaryChanged
  | SelectionMappedDependencyChanged
  deriving stock (Eq, Ord, Show, Generic)

-- | Durable selection ownership metadata. Locations and query files are absent;
-- the ledger owns only the verification boundary and checked semantic identity.
data RouterSelectionSnapshot = RouterSelectionSnapshot
  { selectionRouter :: !Name,
    selectionVerification :: !SelectionVerification,
    selectionIdentity :: !(Maybe Text),
    selectionVersion :: !(Maybe Natural),
    selectionFingerprint :: !(Maybe Text)
  }
  deriving stock (Eq, Ord, Show, Generic)

data CoordinationImpact = CoordinationImpact
  { coordinationRouter :: !Name,
    coordinationSeverity :: !CoordinationSeverity,
    coordinationReason :: !CoordinationReason,
    previousVerification :: !SelectionVerification,
    currentVerification :: !SelectionVerification,
    previousIdentity :: !(Maybe Text),
    currentIdentity :: !(Maybe Text),
    previousVersion :: !(Maybe Natural),
    currentVersion :: !(Maybe Natural),
    previousFingerprint :: !(Maybe Text),
    currentFingerprint :: !(Maybe Text),
    affectedUseSites :: ![UseSite]
  }
  deriving stock (Eq, Show, Generic)

data RouterSelectionDrift = RouterSelectionDrift
  { driftRouter :: !Name,
    driftPreviousSelection :: !(Maybe RouterSelectionSnapshot),
    driftCurrentSelection :: !(Maybe RouterSelectionSnapshot)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SelectionVerification where
  toJSON = toJSON . verificationIdentity

instance FromJSON SelectionVerification where
  parseJSON value = do
    identity <- parseJSON value
    case (identity :: Text) of
      "declarative-verified" -> pure DeclarativeVerified
      "custom-unverified" -> pure CustomUnverified
      _ -> fail "unknown router selection verification"

instance ToJSON RouterSelectionSnapshot where
  toJSON snapshot =
    object
      [ "router" .= selectionRouter snapshot,
        "verification" .= selectionVerification snapshot,
        "identity" .= selectionIdentity snapshot,
        "version" .= selectionVersion snapshot,
        "fingerprint" .= selectionFingerprint snapshot
      ]

instance FromJSON RouterSelectionSnapshot where
  parseJSON = withObject "RouterSelectionSnapshot" $ \fields -> do
    snapshot <-
      RouterSelectionSnapshot
        <$> fields .: "router"
        <*> fields .: "verification"
        <*> fields .:? "identity"
        <*> fields .:? "version"
        <*> fields .:? "fingerprint"
    unless (snapshotValid snapshot) (fail "router selection metadata does not match its verification boundary")
    pure snapshot

instance ToJSON CoordinationImpact where
  toJSON impact =
    object
      [ "router" .= coordinationRouter impact,
        "severity" .= severityIdentity (coordinationSeverity impact),
        "reason" .= reasonIdentity (coordinationReason impact),
        "previousVerification" .= previousVerification impact,
        "currentVerification" .= currentVerification impact,
        "previousIdentity" .= previousIdentity impact,
        "currentIdentity" .= currentIdentity impact,
        "previousVersion" .= previousVersion impact,
        "currentVersion" .= currentVersion impact,
        "previousFingerprint" .= previousFingerprint impact,
        "currentFingerprint" .= currentFingerprint impact,
        "affectedUseSites" .= map (renderUsePath . (`UsePath` [])) (affectedUseSites impact)
      ]

-- | Freeze every router's checked coordination metadata in canonical name order.
routerSelectionSnapshots :: CheckedService -> [RouterSelectionSnapshot]
routerSelectionSnapshots = sortOn selectionRouter . map stateSnapshot . routerSelectionStates

routerSelectionDrift :: [RouterSelectionSnapshot] -> [RouterSelectionSnapshot] -> [RouterSelectionDrift]
routerSelectionDrift previous current =
  [ RouterSelectionDrift router old new
  | router <- Set.toAscList (Map.keysSet oldByRouter <> Map.keysSet newByRouter),
    let old = Map.lookup router oldByRouter,
    let new = Map.lookup router newByRouter,
    old /= new
  ]
  where
    oldByRouter = Map.fromList [(selectionRouter snapshot, snapshot) | snapshot <- previous]
    newByRouter = Map.fromList [(selectionRouter snapshot, snapshot) | snapshot <- current]

renderRouterSelectionDrift :: [RouterSelectionDrift] -> [Text]
renderRouterSelectionDrift [] = []
renderRouterSelectionDrift drifts = "router selection coordination metadata:" : concatMap renderDrift drifts
  where
    renderDrift drift =
      [ "  " <> driftRouter drift,
        "    previous: " <> maybe "(none)" renderSnapshot (driftPreviousSelection drift),
        "    current:  " <> maybe "(none)" renderSnapshot (driftCurrentSelection drift)
      ]
    renderSnapshot snapshot =
      verificationIdentity (selectionVerification snapshot)
        <> maybe "" (" identity=" <>) (selectionIdentity snapshot)
        <> maybe "" ((" version=" <>) . T.pack . show) (selectionVersion snapshot)
        <> maybe "" (" fingerprint=" <>) (selectionFingerprint snapshot)

coordinationImpact :: CheckedService -> CheckedService -> [MappedImpactDelta] -> [CoordinationImpact]
coordinationImpact previous current mappedDeltas =
  sortOn impactOrder (directImpacts <> mappedImpacts)
  where
    previousStates = stateMap previous
    currentStates = stateMap current
    matchedRouters = Set.toAscList (Map.keysSet previousStates `Set.intersection` Map.keysSet currentStates)
    directImpacts =
      mapMaybe
        (\router -> directImpact (previousStates Map.! router) (currentStates Map.! router))
        matchedRouters
    affectedRouters =
      Set.toAscList . Set.fromList $
        [ router
        | delta <- mappedDeltas,
          consumer <- Set.toList (impactPreviousConsumers delta <> impactCurrentConsumers delta),
          RouterSelectionConsumer router _ <- [consumer]
        ]
    mappedImpacts =
      [ mkImpact
          CoordinationAdvisory
          SelectionMappedDependencyChanged
          oldState
          newState
          (stateUseSites oldState <> stateUseSites newState)
      | router <- affectedRouters,
        Just oldState <- [Map.lookup router previousStates],
        Just newState <- [Map.lookup router currentStates]
      ]
    impactOrder impact = (coordinationRouter impact, coordinationReason impact)

data RouterSelectionState = RouterSelectionState
  { stateSnapshot :: !RouterSelectionSnapshot,
    stateUseSites :: ![UseSite]
  }

stateMap :: CheckedService -> Map Name RouterSelectionState
stateMap = Map.fromList . map (\state -> (selectionRouter (stateSnapshot state), state)) . routerSelectionStates

routerSelectionStates :: CheckedService -> [RouterSelectionState]
routerSelectionStates service = case resolveTypeGraph spec of
  Left failures -> error ("checked service type graph did not resolve for router coordination: " <> show failures)
  Right graph -> map (routerState graph) routers
  where
    spec = checkedSpec service
    routers = [router | NRouter router <- specNodes spec]
    routerState graph router = case rvSource (rtResolve router) of
      ResolveDeclarative {} -> case checkRouterSelection (checkedLanguageContract service) graph spec router of
        Left failures -> error ("validated declarative router selection did not check for coordination: " <> show failures)
        Right selection ->
          RouterSelectionState
            { stateSnapshot =
                RouterSelectionSnapshot
                  { selectionRouter = rtId router,
                    selectionVerification = DeclarativeVerified,
                    selectionIdentity = Just (checkedIdentity selection),
                    selectionVersion = Just (checkedVersion selection),
                    selectionFingerprint = Just (checkedFingerprint selection)
                  },
              stateUseSites = checkedUseSites selection
            }
      ResolveReadModel {} -> customState router
      ResolveHole -> customState router
    customState router =
      RouterSelectionState
        { stateSnapshot =
            RouterSelectionSnapshot
              { selectionRouter = rtId router,
                selectionVerification = CustomUnverified,
                selectionIdentity = Nothing,
                selectionVersion = Nothing,
                selectionFingerprint = Nothing
              },
          stateUseSites = []
        }

directImpact :: RouterSelectionState -> RouterSelectionState -> Maybe CoordinationImpact
directImpact oldState newState
  | oldVerification /= newVerification = advisory SelectionVerificationBoundaryChanged
  | oldVerification == CustomUnverified = Nothing
  | oldIdentity /= newIdentity = breaking SelectionIdentityChanged
  | newVersion < oldVersion = breaking SelectionVersionDecreased
  | oldFingerprint /= newFingerprint && newVersion == oldVersion = breaking SelectionFingerprintChangedWithoutVersionBump
  | oldFingerprint /= newFingerprint && newVersion > oldVersion = advisory SelectionFingerprintChangedWithVersionBump
  | oldFingerprint == newFingerprint && newVersion > oldVersion = advisory SelectionVersionMetadataOnly
  | otherwise = Nothing
  where
    old = stateSnapshot oldState
    new = stateSnapshot newState
    oldVerification = selectionVerification old
    newVerification = selectionVerification new
    oldIdentity = selectionIdentity old
    newIdentity = selectionIdentity new
    oldVersion = selectionVersion old
    newVersion = selectionVersion new
    oldFingerprint = selectionFingerprint old
    newFingerprint = selectionFingerprint new
    useSites = stateUseSites oldState <> stateUseSites newState
    advisory reason = Just (mkImpact CoordinationAdvisory reason oldState newState useSites)
    breaking reason = Just (mkImpact CoordinationBreaking reason oldState newState useSites)

mkImpact :: CoordinationSeverity -> CoordinationReason -> RouterSelectionState -> RouterSelectionState -> [UseSite] -> CoordinationImpact
mkImpact severity reason oldState newState useSites =
  CoordinationImpact
    { coordinationRouter = selectionRouter new,
      coordinationSeverity = severity,
      coordinationReason = reason,
      previousVerification = selectionVerification old,
      currentVerification = selectionVerification new,
      previousIdentity = selectionIdentity old,
      currentIdentity = selectionIdentity new,
      previousVersion = selectionVersion old,
      currentVersion = selectionVersion new,
      previousFingerprint = selectionFingerprint old,
      currentFingerprint = selectionFingerprint new,
      affectedUseSites = Set.toAscList (Set.fromList useSites)
    }
  where
    old = stateSnapshot oldState
    new = stateSnapshot newState

renderCoordinationImpact :: [CoordinationImpact] -> [Text]
renderCoordinationImpact [] = []
renderCoordinationImpact impacts = "coordination impact:" : concatMap renderImpact impacts
  where
    renderImpact impact =
      [ "  " <> coordinationRouter impact <> ": " <> severityIdentity (coordinationSeverity impact) <> " (" <> reasonIdentity (coordinationReason impact) <> ")",
        "    verification: " <> verificationIdentity (previousVerification impact) <> " -> " <> verificationIdentity (currentVerification impact),
        "    identity: " <> renderMaybe (previousIdentity impact) <> " -> " <> renderMaybe (currentIdentity impact),
        "    version: " <> renderMaybeShow (previousVersion impact) <> " -> " <> renderMaybeShow (currentVersion impact),
        "    fingerprint: " <> renderMaybe (previousFingerprint impact) <> " -> " <> renderMaybe (currentFingerprint impact),
        "    affected use sites: " <> renderUseSites (affectedUseSites impact)
      ]
    renderMaybe = maybe "(unverified)" id
    renderMaybeShow = maybe "(unverified)" (T.pack . show)
    renderUseSites [] = "(none)"
    renderUseSites values = T.intercalate ", " (map (renderUsePath . (`UsePath` [])) values)

snapshotValid :: RouterSelectionSnapshot -> Bool
snapshotValid snapshot = case selectionVerification snapshot of
  DeclarativeVerified -> allPresent
  CustomUnverified -> allAbsent
  where
    fields = [() <$ selectionIdentity snapshot, () <$ selectionVersion snapshot, () <$ selectionFingerprint snapshot]
    allPresent = all (/= Nothing) fields
    allAbsent = all (== Nothing) fields

verificationIdentity :: SelectionVerification -> Text
verificationIdentity DeclarativeVerified = "declarative-verified"
verificationIdentity CustomUnverified = "custom-unverified"

severityIdentity :: CoordinationSeverity -> Text
severityIdentity CoordinationAdvisory = "advisory"
severityIdentity CoordinationBreaking = "breaking"

reasonIdentity :: CoordinationReason -> Text
reasonIdentity SelectionIdentityChanged = "selection-identity-changed"
reasonIdentity SelectionVersionDecreased = "selection-version-decreased"
reasonIdentity SelectionFingerprintChangedWithoutVersionBump = "selection-fingerprint-changed-without-version-bump"
reasonIdentity SelectionFingerprintChangedWithVersionBump = "selection-fingerprint-changed-with-version-bump"
reasonIdentity SelectionVersionMetadataOnly = "selection-version-metadata-only"
reasonIdentity SelectionVerificationBoundaryChanged = "selection-verification-boundary-changed"
reasonIdentity SelectionMappedDependencyChanged = "selection-mapped-dependency-changed"
