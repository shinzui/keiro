{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Static behavioral obligations derivable from a validated aggregate graph.
--
-- This module deliberately knows nothing about consumer Haskell witnesses.  It
-- inventories the finite obligations the source graph requires; the generated
-- consumer contract reconciles and executes witness values in a later layer.
module Keiro.Dsl.BehaviorCoverage
  ( BehaviorKey (..),
    unBehaviorKey,
    ObligationKind (..),
    EvidenceLevel (..),
    GuardCoverage (..),
    OutputEvidence (..),
    RequirementOrigin (..),
    BehaviorExactLocation (..),
    BehaviorRequirement (..),
    BehaviorRecordRow (..),
    BehaviorDerivationError (..),
    BehaviorObligationsReport (..),
    deriveAggregateBehaviorRequirements,
    deriveBehaviorRequirements,
    deriveBehaviorRequirementsForService,
    behaviorRecordRows,
    attributeBehaviorOwner,
    behaviorObligationsReport,
    renderBehaviorObligationsText,
    encodeBehaviorObligationsJson,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.List (find, groupBy, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Keiro.Dsl.CanonicalEncoding (canonicalTransitionOutcome)
import Keiro.Dsl.EventOutput
import Keiro.Dsl.Grammar
import Keiro.Dsl.PrettyPrint (renderExpr)
import Keiro.Dsl.ReadModelShape (fnv1a64)
import Keiro.Dsl.SemanticContract (CheckedService, checkedSpec, checkedTypeGraph)
import Keiro.Dsl.SourceIndex (TransitionOrdinal (..))
import Keiro.Dsl.TypeGraph (TypeGraph, TypeGraphError, resolveTypeGraph)

newtype BehaviorKey = BehaviorKey {unBehaviorKey :: Text}
  deriving stock (Eq, Ord, Show)

unBehaviorKey :: BehaviorKey -> Text
unBehaviorKey (BehaviorKey value) = value

data ObligationKind
  = LiveTransition
  | RequiredRejection
  | ReplayTransition
  deriving stock (Eq, Ord, Show)

data EvidenceLevel
  = GeneratedAuthoritative
  | HoleWitnessed
  | LegacyRuntimeWitness
  deriving stock (Eq, Ord, Show)

data GuardCoverage
  = GuardTotal
  | GuardPartial
  | GuardUnknown
  | GuardNotApplicable
  deriving stock (Eq, Ord, Show)

data OutputEvidence
  = GeneratedOutput !Name
  | HandOwnedOutput !OutputObligationKey
  deriving stock (Eq, Ord, Show)

-- | The semantic source subject that owns an obligation. Unlike 'Loc', this
-- identity does not change when source text moves and can therefore be joined
-- to an independently checked exact source index.
data RequirementOrigin
  = TransitionRequirementOrigin !Name !TransitionOrdinal
  | RejectionRequirementOrigin !Name !Name
  deriving stock (Eq, Ord, Show)

-- | Current exact presentation data attached only by a source-aware reporting
-- path. It never contributes to 'requirementCanonical' or 'BehaviorKey'.
data BehaviorExactLocation = BehaviorExactLocation
  { sourceFile :: !FilePath,
    sourceLine :: !Int,
    sourceColumn :: !Int
  }
  deriving stock (Eq, Ord, Show)

data BehaviorRequirement = BehaviorRequirement
  { key :: !BehaviorKey,
    origin :: !RequirementOrigin,
    kind :: !ObligationKind,
    evidence :: !EvidenceLevel,
    guardCoverage :: !GuardCoverage,
    context :: !Name,
    aggregate :: !Name,
    source :: !Name,
    command :: !Name,
    target :: !(Maybe Name),
    mode :: !(Maybe TransitionMode),
    events :: ![Name],
    outputs :: ![OutputEvidence],
    domainOutcome :: !(Maybe TransitionOutcome),
    location :: !Loc,
    exactLocation :: !(Maybe BehaviorExactLocation),
    owner :: !(Maybe FilePath),
    canonical :: !Text
  }
  deriving stock (Eq, Show)

-- | Forward-compatible record representation of one requirement.  Records
-- retain enough human-readable identity to report additions and removals
-- without re-reading or attempting to understand consumer Haskell.
data BehaviorRecordRow = BehaviorRecordRow
  { key :: !BehaviorKey,
    kind :: !ObligationKind,
    evidence :: !EvidenceLevel,
    aggregate :: !Name,
    source :: !Name,
    command :: !Name,
    owner :: !(Maybe FilePath),
    outputs :: ![OutputEvidence]
  }
  deriving stock (Eq, Ord, Show)

data BehaviorDerivationError
  = InvalidEventOutput !Name !EventOutputError
  | EventlessStateChange !Name !Name !Name
  | DuplicateBehaviorIdentity !Text ![Loc]
  | BehaviorKeyCollision !BehaviorKey ![Text]
  deriving stock (Eq, Show)

data BehaviorObligationsReport = BehaviorObligationsReport
  { subject :: !FilePath,
    workspaceService :: !(Maybe Text),
    requirements :: ![BehaviorRequirement]
  }
  deriving stock (Eq, Show)

instance ToJSON BehaviorKey where
  toJSON = toJSON . unBehaviorKey

instance ToJSON ObligationKind where
  toJSON = toJSON . obligationKindText

instance ToJSON EvidenceLevel where
  toJSON = toJSON . evidenceLevelText

instance ToJSON GuardCoverage where
  toJSON = toJSON . guardCoverageText

instance ToJSON OutputEvidence where
  toJSON evidence = case evidence of
    GeneratedOutput command -> object ["ownership" .= ("generated-command-identity" :: Text), "command" .= command]
    HandOwnedOutput key -> object ["ownership" .= ("hand-owned" :: Text), "obligation" .= unOutputObligationKey key]

instance FromJSON BehaviorKey where
  parseJSON value = BehaviorKey <$> parseJSON value

instance FromJSON ObligationKind where
  parseJSON value = parseJSON value >>= parseLabel
    where
      parseLabel ("live-transition" :: Text) = pure LiveTransition
      parseLabel "required-rejection" = pure RequiredRejection
      parseLabel "replay-transition" = pure ReplayTransition
      parseLabel other = fail ("unknown behavior obligation kind: " <> T.unpack other)

instance FromJSON EvidenceLevel where
  parseJSON value = parseJSON value >>= parseLabel
    where
      parseLabel ("generated-authoritative" :: Text) = pure GeneratedAuthoritative
      parseLabel "hole-witnessed" = pure HoleWitnessed
      parseLabel "legacy-runtime-witness" = pure LegacyRuntimeWitness
      parseLabel other = fail ("unknown behavior evidence level: " <> T.unpack other)

instance FromJSON OutputEvidence where
  parseJSON = withObject "OutputEvidence" $ \fields -> do
    ownership <- fields .: "ownership"
    case (ownership :: Text) of
      "generated-command-identity" -> GeneratedOutput <$> fields .: "command"
      "hand-owned" -> HandOwnedOutput . OutputObligationKey <$> fields .: "obligation"
      other -> fail ("unknown event-output ownership: " <> T.unpack other)

instance ToJSON BehaviorRecordRow where
  toJSON row =
    object
      ( [ "key" .= (.key) row,
          "kind" .= (.kind) row,
          "evidence" .= (.evidence) row,
          "aggregate" .= (.aggregate) row,
          "source" .= (.source) row,
          "command" .= (.command) row,
          "outputs" .= (.outputs) row
        ]
          <> ["owner" .= owner | Just owner <- [(.owner) row]]
      )

instance FromJSON BehaviorRecordRow where
  parseJSON = withObject "BehaviorRecordRow" $ \fields ->
    BehaviorRecordRow
      <$> fields .: "key"
      <*> fields .: "kind"
      <*> fields .: "evidence"
      <*> fields .: "aggregate"
      <*> fields .: "source"
      <*> fields .: "command"
      <*> fields .:? "owner"
      <*> fields .: "outputs"

instance ToJSON BehaviorRequirement where
  toJSON requirement =
    object
      ( [ "key" .= (.key) requirement,
          "kind" .= (.kind) requirement,
          "evidence" .= (.evidence) requirement,
          "guardCoverage" .= (.guardCoverage) requirement,
          "context" .= (.context) requirement,
          "aggregate" .= (.aggregate) requirement,
          "source" .= (.source) requirement,
          "command" .= (.command) requirement,
          "target" .= (.target) requirement,
          "mode" .= fmap transitionModeText ((.mode) requirement),
          "events" .= (.events) requirement,
          "outputs" .= (.outputs) requirement,
          "location"
            .= object
              ( ["line" .= maybe (unLoc ((.location) requirement)) (.sourceLine) ((.exactLocation) requirement)]
                  <> ["member" .= owner | Just owner <- [(.owner) requirement]]
                  <> ["file" .= (.sourceFile) exact | Just exact <- [(.exactLocation) requirement]]
                  <> ["column" .= (.sourceColumn) exact | Just exact <- [(.exactLocation) requirement]]
                  <> ["quality" .= maybe ("line-only" :: Text) (const "exact") ((.exactLocation) requirement)]
              )
        ]
          <> ["domainOutcome" .= canonicalTransitionOutcome (Just outcome) | Just outcome <- [(.domainOutcome) requirement]]
      )

instance ToJSON BehaviorObligationsReport where
  toJSON report =
    object
      ( [ "schema" .= ("keiro-dsl/behavior-obligations/1" :: Text),
          "subject" .= (.subject) report,
          "requirements" .= (.requirements) report
        ]
          <> ["workspace" .= object ["service" .= service] | Just service <- [(.workspaceService) report]]
      )

deriveBehaviorRequirements :: Spec -> Either [BehaviorDerivationError] [BehaviorRequirement]
deriveBehaviorRequirements spec = deriveBehaviorRequirementsWithGraphResult (resolveTypeGraph spec) spec

deriveBehaviorRequirementsForService :: CheckedService -> Either [BehaviorDerivationError] [BehaviorRequirement]
deriveBehaviorRequirementsForService service =
  deriveBehaviorRequirementsWithGraphResult (checkedTypeGraph service) (checkedSpec service)

deriveBehaviorRequirementsWithGraphResult :: Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> Either [BehaviorDerivationError] [BehaviorRequirement]
deriveBehaviorRequirementsWithGraphResult typeGraphResult spec = case fmap concat (traverse (deriveAggregateBehaviorRequirementsWithGraphResult typeGraphResult spec) aggregates) of
  Left derivationError -> Left [derivationError]
  Right raw -> do
    rejectIdentityDefects raw
    pure (sortOn (.key) raw)
  where
    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]

deriveAggregateBehaviorRequirements :: Spec -> Aggregate -> Either BehaviorDerivationError [BehaviorRequirement]
deriveAggregateBehaviorRequirements spec = deriveAggregateBehaviorRequirementsWithGraphResult (resolveTypeGraph spec) spec

deriveAggregateBehaviorRequirementsWithGraphResult :: Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> Aggregate -> Either BehaviorDerivationError [BehaviorRequirement]
deriveAggregateBehaviorRequirementsWithGraphResult typeGraphResult spec aggregate = do
  let reachable = liveReachableStates aggregate
      indexedTransitions = zip (map TransitionOrdinal [0 ..]) ((.transitions) aggregate)
      liveTransitions =
        [ (ordinal, transition)
        | (ordinal, transition) <- indexedTransitions,
          (.mode) transition == TmLive,
          (.source) transition `Set.member` reachable
        ]
      replayTransitions = [(ordinal, transition) | (ordinal, transition) <- indexedTransitions, (.mode) transition == TmReplayOnly]
      commands = map (\command -> command.name) ((.commands) aggregate)
      cells = [(state, commandName) | state <- Set.toAscList reachable, commandName <- commands]
      cellTransitions state commandName =
        [ (ordinal, transition)
        | (ordinal, transition) <- liveTransitions,
          (.source) transition == state,
          (.command) transition == commandName
        ]
      transitionRows =
        [ transitionRequirement typeGraphResult spec aggregate (cellGuardCoverage (map snd siblings)) ordinal transition
        | (state, command) <- cells,
          let siblings = cellTransitions state command,
          (ordinal, transition) <- siblings
        ]
      rejectionRows =
        [ pure (rejectionRequirement spec aggregate state command)
        | (state, command) <- cells,
          null (cellTransitions state command)
        ]
      replayRows = [transitionRequirement typeGraphResult spec aggregate (replayGuardCoverage transition) ordinal transition | (ordinal, transition) <- replayTransitions]
  sequence (transitionRows <> rejectionRows <> replayRows)

behaviorRecordRows :: [BehaviorRequirement] -> [BehaviorRecordRow]
behaviorRecordRows = map toRow
  where
    toRow requirement =
      BehaviorRecordRow
        { key = (.key) requirement,
          kind = (.kind) requirement,
          evidence = (.evidence) requirement,
          aggregate = (.aggregate) requirement,
          source = (.source) requirement,
          command = (.command) requirement,
          owner = (.owner) requirement,
          outputs = (.outputs) requirement
        }

attributeBehaviorOwner :: (Name -> Maybe FilePath) -> BehaviorRequirement -> BehaviorRequirement
attributeBehaviorOwner ownerForAggregate BehaviorRequirement {key, origin, kind, evidence, guardCoverage, context, aggregate, source, command, target, mode, events, outputs, domainOutcome, location, exactLocation, canonical} =
  BehaviorRequirement
    { key,
      origin,
      kind,
      evidence,
      guardCoverage,
      context,
      aggregate,
      source,
      command,
      target,
      mode,
      events,
      outputs,
      domainOutcome,
      location,
      exactLocation,
      owner = ownerForAggregate aggregate,
      canonical
    }

behaviorObligationsReport :: FilePath -> Spec -> Either [BehaviorDerivationError] BehaviorObligationsReport
behaviorObligationsReport subject spec =
  BehaviorObligationsReport subject Nothing <$> deriveBehaviorRequirements spec

transitionRequirement :: Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> Aggregate -> GuardCoverage -> TransitionOrdinal -> Transition -> Either BehaviorDerivationError BehaviorRequirement
transitionRequirement typeGraphResult spec aggregate guardCoverage ordinal transition = do
  if null ((.emits) transition) && ((.source) transition /= (.goto) transition || not (null ((.writes) transition)))
    then Left (EventlessStateChange ((.name) aggregate) ((.source) transition) ((.command) transition))
    else pure ()
  mappings <-
    traverse
      (\(emitIndex, eventName) -> either (Left . InvalidEventOutput eventName) Right (eventOutputMappingFromGraphResult typeGraphResult spec aggregate transition emitIndex eventName))
      (zip [1 ..] ((.emits) transition))
  let kind = if (.mode) transition == TmLive then LiveTransition else ReplayTransition
      outputs = map outputEvidence mappings
      canonical = transitionCanonical spec aggregate kind transition mappings
  pure
    BehaviorRequirement
      { key = canonicalKey canonical,
        origin = TransitionRequirementOrigin ((.name) aggregate) ordinal,
        kind = kind,
        evidence = transitionEvidence transition,
        guardCoverage = guardCoverage,
        context = (.context) spec,
        aggregate = (.name) aggregate,
        source = (.source) transition,
        command = (.command) transition,
        target = Just ((.goto) transition),
        mode = Just ((.mode) transition),
        events = (.emits) transition,
        outputs = outputs,
        domainOutcome = (.outcome) transition,
        location = (.loc) transition,
        exactLocation = Nothing,
        owner = Nothing,
        canonical = canonical
      }

rejectionRequirement :: Spec -> Aggregate -> Name -> Name -> BehaviorRequirement
rejectionRequirement spec aggregate state command =
  BehaviorRequirement
    { key = canonicalKey canonical,
      origin = RejectionRequirementOrigin ((.name) aggregate) state,
      kind = RequiredRejection,
      evidence = aggregateEvidence aggregate,
      guardCoverage = GuardNotApplicable,
      context = (.context) spec,
      aggregate = (.name) aggregate,
      source = state,
      command = command,
      target = Nothing,
      mode = Nothing,
      events = [],
      outputs = [],
      domainOutcome = Nothing,
      location = maybe ((.loc) aggregate) (.loc) (find ((== state) . (.name)) ((.states) aggregate)),
      exactLocation = Nothing,
      owner = Nothing,
      canonical = canonical
    }
  where
    canonical =
      T.intercalate
        "|"
        [ "behavior-v1",
          "kind=rejection",
          "context=" <> (.context) spec,
          "aggregate=" <> (.name) aggregate,
          "source=" <> state,
          "command=" <> command
        ]

transitionCanonical :: Spec -> Aggregate -> ObligationKind -> Transition -> [EventOutputMapping] -> Text
transitionCanonical spec aggregate kind transition mappings =
  T.intercalate
    "|"
    ( [ "behavior-v1",
        "kind=" <> obligationKindText kind,
        "context=" <> (.context) spec,
        "aggregate=" <> (.name) aggregate,
        "mode=" <> transitionModeText ((.mode) transition),
        "source=" <> (.source) transition,
        "command=" <> (.command) transition,
        "implementation=" <> implementationText ((.implementation) transition),
        "guard=" <> maybe "" renderExpr ((.guard) transition),
        "writes=" <> T.intercalate ";" [name <> ":=" <> renderExpr expression | (name, expression) <- (.writes) transition],
        "events=" <> T.intercalate "," ((.emits) transition),
        "outputs=" <> T.intercalate "," (map eventOutputCanonical mappings),
        "target=" <> (.goto) transition
      ]
        ++ outcomeSegments
    )
  where
    outcomeSegments = case (.domainOutcomeTypes) aggregate of
      Nothing -> []
      Just declaration ->
        [ "outcome-rejection-type=" <> (.rejectionType) declaration,
          "outcome-no-op-type=" <> (.noOpType) declaration,
          "domain-outcome=" <> canonicalTransitionOutcome ((.outcome) transition)
        ]

canonicalKey :: Text -> BehaviorKey
canonicalKey canonical = BehaviorKey ("behavior-v1-" <> fnv1a64 canonical)

outputEvidence :: EventOutputMapping -> OutputEvidence
outputEvidence mapping = case mapping of
  GeneratedCommandIdentity command _ -> GeneratedOutput command
  HandOwnedEventOutput obligation -> HandOwnedOutput obligation

transitionEvidence :: Transition -> EvidenceLevel
transitionEvidence transition = case (.implementation) transition of
  LegacyHoleImplementation -> LegacyRuntimeWitness
  GeneratedImplementation -> GeneratedAuthoritative
  HoleImplementation -> HoleWitnessed

aggregateEvidence :: Aggregate -> EvidenceLevel
aggregateEvidence aggregate
  | any ((/= LegacyHoleImplementation) . (.implementation)) ((.transitions) aggregate) = GeneratedAuthoritative
  | otherwise = LegacyRuntimeWitness

cellGuardCoverage :: [Transition] -> GuardCoverage
cellGuardCoverage transitions
  | any ((== Nothing) . (.guard)) transitions = GuardTotal
  | any crossesOneWayProjection guards = GuardUnknown
  | complementary = GuardTotal
  | all isLiteralFalse guards = GuardPartial
  | otherwise = GuardUnknown
  where
    guards = [guard | transition <- transitions, Just guard <- [(.guard) transition]]
    complementary = or [left == complementExpr right | left <- guards, right <- guards, left /= right]
    isLiteralFalse (EAtom (ABool False)) = True
    isLiteralFalse _ = False

crossesOneWayProjection :: Expr -> Bool
crossesOneWayProjection expression = case expression of
  EOr left right -> crossesOneWayProjection left || crossesOneWayProjection right
  EAnd left right -> crossesOneWayProjection left || crossesOneWayProjection right
  ECmp _ left right -> crossesOneWayProjection left || crossesOneWayProjection right
  EAdd _ left right -> crossesOneWayProjection left || crossesOneWayProjection right
  ESubtract _ left right -> crossesOneWayProjection left || crossesOneWayProjection right
  EMultiply _ left right -> crossesOneWayProjection left || crossesOneWayProjection right
  EPath _ _ (_ : _ : _) -> True
  EPath {} -> False
  ELiteral {} -> False
  EAtom {} -> False

replayGuardCoverage :: Transition -> GuardCoverage
replayGuardCoverage transition
  | maybe False crossesOneWayProjection ((.guard) transition) = GuardUnknown
  | otherwise = GuardNotApplicable

liveReachableStates :: Aggregate -> Set Name
liveReachableStates aggregate = case map (\state -> state.name) ((.states) aggregate) of
  [] -> Set.empty
  initial : _ -> go (Set.singleton initial) [initial]
  where
    go seen [] = seen
    go seen (source : remaining) =
      let next =
            [ (.goto) transition
            | transition <- (.transitions) aggregate,
              (.mode) transition == TmLive,
              (.source) transition == source,
              (.goto) transition `Set.notMember` seen
            ]
       in go (foldr Set.insert seen next) (remaining <> next)

rejectIdentityDefects :: [BehaviorRequirement] -> Either [BehaviorDerivationError] ()
rejectIdentityDefects requirements = case duplicateErrors <> collisionErrors of
  [] -> Right ()
  errors -> Left errors
  where
    byCanonical = groupsOn (.canonical) requirements
    duplicateErrors =
      [ DuplicateBehaviorIdentity canonicalIdentity (map (\requirement -> requirement.location) duplicates)
      | duplicates@(first : _ : _) <- byCanonical,
        let canonicalIdentity = (.canonical) first
      ]
    byKey = groupsOn (.key) requirements
    collisionErrors =
      [ BehaviorKeyCollision behaviorKey canonicals
      | collisions@(first : _ : _) <- byKey,
        let behaviorKey = (.key) first,
        let canonicals = Set.toAscList (Set.fromList (map (\requirement -> requirement.canonical) collisions)),
        length canonicals > 1
      ]

groupsOn :: (Ord key) => (value -> key) -> [value] -> [[value]]
groupsOn key = groupBy (\left right -> key left == key right) . sortOn key

renderBehaviorObligationsText :: BehaviorObligationsReport -> Text
renderBehaviorObligationsText report =
  T.unlines
    ( [ "behavior obligations: " <> T.pack ((.subject) report),
        "schema: keiro-dsl/behavior-obligations/1",
        "required: " <> tshow (length ((.requirements) report))
      ]
        <> map renderRequirement ((.requirements) report)
    )
  where
    renderRequirement requirement =
      unBehaviorKey ((.key) requirement)
        <> " "
        <> obligationKindText ((.kind) requirement)
        <> " "
        <> (.aggregate) requirement
        <> ":"
        <> (.source) requirement
        <> " -- "
        <> (.command) requirement
        <> " ["
        <> evidenceLevelText ((.evidence) requirement)
        <> ", guard="
        <> guardCoverageText ((.guardCoverage) requirement)
        <> "]"
        <> maybe (renderLineOnly requirement) renderExact ((.exactLocation) requirement)
    renderExact exact =
      " "
        <> T.pack ((.sourceFile) exact)
        <> ":"
        <> tshow ((.sourceLine) exact)
        <> ":"
        <> tshow ((.sourceColumn) exact)
        <> " [location-quality=exact]"
    renderLineOnly requirement =
      " line "
        <> tshow (unLoc ((.location) requirement))
        <> " [location-quality=line-only]"

encodeBehaviorObligationsJson :: BehaviorObligationsReport -> Text
encodeBehaviorObligationsJson = Text.decodeUtf8 . BL.toStrict . Aeson.encode

obligationKindText :: ObligationKind -> Text
obligationKindText kind = case kind of
  LiveTransition -> "live-transition"
  RequiredRejection -> "required-rejection"
  ReplayTransition -> "replay-transition"

evidenceLevelText :: EvidenceLevel -> Text
evidenceLevelText evidence = case evidence of
  GeneratedAuthoritative -> "generated-authoritative"
  HoleWitnessed -> "hole-witnessed"
  LegacyRuntimeWitness -> "legacy-runtime-witness"

guardCoverageText :: GuardCoverage -> Text
guardCoverageText coverage = case coverage of
  GuardTotal -> "proved-total"
  GuardPartial -> "provably-partial"
  GuardUnknown -> "unknown"
  GuardNotApplicable -> "not-applicable"

transitionModeText :: TransitionMode -> Text
transitionModeText mode = case mode of
  TmLive -> "live"
  TmReplayOnly -> "replay-only"

implementationText :: TransitionImplementation -> Text
implementationText implementation = case implementation of
  LegacyHoleImplementation -> "legacy-hole"
  GeneratedImplementation -> "generated"
  HoleImplementation -> "hole"

tshow :: (Show value) => value -> Text
tshow = T.pack . show
