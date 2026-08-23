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
import Keiro.Dsl.SemanticContract (CheckedService, checkedLanguageContract, checkedSpec, checkedTypeGraph)
import Keiro.Dsl.SemanticImpact (MappedConsumer (..), MappedImpactDelta (..))
import Keiro.Dsl.TypeGraph (UsePath (..), UseSite, renderUsePath)
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
  { router :: !Name,
    verification :: !SelectionVerification,
    identity :: !(Maybe Text),
    version :: !(Maybe Natural),
    fingerprint :: !(Maybe Text)
  }
  deriving stock (Eq, Ord, Show, Generic)

data CoordinationImpact = CoordinationImpact
  { router :: !Name,
    severity :: !CoordinationSeverity,
    reason :: !CoordinationReason,
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
  { router :: !Name,
    previousSelection :: !(Maybe RouterSelectionSnapshot),
    currentSelection :: !(Maybe RouterSelectionSnapshot)
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
      [ "router" .= (.router) snapshot,
        "verification" .= (.verification) snapshot,
        "identity" .= (.identity) snapshot,
        "version" .= (.version) snapshot,
        "fingerprint" .= (.fingerprint) snapshot
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
      [ "router" .= (.router) impact,
        "severity" .= severityIdentity ((.severity) impact),
        "reason" .= reasonIdentity ((.reason) impact),
        "previousVerification" .= (.previousVerification) impact,
        "currentVerification" .= (.currentVerification) impact,
        "previousIdentity" .= (.previousIdentity) impact,
        "currentIdentity" .= (.currentIdentity) impact,
        "previousVersion" .= (.previousVersion) impact,
        "currentVersion" .= (.currentVersion) impact,
        "previousFingerprint" .= (.previousFingerprint) impact,
        "currentFingerprint" .= (.currentFingerprint) impact,
        "affectedUseSites" .= map (renderUsePath . (`UsePath` [])) ((.affectedUseSites) impact)
      ]

-- | Freeze every router's checked coordination metadata in canonical name order.
routerSelectionSnapshots :: CheckedService -> [RouterSelectionSnapshot]
routerSelectionSnapshots = sortOn (.router) . map (.snapshot) . routerSelectionStates

routerSelectionDrift :: [RouterSelectionSnapshot] -> [RouterSelectionSnapshot] -> [RouterSelectionDrift]
routerSelectionDrift previous current =
  [ RouterSelectionDrift router old new
  | router <- Set.toAscList (Map.keysSet oldByRouter <> Map.keysSet newByRouter),
    let old = Map.lookup router oldByRouter,
    let new = Map.lookup router newByRouter,
    old /= new
  ]
  where
    oldByRouter = Map.fromList [((.router) snapshot, snapshot) | snapshot <- previous]
    newByRouter = Map.fromList [((.router) snapshot, snapshot) | snapshot <- current]

renderRouterSelectionDrift :: [RouterSelectionDrift] -> [Text]
renderRouterSelectionDrift [] = []
renderRouterSelectionDrift drifts = "router selection coordination metadata:" : concatMap renderDrift drifts
  where
    renderDrift drift =
      [ "  " <> (.router) drift,
        "    previous: " <> maybe "(none)" renderSnapshot ((.previousSelection) drift),
        "    current:  " <> maybe "(none)" renderSnapshot ((.currentSelection) drift)
      ]
    renderSnapshot snapshot =
      verificationIdentity ((.verification) snapshot)
        <> maybe "" (" identity=" <>) ((.identity) snapshot)
        <> maybe "" ((" version=" <>) . T.pack . show) ((.version) snapshot)
        <> maybe "" (" fingerprint=" <>) ((.fingerprint) snapshot)

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
          consumer <- Set.toList ((.previousConsumers) delta <> (.currentConsumers) delta),
          RouterSelectionConsumer router _ <- [consumer]
        ]
    mappedImpacts =
      [ mkImpact
          CoordinationAdvisory
          SelectionMappedDependencyChanged
          oldState
          newState
          ((.useSites) oldState <> (.useSites) newState)
      | router <- affectedRouters,
        Just oldState <- [Map.lookup router previousStates],
        Just newState <- [Map.lookup router currentStates]
      ]
    impactOrder impact = ((.router) impact, (.reason) impact)

data RouterSelectionState = RouterSelectionState
  { snapshot :: !RouterSelectionSnapshot,
    useSites :: ![UseSite]
  }

stateMap :: CheckedService -> Map Name RouterSelectionState
stateMap = Map.fromList . map (\state -> ((.router) ((.snapshot) state), state)) . routerSelectionStates

routerSelectionStates :: CheckedService -> [RouterSelectionState]
routerSelectionStates service = case checkedTypeGraph service of
  Left failures -> error ("checked service type graph did not resolve for router coordination: " <> show failures)
  Right graph -> map (routerState graph) routers
  where
    spec = checkedSpec service
    routers = [router | NRouter router <- (.nodes) spec]
    routerState graph router = case (.source) ((.resolve) router) of
      ResolveDeclarative {} -> case checkRouterSelection (checkedLanguageContract service) graph spec router of
        Left failures -> error ("validated declarative router selection did not check for coordination: " <> show failures)
        Right selection ->
          RouterSelectionState
            { snapshot =
                RouterSelectionSnapshot
                  { router = (.id) router,
                    verification = DeclarativeVerified,
                    identity = Just ((.identity) selection),
                    version = Just ((.version) selection),
                    fingerprint = Just ((.fingerprint) selection)
                  },
              useSites = (.useSites) selection
            }
      ResolveReadModel {} -> customState router
      ResolveHole -> customState router
    customState router =
      RouterSelectionState
        { snapshot =
            RouterSelectionSnapshot
              { router = (.id) router,
                verification = CustomUnverified,
                identity = Nothing,
                version = Nothing,
                fingerprint = Nothing
              },
          useSites = []
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
    old = (.snapshot) oldState
    new = (.snapshot) newState
    oldVerification = (.verification) old
    newVerification = (.verification) new
    oldIdentity = (.identity) old
    newIdentity = (.identity) new
    oldVersion = (.version) old
    newVersion = (.version) new
    oldFingerprint = (.fingerprint) old
    newFingerprint = (.fingerprint) new
    useSites = (.useSites) oldState <> (.useSites) newState
    advisory reason = Just (mkImpact CoordinationAdvisory reason oldState newState useSites)
    breaking reason = Just (mkImpact CoordinationBreaking reason oldState newState useSites)

mkImpact :: CoordinationSeverity -> CoordinationReason -> RouterSelectionState -> RouterSelectionState -> [UseSite] -> CoordinationImpact
mkImpact severity reason oldState newState useSites =
  CoordinationImpact
    { router = (.router) new,
      severity = severity,
      reason = reason,
      previousVerification = (.verification) old,
      currentVerification = (.verification) new,
      previousIdentity = (.identity) old,
      currentIdentity = (.identity) new,
      previousVersion = (.version) old,
      currentVersion = (.version) new,
      previousFingerprint = (.fingerprint) old,
      currentFingerprint = (.fingerprint) new,
      affectedUseSites = Set.toAscList (Set.fromList useSites)
    }
  where
    old = (.snapshot) oldState
    new = (.snapshot) newState

renderCoordinationImpact :: [CoordinationImpact] -> [Text]
renderCoordinationImpact [] = []
renderCoordinationImpact impacts = "coordination impact:" : concatMap renderImpact impacts
  where
    renderImpact impact =
      [ "  " <> (.router) impact <> ": " <> severityIdentity ((.severity) impact) <> " (" <> reasonIdentity ((.reason) impact) <> ")",
        "    verification: " <> verificationIdentity ((.previousVerification) impact) <> " -> " <> verificationIdentity ((.currentVerification) impact),
        "    identity: " <> renderMaybe ((.previousIdentity) impact) <> " -> " <> renderMaybe ((.currentIdentity) impact),
        "    version: " <> renderMaybeShow ((.previousVersion) impact) <> " -> " <> renderMaybeShow ((.currentVersion) impact),
        "    fingerprint: " <> renderMaybe ((.previousFingerprint) impact) <> " -> " <> renderMaybe ((.currentFingerprint) impact),
        "    affected use sites: " <> renderUseSites ((.affectedUseSites) impact)
      ]
    renderMaybe = maybe "(unverified)" id
    renderMaybeShow = maybe "(unverified)" (T.pack . show)
    renderUseSites [] = "(none)"
    renderUseSites values = T.intercalate ", " (map (renderUsePath . (`UsePath` [])) values)

snapshotValid :: RouterSelectionSnapshot -> Bool
snapshotValid snapshot = case (.verification) snapshot of
  DeclarativeVerified -> allPresent
  CustomUnverified -> allAbsent
  where
    fields = [() <$ (.identity) snapshot, () <$ (.version) snapshot, () <$ (.fingerprint) snapshot]
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
