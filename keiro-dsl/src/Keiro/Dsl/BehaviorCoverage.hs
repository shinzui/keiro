{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Static behavioral obligations derivable from a validated aggregate graph.
--
-- This module deliberately knows nothing about consumer Haskell witnesses.  It
-- inventories the finite obligations the source graph requires; the generated
-- consumer contract reconciles and executes witness values in a later layer.
module Keiro.Dsl.BehaviorCoverage
  ( BehaviorKey (..),
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
import Keiro.Dsl.SourceIndex (TransitionOrdinal (..))

newtype BehaviorKey = BehaviorKey {unBehaviorKey :: Text}
  deriving stock (Eq, Ord, Show)

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
  { exactSourceFile :: !FilePath,
    exactSourceLine :: !Int,
    exactSourceColumn :: !Int
  }
  deriving stock (Eq, Ord, Show)

data BehaviorRequirement = BehaviorRequirement
  { requirementKey :: !BehaviorKey,
    requirementOrigin :: !RequirementOrigin,
    requirementKind :: !ObligationKind,
    requirementEvidence :: !EvidenceLevel,
    requirementGuardCoverage :: !GuardCoverage,
    requirementContext :: !Name,
    requirementAggregate :: !Name,
    requirementSource :: !Name,
    requirementCommand :: !Name,
    requirementTarget :: !(Maybe Name),
    requirementMode :: !(Maybe TransitionMode),
    requirementEvents :: ![Name],
    requirementOutputs :: ![OutputEvidence],
    requirementLocation :: !Loc,
    requirementExactLocation :: !(Maybe BehaviorExactLocation),
    requirementOwner :: !(Maybe FilePath),
    requirementCanonical :: !Text
  }
  deriving stock (Eq, Show)

-- | Forward-compatible record representation of one requirement.  Records
-- retain enough human-readable identity to report additions and removals
-- without re-reading or attempting to understand consumer Haskell.
data BehaviorRecordRow = BehaviorRecordRow
  { behaviorRecordKey :: !BehaviorKey,
    behaviorRecordKind :: !ObligationKind,
    behaviorRecordEvidence :: !EvidenceLevel,
    behaviorRecordAggregate :: !Name,
    behaviorRecordSource :: !Name,
    behaviorRecordCommand :: !Name,
    behaviorRecordOwner :: !(Maybe FilePath),
    behaviorRecordOutputs :: ![OutputEvidence]
  }
  deriving stock (Eq, Ord, Show)

data BehaviorDerivationError
  = InvalidEventOutput !Name !EventOutputError
  | EventlessStateChange !Name !Name !Name
  | DuplicateBehaviorIdentity !Text ![Loc]
  | BehaviorKeyCollision !BehaviorKey ![Text]
  deriving stock (Eq, Show)

data BehaviorObligationsReport = BehaviorObligationsReport
  { behaviorSubject :: !FilePath,
    behaviorWorkspaceService :: !(Maybe Text),
    behaviorRequirements :: ![BehaviorRequirement]
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
      ( [ "key" .= behaviorRecordKey row,
          "kind" .= behaviorRecordKind row,
          "evidence" .= behaviorRecordEvidence row,
          "aggregate" .= behaviorRecordAggregate row,
          "source" .= behaviorRecordSource row,
          "command" .= behaviorRecordCommand row,
          "outputs" .= behaviorRecordOutputs row
        ]
          <> ["owner" .= owner | Just owner <- [behaviorRecordOwner row]]
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
      [ "key" .= requirementKey requirement,
        "kind" .= requirementKind requirement,
        "evidence" .= requirementEvidence requirement,
        "guardCoverage" .= requirementGuardCoverage requirement,
        "context" .= requirementContext requirement,
        "aggregate" .= requirementAggregate requirement,
        "source" .= requirementSource requirement,
        "command" .= requirementCommand requirement,
        "target" .= requirementTarget requirement,
        "mode" .= fmap transitionModeText (requirementMode requirement),
        "events" .= requirementEvents requirement,
        "outputs" .= requirementOutputs requirement,
        "location"
          .= object
            ( ["line" .= maybe (unLoc (requirementLocation requirement)) exactSourceLine (requirementExactLocation requirement)]
                <> ["member" .= owner | Just owner <- [requirementOwner requirement]]
                <> ["file" .= exactSourceFile exact | Just exact <- [requirementExactLocation requirement]]
                <> ["column" .= exactSourceColumn exact | Just exact <- [requirementExactLocation requirement]]
                <> ["quality" .= maybe ("line-only" :: Text) (const "exact") (requirementExactLocation requirement)]
            )
      ]

instance ToJSON BehaviorObligationsReport where
  toJSON report =
    object
      ( [ "schema" .= ("keiro-dsl/behavior-obligations/1" :: Text),
          "subject" .= behaviorSubject report,
          "requirements" .= behaviorRequirements report
        ]
          <> ["workspace" .= object ["service" .= service] | Just service <- [behaviorWorkspaceService report]]
      )

deriveBehaviorRequirements :: Spec -> Either [BehaviorDerivationError] [BehaviorRequirement]
deriveBehaviorRequirements spec = case fmap concat (traverse (deriveAggregateBehaviorRequirements spec) aggregates) of
  Left derivationError -> Left [derivationError]
  Right raw -> do
    rejectIdentityDefects raw
    pure (sortOn requirementKey raw)
  where
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]

deriveAggregateBehaviorRequirements :: Spec -> Aggregate -> Either BehaviorDerivationError [BehaviorRequirement]
deriveAggregateBehaviorRequirements spec aggregate = do
  let reachable = liveReachableStates aggregate
      indexedTransitions = zip (map TransitionOrdinal [0 ..]) (aggTransitions aggregate)
      liveTransitions =
        [ (ordinal, transition)
        | (ordinal, transition) <- indexedTransitions,
          tMode transition == TmLive,
          tSource transition `Set.member` reachable
        ]
      replayTransitions = [(ordinal, transition) | (ordinal, transition) <- indexedTransitions, tMode transition == TmReplayOnly]
      commands = map cmdName (aggCommands aggregate)
      cells = [(state, command) | state <- Set.toAscList reachable, command <- commands]
      cellTransitions state command =
        [ (ordinal, transition)
        | (ordinal, transition) <- liveTransitions,
          tSource transition == state,
          tCommand transition == command
        ]
      transitionRows =
        [ transitionRequirement spec aggregate (cellGuardCoverage (map snd siblings)) ordinal transition
        | (state, command) <- cells,
          let siblings = cellTransitions state command,
          (ordinal, transition) <- siblings
        ]
      rejectionRows =
        [ pure (rejectionRequirement spec aggregate state command)
        | (state, command) <- cells,
          null (cellTransitions state command)
        ]
      replayRows = [transitionRequirement spec aggregate (replayGuardCoverage transition) ordinal transition | (ordinal, transition) <- replayTransitions]
  sequence (transitionRows <> rejectionRows <> replayRows)

behaviorRecordRows :: [BehaviorRequirement] -> [BehaviorRecordRow]
behaviorRecordRows = map toRow
  where
    toRow requirement =
      BehaviorRecordRow
        { behaviorRecordKey = requirementKey requirement,
          behaviorRecordKind = requirementKind requirement,
          behaviorRecordEvidence = requirementEvidence requirement,
          behaviorRecordAggregate = requirementAggregate requirement,
          behaviorRecordSource = requirementSource requirement,
          behaviorRecordCommand = requirementCommand requirement,
          behaviorRecordOwner = requirementOwner requirement,
          behaviorRecordOutputs = requirementOutputs requirement
        }

attributeBehaviorOwner :: (Name -> Maybe FilePath) -> BehaviorRequirement -> BehaviorRequirement
attributeBehaviorOwner ownerForAggregate requirement =
  requirement {requirementOwner = ownerForAggregate (requirementAggregate requirement)}

behaviorObligationsReport :: FilePath -> Spec -> Either [BehaviorDerivationError] BehaviorObligationsReport
behaviorObligationsReport subject spec =
  BehaviorObligationsReport subject Nothing <$> deriveBehaviorRequirements spec

transitionRequirement :: Spec -> Aggregate -> GuardCoverage -> TransitionOrdinal -> Transition -> Either BehaviorDerivationError BehaviorRequirement
transitionRequirement spec aggregate guardCoverage ordinal transition = do
  if null (tEmits transition) && (tSource transition /= tGoto transition || not (null (tWrites transition)))
    then Left (EventlessStateChange (aggName aggregate) (tSource transition) (tCommand transition))
    else pure ()
  mappings <-
    traverse
      (\(emitIndex, eventName) -> either (Left . InvalidEventOutput eventName) Right (eventOutputMapping spec aggregate transition emitIndex eventName))
      (zip [1 ..] (tEmits transition))
  let kind = if tMode transition == TmLive then LiveTransition else ReplayTransition
      outputs = map outputEvidence mappings
      canonical = transitionCanonical spec aggregate kind transition mappings
  pure
    BehaviorRequirement
      { requirementKey = canonicalKey canonical,
        requirementOrigin = TransitionRequirementOrigin (aggName aggregate) ordinal,
        requirementKind = kind,
        requirementEvidence = transitionEvidence transition,
        requirementGuardCoverage = guardCoverage,
        requirementContext = specContext spec,
        requirementAggregate = aggName aggregate,
        requirementSource = tSource transition,
        requirementCommand = tCommand transition,
        requirementTarget = Just (tGoto transition),
        requirementMode = Just (tMode transition),
        requirementEvents = tEmits transition,
        requirementOutputs = outputs,
        requirementLocation = tLoc transition,
        requirementExactLocation = Nothing,
        requirementOwner = Nothing,
        requirementCanonical = canonical
      }

rejectionRequirement :: Spec -> Aggregate -> Name -> Name -> BehaviorRequirement
rejectionRequirement spec aggregate state command =
  BehaviorRequirement
    { requirementKey = canonicalKey canonical,
      requirementOrigin = RejectionRequirementOrigin (aggName aggregate) state,
      requirementKind = RequiredRejection,
      requirementEvidence = aggregateEvidence aggregate,
      requirementGuardCoverage = GuardNotApplicable,
      requirementContext = specContext spec,
      requirementAggregate = aggName aggregate,
      requirementSource = state,
      requirementCommand = command,
      requirementTarget = Nothing,
      requirementMode = Nothing,
      requirementEvents = [],
      requirementOutputs = [],
      requirementLocation = maybe (aggLoc aggregate) stLoc (find ((== state) . stName) (aggStates aggregate)),
      requirementExactLocation = Nothing,
      requirementOwner = Nothing,
      requirementCanonical = canonical
    }
  where
    canonical =
      T.intercalate
        "|"
        [ "behavior-v1",
          "kind=rejection",
          "context=" <> specContext spec,
          "aggregate=" <> aggName aggregate,
          "source=" <> state,
          "command=" <> command
        ]

transitionCanonical :: Spec -> Aggregate -> ObligationKind -> Transition -> [EventOutputMapping] -> Text
transitionCanonical spec aggregate kind transition mappings =
  T.intercalate
    "|"
    ( [ "behavior-v1",
        "kind=" <> obligationKindText kind,
        "context=" <> specContext spec,
        "aggregate=" <> aggName aggregate,
        "mode=" <> transitionModeText (tMode transition),
        "source=" <> tSource transition,
        "command=" <> tCommand transition,
        "implementation=" <> implementationText (tImplementation transition),
        "guard=" <> maybe "" renderExpr (tGuard transition),
        "writes=" <> T.intercalate ";" [name <> ":=" <> renderExpr expression | (name, expression) <- tWrites transition],
        "events=" <> T.intercalate "," (tEmits transition),
        "outputs=" <> T.intercalate "," (map eventOutputCanonical mappings),
        "target=" <> tGoto transition
      ]
        ++ outcomeSegments
    )
  where
    outcomeSegments = case aggDomainOutcomeTypes aggregate of
      Nothing -> []
      Just declaration ->
        [ "outcome-rejection-type=" <> rejectionType declaration,
          "outcome-no-op-type=" <> noOpType declaration,
          "domain-outcome=" <> canonicalTransitionOutcome (tOutcome transition)
        ]

canonicalKey :: Text -> BehaviorKey
canonicalKey canonical = BehaviorKey ("behavior-v1-" <> fnv1a64 canonical)

outputEvidence :: EventOutputMapping -> OutputEvidence
outputEvidence mapping = case mapping of
  GeneratedCommandIdentity command _ -> GeneratedOutput command
  HandOwnedEventOutput obligation -> HandOwnedOutput obligation

transitionEvidence :: Transition -> EvidenceLevel
transitionEvidence transition = case tImplementation transition of
  LegacyHoleImplementation -> LegacyRuntimeWitness
  GeneratedImplementation -> GeneratedAuthoritative
  HoleImplementation -> HoleWitnessed

aggregateEvidence :: Aggregate -> EvidenceLevel
aggregateEvidence aggregate
  | any ((/= LegacyHoleImplementation) . tImplementation) (aggTransitions aggregate) = GeneratedAuthoritative
  | otherwise = LegacyRuntimeWitness

cellGuardCoverage :: [Transition] -> GuardCoverage
cellGuardCoverage transitions
  | any ((== Nothing) . tGuard) transitions = GuardTotal
  | any crossesOneWayProjection guards = GuardUnknown
  | complementary = GuardTotal
  | all isLiteralFalse guards = GuardPartial
  | otherwise = GuardUnknown
  where
    guards = [guard | transition <- transitions, Just guard <- [tGuard transition]]
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
  | maybe False crossesOneWayProjection (tGuard transition) = GuardUnknown
  | otherwise = GuardNotApplicable

liveReachableStates :: Aggregate -> Set Name
liveReachableStates aggregate = case map stName (aggStates aggregate) of
  [] -> Set.empty
  initial : _ -> go (Set.singleton initial) [initial]
  where
    go seen [] = seen
    go seen (source : remaining) =
      let next =
            [ tGoto transition
            | transition <- aggTransitions aggregate,
              tMode transition == TmLive,
              tSource transition == source,
              tGoto transition `Set.notMember` seen
            ]
       in go (foldr Set.insert seen next) (remaining <> next)

rejectIdentityDefects :: [BehaviorRequirement] -> Either [BehaviorDerivationError] ()
rejectIdentityDefects requirements = case duplicateErrors <> collisionErrors of
  [] -> Right ()
  errors -> Left errors
  where
    byCanonical = groupsOn requirementCanonical requirements
    duplicateErrors =
      [ DuplicateBehaviorIdentity canonical (map requirementLocation duplicates)
      | duplicates@(first : _ : _) <- byCanonical,
        let canonical = requirementCanonical first
      ]
    byKey = groupsOn requirementKey requirements
    collisionErrors =
      [ BehaviorKeyCollision key canonicals
      | collisions@(first : _ : _) <- byKey,
        let key = requirementKey first,
        let canonicals = Set.toAscList (Set.fromList (map requirementCanonical collisions)),
        length canonicals > 1
      ]

groupsOn :: (Ord key) => (value -> key) -> [value] -> [[value]]
groupsOn key = groupBy (\left right -> key left == key right) . sortOn key

renderBehaviorObligationsText :: BehaviorObligationsReport -> Text
renderBehaviorObligationsText report =
  T.unlines
    ( [ "behavior obligations: " <> T.pack (behaviorSubject report),
        "schema: keiro-dsl/behavior-obligations/1",
        "required: " <> tshow (length (behaviorRequirements report))
      ]
        <> map renderRequirement (behaviorRequirements report)
    )
  where
    renderRequirement requirement =
      unBehaviorKey (requirementKey requirement)
        <> " "
        <> obligationKindText (requirementKind requirement)
        <> " "
        <> requirementAggregate requirement
        <> ":"
        <> requirementSource requirement
        <> " -- "
        <> requirementCommand requirement
        <> " ["
        <> evidenceLevelText (requirementEvidence requirement)
        <> ", guard="
        <> guardCoverageText (requirementGuardCoverage requirement)
        <> "]"
        <> maybe (renderLineOnly requirement) renderExact (requirementExactLocation requirement)
    renderExact exact =
      " "
        <> T.pack (exactSourceFile exact)
        <> ":"
        <> tshow (exactSourceLine exact)
        <> ":"
        <> tshow (exactSourceColumn exact)
        <> " [location-quality=exact]"
    renderLineOnly requirement =
      " line "
        <> tshow (unLoc (requirementLocation requirement))
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
