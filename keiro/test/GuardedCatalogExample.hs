{-# LANGUAGE DataKinds #-}

-- | Executable consumer fixture. The identity index is command authority;
-- payload maintenance belongs to the independent asynchronous owner.
module GuardedCatalogExample where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Core
import Keiki.Core qualified as Keiki
import Keiro
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection
import Keiro.Projection.Catalog (SourceScope (AllStreams))
import Keiro.ReadModel (QueryCursorAuthority (..), ReadModel, ReadModelBlueprint (..), immediateReadModel)
import Keiro.ReadModel.Rebuild (registerProjectionCatalog)
import Keiro.Test.Postgres (StoreRunner (..))
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (..))
import Kiroku.Store.Types (EventType (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

data NoteRefusal = ExistingNote Text | GuardConfigurationFault Text
  deriving stock (Eq, Show)

-- Only ExistingNote maps to reuse. Framework faults and a missing/unsupported
-- binding remain distinct failures. No rolled-back position escapes this API.
ensureStateNoteExample :: StoreRunner -> Note -> IO (Either Text (Text, Bool))
ensureStateNoteExample (StoreRunner run) note = do
  outcome <- run (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (handler 1) (stream (noteId note)) (CreateNote (notePayload note)) catalog commandSet (noteGuard note))
  pure $ case outcome of
    Right (Right (PreconditionRefused (ExistingNote winner))) -> Right (winner, False)
    Right (Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}}))) -> Right (noteId note, True)
    other -> Left (Text.pack (show other))

noteGuard :: Note -> CatalogPreconditionContext -> Tx.Transaction (Either NoteRefusal ())
noteGuard note context = case catalogPreconditionBindings context of
  [binding] | binding ^. #writeGroupId == identityGroup && binding ^. #writeRevisionId == Nothing ->
    case resolvePhysicalTarget identityTarget (binding ^. #writePhysicalTargets) of
      Nothing -> pure (Left (GuardConfigurationFault "identity target missing"))
      Just table -> do
        winner <- Tx.statement (notePayload note) (identityLookup table)
        pure (maybe (Right ()) (Left . ExistingNote) winner)
  _ -> pure (Left (GuardConfigurationFault "unsupported identity serving binding"))

data NoteCommand = CreateNote Text | ArchiveNote Text | IgnoreNote | RejectNote | UnmatchedNote
  deriving stock (Eq, Show)

data NoteEvent = NoteCreated Text | NoteArchived Text | NoteAudited
  deriving stock (Eq, Show)

data NoteState = Ready deriving stock (Eq, Ord, Show, Enum, Bounded)

type NoteStream = EventStream (HsPred '[] NoteCommand) '[] NoteState NoteCommand NoteEvent

-- All identity components are canonical, non-null strings. Archive never
-- removes the mapping. This fixture has no delete or re-anchor command.
data Note = Note
  { noteId :: Text,
    anchorType :: Text,
    anchorId :: Text,
    propertyId :: Text,
    stateId :: Text,
    content :: Text,
    tags :: [Text],
    provenance :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

notePayload :: Note -> Text
notePayload = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode . canonicalNote

-- The application normalizes the same keys before both lookup and encoding.
canonicalNote :: Note -> Note
canonicalNote note =
  note
    { anchorType = Text.toCaseFold (Text.strip (anchorType note)),
      anchorId = Text.strip (anchorId note),
      propertyId = Text.strip (propertyId note),
      stateId = Text.strip (stateId note)
    }

exampleNote :: Text -> Text -> Note
exampleNote candidate key = Note candidate "intention" key "status" "ready" (Text.replicate 1024 "x") ["a", "b", "c", "d"] "original-source"

handler :: Int -> DomainCommandHandler (HsPred '[] NoteCommand) '[] NoteState NoteCommand NoteEvent Text Text
handler batch = DomainCommandHandler (validated batch) $ \context ->
  case context ^. #command of
    IgnoreNote -> SilentNoOp "unchanged"
    RejectNote -> SilentRejected "refused by domain"
    _ -> error "eventful command classified as silent"

validated :: Int -> ValidatedEventStream (HsPred '[] NoteCommand) '[] NoteState NoteCommand NoteEvent
validated batch = either (error . show) id (mkEventStream "state-note" raw)
  where
    raw =
      EventStream
        { transducer =
            SymTransducer
              { edgesOut =
                  const
                    [ edge (matchInCtor createCtor) (pack createCtor createdCtor (inpCtor createCtor #payload *: oNil) : replicate (batch - 1) (pack createCtor auditedCtor oNil)),
                      edge (matchInCtor archiveCtor) [pack archiveCtor archivedCtor (inpCtor archiveCtor #payload *: oNil)],
                      edge (matchInCtor ignoreCtor) [],
                      edge (matchInCtor rejectCtor) []
                    ],
                initial = Ready,
                initialRegs = RNil,
                isFinal = const False
              },
          initialState = Ready,
          initialRegisters = RNil,
          eventCodec = noteCodec,
          resolveStreamName = streamName,
          snapshotPolicy = Never,
          stateCodec = Nothing
        }
    edge predicate outputs = Edge predicate UKeep outputs Ready Keiki.Live

type Payload = '[ '("payload", Text)]

createCtor, archiveCtor :: InCtor NoteCommand Payload
createCtor = unavailableInCtor "CreateNote" (\case CreateNote p -> Just (RCons Proxy p RNil); _ -> Nothing) (\(RCons _ p RNil) -> CreateNote p)
archiveCtor = unavailableInCtor "ArchiveNote" (\case ArchiveNote p -> Just (RCons Proxy p RNil); _ -> Nothing) (\(RCons _ p RNil) -> ArchiveNote p)

ignoreCtor, rejectCtor :: InCtor NoteCommand '[]
ignoreCtor = unavailableInCtor "IgnoreNote" (\case IgnoreNote -> Just RNil; _ -> Nothing) (const IgnoreNote)
rejectCtor = unavailableInCtor "RejectNote" (\case RejectNote -> Just RNil; _ -> Nothing) (const RejectNote)

createdCtor, archivedCtor :: WireCtor NoteEvent (Text, ())
createdCtor = unavailableWireCtor "NoteCreated" (\case NoteCreated p -> Just (p, ()); _ -> Nothing) (NoteCreated . fst)
archivedCtor = unavailableWireCtor "NoteArchived" (\case NoteArchived p -> Just (p, ()); _ -> Nothing) (NoteArchived . fst)

auditedCtor :: WireCtor NoteEvent ()
auditedCtor = unavailableWireCtor "NoteAudited" (\case NoteAudited -> Just (); _ -> Nothing) (const NoteAudited)

noteCodec :: Codec NoteEvent
noteCodec =
  Codec
    { eventTypes = EventType "NoteCreated" :| [EventType "NoteArchived", EventType "NoteAudited"],
      eventType = \case NoteCreated _ -> EventType "NoteCreated"; NoteArchived _ -> EventType "NoteArchived"; NoteAudited -> EventType "NoteAudited",
      schemaVersion = 1,
      encode = \case NoteCreated p -> Aeson.String p; NoteArchived p -> Aeson.String p; NoteAudited -> Aeson.Null,
      decode = \(EventType kind) value -> case (kind, value) of
        ("NoteCreated", Aeson.String p) -> Right (NoteCreated p)
        ("NoteArchived", Aeson.String p) -> Right (NoteArchived p)
        ("NoteAudited", _) -> Right NoteAudited
        _ -> Left "invalid note event",
      upcasters = []
    }

identityGroup, richGroup :: RebuildGroupId
identityGroup = ident mkRebuildGroupId "note-identity-group"
richGroup = ident mkRebuildGroupId "note-rich-group"

identityTarget, richTarget :: TargetId
identityTarget = ident mkTargetId "note-identity-target"
richTarget = ident mkTargetId "note-rich-target"

identityOwner, richOwner :: ProjectionId
identityOwner = ident mkProjectionId "note-identity-owner"
richOwner = ident mkProjectionId "note-rich-owner"

noteSource :: SourceId
noteSource = ident mkSourceId "note-source"

noteSubscription :: SubscriptionId
noteSubscription = ident mkSubscriptionId "note-subscription"

noteDedup :: DedupKeyId
noteDedup = ident mkDedupKeyId "note-dedup"

ident :: (Show e) => (Text -> Either e a) -> Text -> a
ident constructor = either (error . show) id . constructor

site :: ClaimSite
site = ident mkClaimSite "guarded-note-example"

identityTable, richTable :: QualifiedTable
identityTable = QualifiedTable "app" "state_note_identity"
richTable = QualifiedTable "app" "state_notes"

identityDefinition, richDefinition :: ProjectionDefinition NoteEvent
identityDefinition = ProjectionDefinition identityOwner identityGroup (identityTarget :| []) (replay applyIdentity) (InlineHandler (InlineProjection "note-identity" applyIdentity) site :| []) site
richDefinition = ProjectionDefinition richOwner richGroup (richTarget :| []) (replay applyRich) (AsyncHandler richProjection noteSubscription noteDedup site :| []) site

commandSet, fullSet :: ProjectionSet NoteEvent
commandSet = ProjectionSet noteSource (identityDefinition :| []) site
fullSet = ProjectionSet noteSource (identityDefinition :| [richDefinition]) site

richProjection :: AsyncProjection
richProjection =
  AsyncProjection
    "note-rich"
    "note-rich-query"
    "note-rich-worker"
    ( \recorded -> case decodeNoteRecorded recorded of
        ReplayRelevant event -> applyRich event recorded
        _ -> pure ()
    )
    (^. #eventId)

replay :: (NoteEvent -> RecordedEvent -> Tx.Transaction ()) -> ProjectionReplayPolicy NoteEvent
replay applyEvent = Replayable (replayAdapterFromCodec noteCodec applyEvent)

decodeNoteRecorded :: RecordedEvent -> ReplayDecodeResult NoteEvent
decodeNoteRecorded = (^. #decodeForReplay) (replayAdapterFromCodec noteCodec applyRich)

catalogDefinition :: ProjectionCatalog
catalogDefinition =
  ProjectionCatalog
    { sources = [SourceDeclaration noteSource AllStreams "note-codec-v1" site],
      targets = [TargetDeclaration identityTarget identityTable ClearBeforeReplay [] site, TargetDeclaration richTarget richTable ClearBeforeReplay [] site],
      rebuildGroups = [RebuildGroupDeclaration identityGroup [identityTarget] [] site, RebuildGroupDeclaration richGroup [richTarget] [] site],
      projectionRevisions = [],
      externalReadContracts = [],
      subscriptions = [SubscriptionDeclaration noteSubscription "note-rich-worker" noteSource FromBeginning site],
      dedupKeys = [DedupKeyDeclaration noteDedup "note-rich" site],
      queryModels = [SomeQueryModelBinding (QueryModelBinding (ident mkQueryModelId "note-rich-query") richReadModel richGroup [richTarget] site)],
      projectionSets = [SomeProjectionSet fullSet]
    }

richReadModel :: ReadModel Text (Maybe Text)
richReadModel = immediateReadModel (ReadModelBlueprint "note-rich-query" "state_notes" "app" 1 "note-rich-v1" (DurableQueryCursor "note-rich-worker") (\candidate -> Tx.statement candidate richLookup))

richLookup :: Statement Text (Maybe Text)
richLookup = preparable "SELECT payload::text FROM app.state_notes WHERE note_id = $1" (E.param (E.nonNullable E.text)) (D.rowMaybe (D.column (D.nonNullable D.text)))

catalog :: ValidatedProjectionCatalog
catalog = case validateProjectionCatalog catalogDefinition of
  Success value -> value
  Failure diagnostics -> error (show diagnostics)

setup :: StoreRunner -> IO ()
setup (StoreRunner run) = do
  run (Store.runTransaction (Tx.sql (Encoding.encodeUtf8 setupSql))) >>= either (fail . show) pure
  run (registerProjectionCatalog catalog) >>= either (fail . show) (either (fail . show) (const (pure ())))

setupSql :: Text
setupSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.state_note_identity (
    anchor_type text NOT NULL, anchor_id text NOT NULL,
    property_id text NOT NULL, state_id text NOT NULL, note_id text NOT NULL,
    PRIMARY KEY (anchor_type, anchor_id, property_id, state_id));
  CREATE TABLE app.state_notes (note_id text PRIMARY KEY, payload jsonb NOT NULL, archived boolean NOT NULL DEFAULT false);
  CREATE TABLE app.guard_markers (marker text);
  """

applyIdentity, applyRich :: NoteEvent -> RecordedEvent -> Tx.Transaction ()
applyIdentity event _ = case event of
  NoteCreated payload -> Tx.statement payload insertIdentity
  _ -> pure ()
applyRich event _ = case event of
  NoteCreated payload -> Tx.statement payload (preparable "INSERT INTO app.state_notes(note_id,payload) SELECT $1::jsonb->>'noteId',$1::jsonb" textParam D.noResult)
  NoteArchived candidate -> Tx.statement candidate (preparable "UPDATE app.state_notes SET archived = true WHERE note_id = $1" textParam D.noResult)
  NoteAudited -> pure ()

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

insertIdentity :: Statement Text ()
insertIdentity = preparable "INSERT INTO app.state_note_identity SELECT $1::jsonb->>'anchorType',$1::jsonb->>'anchorId',$1::jsonb->>'propertyId',$1::jsonb->>'stateId',$1::jsonb->>'noteId'" textParam D.noResult

identityLookup :: QualifiedTable -> Statement Text (Maybe Text)
identityLookup table =
  preparable
    ("SELECT note_id FROM " <> qualifyTable (table ^. #schemaName) (table ^. #tableName) <> " WHERE anchor_type = $1::jsonb->>'anchorType' AND anchor_id = $1::jsonb->>'anchorId' AND property_id = $1::jsonb->>'propertyId' AND state_id = $1::jsonb->>'stateId'")
    textParam
    (D.rowMaybe (D.column (D.nonNullable D.text)))
