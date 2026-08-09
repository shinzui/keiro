-- | Operational adapters for Kiroku stream reads and lifecycle operations.
--
-- Every database action is a public @kiroku-store@ operation, preserving that
-- library's schema ownership under ADR 28.
module Keiro.Ops.Stream
  ( Command (..),
    TruncateCommand (..),
    commandParser,
    isMutation,
    runCommand,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Render
import Keiro.Ops.Snapshot qualified as Snapshot
import Kiroku.Store.Causation (findCausationAncestors, findCausationDescendants)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Lifecycle
import Kiroku.Store.Read (getStream, lookupStreamNames, readStreamForward)
import Kiroku.Store.Subscription
  ( SubscriptionCheckpoint (..),
    SubscriptionCheckpointInventory (..),
    SubscriptionName (..),
    subscriptionCheckpointInventory,
  )
import Kiroku.Store.Types
import Options.Applicative hiding (action, info, value)
import Options.Applicative qualified as Opt
import System.IO (hFlush, stdout)

data Command
  = Show !Text !StreamVersion !Int
  | SoftDelete !Text
  | Undelete !Text
  | HardDelete !Text
  | TruncateBefore !TruncateCommand
  | Causation !EventId
  | Subscriptions
  deriving stock (Eq, Show)

data TruncateCommand
  = SetTruncateBefore !Text !StreamVersion !(Maybe Snapshot.ExpectedDiscriminators) !Bool
  | ClearTruncateBefore !Text
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "show" (Opt.info showParser (progDesc "Show stream metadata and ordered events"))
        <> command "soft-delete" (Opt.info (SoftDelete <$> streamArgument) (progDesc "Preview or soft-delete a stream"))
        <> command "undelete" (Opt.info (Undelete <$> streamArgument) (progDesc "Preview or restore a soft-deleted stream"))
        <> command "hard-delete" (Opt.info (HardDelete <$> streamArgument) (progDesc "Preview or permanently delete a stream"))
        <> command "truncate-before" (Opt.info (TruncateBefore <$> truncateParser) (progDesc "Operate the reversible stream visibility marker"))
        <> command "causation" (Opt.info (Causation <$> eventIdArgument) (progDesc "Show an event's causation ancestors and descendants"))
        <> command "subscriptions" (Opt.info (pure Subscriptions) (progDesc "List durable subscription checkpoints"))
    )
  where
    showParser =
      Show
        <$> streamArgument
        <*> (StreamVersion <$> option nonNegativeInt64Reader (long "from" <> metavar "VERSION" <> Opt.value 0 <> showDefault <> help "Exclusive stream-version cursor"))
        <*> option positiveIntReader (long "limit" <> metavar "N" <> Opt.value 100 <> showDefault <> help "Maximum events")

truncateParser :: Parser TruncateCommand
truncateParser =
  hsubparser
    ( command "set" (Opt.info setParser (progDesc "Preview or set a truncate-before marker after snapshot preflight"))
        <> command "clear" (Opt.info (ClearTruncateBefore <$> streamArgument) (progDesc "Preview or clear a truncate-before marker"))
    )
  where
    setParser =
      SetTruncateBefore
        <$> streamArgument
        <*> (StreamVersion <$> argument nonNegativeInt64Reader (metavar "VERSION"))
        <*> optional expectedParser
        <*> switch (long "skip-preflight" <> help "Bypass snapshot coverage checking (dangerous)")
    expectedParser =
      Snapshot.ExpectedDiscriminators
        <$> option nonNegativeIntReader (long "state-codec-version" <> metavar "N" <> help "Application's current state codec version")
        <*> textOption "regfile-shape-hash" "HASH" "Application's current register-layout hash"
        <*> textOption "state-shape-hash" "HASH" "Application's current control-state/fold hash"

streamArgument :: Parser Text
streamArgument = Text.pack <$> argument str (metavar "STREAM")

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText = Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

eventIdArgument :: Parser EventId
eventIdArgument = EventId <$> argument uuidReader (metavar "EVENT_ID")

uuidReader :: ReadM UUID
uuidReader = eitherReader $ \raw -> maybe (Left "expected a UUID event id") Right (UUID.fromString raw)

positiveIntReader :: ReadM Int
positiveIntReader = eitherReader $ \raw ->
  case reads raw of
    [(n, "")] | n > 0 -> Right n
    _ -> Left "expected a positive integer"

nonNegativeIntReader :: ReadM Int
nonNegativeIntReader = eitherReader $ \raw ->
  case reads raw of
    [(n, "")] | n >= 0 -> Right n
    _ -> Left "expected a non-negative integer"

nonNegativeInt64Reader :: ReadM Int64
nonNegativeInt64Reader = eitherReader $ \raw ->
  case reads raw of
    [(n, "")] | n >= 0 -> Right n
    _ -> Left "expected a non-negative stream version"

isMutation :: Command -> Bool
isMutation = \case
  Show {} -> False
  Causation {} -> False
  Subscriptions -> False
  SoftDelete {} -> True
  Undelete {} -> True
  HardDelete {} -> True
  TruncateBefore {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Show name from limit -> runShow env name from limit
  SoftDelete name -> runLifecycle env "soft-delete" name (softDeleteStream (StreamName name))
  Undelete name -> runLifecycle env "undelete" name (undeleteStream (StreamName name))
  HardDelete name -> runHardDelete env name
  TruncateBefore truncateCommand -> runTruncate env truncateCommand
  Causation eventId -> runCausation env eventId
  Subscriptions -> runSubscriptions env

runSubscriptions :: OpsEnv -> IO OpsOutcome
runSubscriptions env =
  runAction env subscriptionCheckpointInventory (Succeeded . subscriptionInventoryResult)

subscriptionInventoryResult :: SubscriptionCheckpointInventory -> OpsResult
subscriptionInventoryResult inventory =
  OpsResult
    { headers = ["subscription", "member", "checkpoint_position", "checkpoint_updated_at", "store_position", "global_position_distance"],
      rows = map (checkpointRow captured) durableCheckpoints,
      jsonValue =
        object
          [ "store_position" .= positionInt captured,
            "checkpoints" .= map (checkpointJson captured) durableCheckpoints
          ]
    }
  where
    captured = storePosition inventory
    durableCheckpoints = Vector.toList (checkpoints inventory)

checkpointRow :: GlobalPosition -> SubscriptionCheckpoint -> [Text]
checkpointRow captured (SubscriptionCheckpoint (SubscriptionName name) member position updatedAt) =
  [ name,
    showText member,
    positionText position,
    utcText updatedAt,
    positionText captured,
    showText (globalPositionDistance captured position)
  ]

checkpointJson :: GlobalPosition -> SubscriptionCheckpoint -> Value
checkpointJson captured (SubscriptionCheckpoint (SubscriptionName name) member position updatedAt) =
  object
    [ "subscription" .= name,
      "member" .= member,
      "checkpoint_position" .= positionInt position,
      "checkpoint_updated_at" .= updatedAt,
      "global_position_distance" .= globalPositionDistance captured position
    ]

globalPositionDistance :: GlobalPosition -> GlobalPosition -> Int64
globalPositionDistance (GlobalPosition captured) (GlobalPosition checkpoint) = max 0 (captured - checkpoint)

utcText :: UTCTime -> Text
utcText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

runShow :: OpsEnv -> Text -> StreamVersion -> Int -> IO OpsOutcome
runShow env name from limit =
  runAction env action $ \(info, events) -> Succeeded (streamResult name info events)
  where
    action = do
      info <- getStream (StreamName name)
      events <- readStreamForward (StreamName name) from (fromIntegral limit)
      pure (info, Vector.toList events)

runLifecycle :: OpsEnv -> Text -> Text -> Eff '[Store, Error StoreError, IOE] (Maybe StreamId) -> IO OpsOutcome
runLifecycle env operation name action
  | not env.force =
      runAction env (getStream (StreamName name)) $ \info ->
        PreviewRequired
          (lifecycleResult True operation name info Nothing)
          (forceInvocation env ["stream", operation, name])
  | otherwise =
      runAction env mutation $ \(before, outcome) ->
        Succeeded (lifecycleResult False operation name before outcome)
  where
    mutation = do
      before <- getStream (StreamName name)
      outcome <- action
      pure (before, outcome)

runHardDelete :: OpsEnv -> Text -> IO OpsOutcome
runHardDelete env name
  | not env.force = runLifecycle env "hard-delete" name (hardDeleteStream (StreamName name))
  | otherwise = do
      confirmed <- confirmDestructive env name
      if confirmed
        then runLifecycle env "hard-delete" name (hardDeleteStream (StreamName name))
        else pure (Failed "stream-name confirmation did not match; hard delete cancelled")

runTruncate :: OpsEnv -> TruncateCommand -> IO OpsOutcome
runTruncate env = \case
  ClearTruncateBefore name -> runClearTruncate env name
  SetTruncateBefore name before expected skipPreflight -> runSetTruncate env name before expected skipPreflight

runClearTruncate :: OpsEnv -> Text -> IO OpsOutcome
runClearTruncate env name
  | not env.force =
      runAction env (getStream (StreamName name)) $ \streamInfo ->
        PreviewRequired
          (lifecycleResult True "truncate-before clear" name streamInfo Nothing)
          (forceInvocation env ["stream", "truncate-before", "clear", name])
  | otherwise =
      runAction env action $ \(streamInfo, outcome) ->
        Succeeded (lifecycleResult False "truncate-before clear" name streamInfo outcome)
  where
    action = do
      streamInfo <- getStream (StreamName name)
      outcome <- clearStreamTruncateBefore (StreamName name)
      pure (streamInfo, outcome)

runSetTruncate :: OpsEnv -> Text -> StreamVersion -> Maybe Snapshot.ExpectedDiscriminators -> Bool -> IO OpsOutcome
runSetTruncate env name before expected skipPreflight = do
  checked <-
    if skipPreflight
      then pure Nothing
      else do
        outcome <- runStoreIO env.store (Snapshot.preflightFor name before expected)
        case outcome of
          Left storeError -> pure (Just (Left (Text.pack (show storeError))))
          Right evidence -> pure (Just (Right evidence))
  case checked of
    Just (Left message) -> pure (Failed message)
    Just (Right evidence)
      | not evidence.passed ->
          pure (Failed ("snapshot preflight failed: " <> evidence.reason))
    _
      | not env.force ->
          runAction env (getStream (StreamName name)) $ \info ->
            PreviewRequired
              (truncateResult True name before info checked)
              (forceInvocation env (setArguments name before expected skipPreflight))
      | otherwise -> do
          confirmed <- confirmDestructive env name
          if not confirmed
            then pure (Failed "stream-name confirmation did not match; truncate-before cancelled")
            else runAction env action $ \(info, outcome) ->
              Succeeded (truncateMutationResult name before info outcome checked)
  where
    action = do
      info <- getStream (StreamName name)
      outcome <- setStreamTruncateBefore (StreamName name) before
      pure (info, outcome)

setArguments :: Text -> StreamVersion -> Maybe Snapshot.ExpectedDiscriminators -> Bool -> [Text]
setArguments name before expected skipPreflight =
  ["stream", "truncate-before", "set", name, versionText before]
    <> maybe [] discriminatorArguments expected
    <> ["--skip-preflight" | skipPreflight]

discriminatorArguments :: Snapshot.ExpectedDiscriminators -> [Text]
discriminatorArguments expected =
  [ "--state-codec-version",
    showText expected.stateCodecVersion,
    "--regfile-shape-hash",
    expected.regfileShapeHash,
    "--state-shape-hash",
    expected.stateShapeHash
  ]

confirmDestructive :: OpsEnv -> Text -> IO Bool
confirmDestructive env name
  | env.outputMode == Json = pure True
  | otherwise = do
      Text.IO.putStr ("type the stream name to confirm: " <> name <> "\n> ")
      hFlush stdout
      entered <- Text.IO.getLine
      pure (entered == name)

runCausation :: OpsEnv -> EventId -> IO OpsOutcome
runCausation env eventId =
  runAction env action $ \(ancestors, descendants, names) ->
    Succeeded (causationResult eventId ancestors descendants names)
  where
    action = do
      ancestors <- Vector.toList <$> findCausationAncestors eventId
      descendants <- Vector.toList <$> findCausationDescendants eventId
      names <- lookupStreamNames (map (.originalStreamId) (ancestors <> descendants))
      pure (ancestors, descendants, names)

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] a -> (a -> OpsOutcome) -> IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

streamResult :: Text -> Maybe StreamInfo -> [RecordedEvent] -> OpsResult
streamResult name info events =
  OpsResult
    { headers = ["stream", "version", "event_id", "event_type", "global_position", "created_at", "payload"],
      rows = map eventRow events,
      jsonValue = object ["stream" .= streamInfoJson name info, "events" .= map (eventJson Nothing) events]
    }
  where
    eventRow event =
      [ name,
        versionText event.streamVersion,
        eventIdText event.eventId,
        eventTypeText event.eventType,
        positionText event.globalPosition,
        showText event.createdAt,
        truncateCell 120 (jsonText event.payload)
      ]

streamInfoJson :: Text -> Maybe StreamInfo -> Value
streamInfoJson name = \case
  Nothing -> object ["name" .= name, "exists" .= False]
  Just info ->
    object
      [ "name" .= name,
        "exists" .= True,
        "stream_id" .= streamIdInt info.id,
        "version" .= versionInt info.version,
        "created_at" .= info.createdAt,
        "deleted_at" .= info.deletedAt,
        "truncate_before" .= versionInt info.truncateBefore
      ]

eventJson :: Maybe Text -> RecordedEvent -> Value
eventJson direction event =
  object
    [ "direction" .= direction,
      "event_id" .= eventIdText event.eventId,
      "event_type" .= eventTypeText event.eventType,
      "stream_version" .= versionInt event.streamVersion,
      "global_position" .= positionInt event.globalPosition,
      "original_stream_id" .= streamIdInt event.originalStreamId,
      "original_version" .= versionInt event.originalVersion,
      "payload" .= event.payload,
      "metadata" .= event.metadata,
      "causation_id" .= fmap UUID.toText event.causationId,
      "correlation_id" .= fmap UUID.toText event.correlationId,
      "created_at" .= event.createdAt
    ]

lifecycleResult :: Bool -> Text -> Text -> Maybe StreamInfo -> Maybe StreamId -> OpsResult
lifecycleResult preview operation name info outcome =
  OpsResult
    { headers = ["operation", "stream", "current_state", "disposition"],
      rows = [[operation, name, maybe "not_found" streamState info, disposition]],
      jsonValue = object ["preview" .= preview, "operation" .= operation, "stream" .= streamInfoJson name info, "affected_stream_id" .= fmap streamIdInt outcome, "disposition" .= disposition]
    }
  where
    disposition
      | preview = maybe "not_found" (const ("would_" <> Text.replace " " "_" operation)) info
      | otherwise = maybe "not_transitioned" (const "transitioned") outcome

streamState :: StreamInfo -> Text
streamState info
  | info.deletedAt == Nothing = "live"
  | otherwise = "soft_deleted"

truncateResult :: Bool -> Text -> StreamVersion -> Maybe StreamInfo -> Maybe (Either Text Snapshot.PreflightEvidence) -> OpsResult
truncateResult preview name before info checked =
  OpsResult
    { headers = ["stream", "current_marker", "new_marker", "preflight", "disposition"],
      rows = [[name, maybe "not_found" (versionText . (.truncateBefore)) info, versionText before, preflightText checked, if preview then "would_set" else "set"]],
      jsonValue = object ["preview" .= preview, "stream" .= streamInfoJson name info, "new_marker" .= versionInt before, "preflight" .= preflightJson checked]
    }

truncateMutationResult :: Text -> StreamVersion -> Maybe StreamInfo -> Maybe StreamId -> Maybe (Either Text Snapshot.PreflightEvidence) -> OpsResult
truncateMutationResult name before info outcome checked =
  (truncateResult False name before info checked)
    { rows = [[name, maybe "not_found" (versionText . (.truncateBefore)) info, versionText before, preflightText checked, maybe "not_transitioned" (const "set") outcome]],
      jsonValue = object ["preview" .= False, "stream" .= streamInfoJson name info, "new_marker" .= versionInt before, "preflight" .= preflightJson checked, "affected_stream_id" .= fmap streamIdInt outcome]
    }

preflightText :: Maybe (Either Text Snapshot.PreflightEvidence) -> Text
preflightText Nothing = "skipped"
preflightText (Just (Left message)) = "error: " <> message
preflightText (Just (Right evidence)) = if evidence.passed then "passed" else "failed: " <> evidence.reason

preflightJson :: Maybe (Either Text Snapshot.PreflightEvidence) -> Value
preflightJson Nothing = object ["skipped" .= True]
preflightJson (Just (Left message)) = object ["error" .= message]
preflightJson (Just (Right evidence)) =
  object
    [ "passed" .= evidence.passed,
      "reason" .= evidence.reason,
      "required_snapshot_version" .= versionInt evidence.requiredSnapshotVersion,
      "version_covered" .= evidence.versionCovered,
      "discriminators_match" .= evidence.discriminatorsMatch
    ]

causationResult :: EventId -> [RecordedEvent] -> [RecordedEvent] -> Map StreamId StreamName -> OpsResult
causationResult seed ancestors descendants names =
  OpsResult
    { headers = ["direction", "event_id", "stream", "type", "global_position", "causation_id"],
      rows = map (uncurry row) directed,
      jsonValue = Aeson.toJSON [eventJson (Just direction) event | (direction, event) <- directed]
    }
  where
    seedRows = take 1 (filter ((== seed) . (.eventId)) (ancestors <> descendants))
    directed =
      map ("seed",) seedRows
        <> map ("ancestor",) (filter ((/= seed) . (.eventId)) ancestors)
        <> map ("descendant",) (filter ((/= seed) . (.eventId)) descendants)
    row direction event =
      [ direction,
        eventIdText event.eventId,
        maybe ("#" <> showText (streamIdInt event.originalStreamId)) streamNameText (Map.lookup event.originalStreamId names),
        eventTypeText event.eventType,
        positionText event.globalPosition,
        maybe "" UUID.toText event.causationId
      ]

streamNameText :: StreamName -> Text
streamNameText (StreamName value) = value

eventIdText :: EventId -> Text
eventIdText (EventId value) = UUID.toText value

eventTypeText :: EventType -> Text
eventTypeText (EventType value) = value

streamIdInt :: StreamId -> Int64
streamIdInt (StreamId value) = value

versionInt :: StreamVersion -> Int64
versionInt (StreamVersion value) = value

positionInt :: GlobalPosition -> Int64
positionInt (GlobalPosition value) = value

versionText :: StreamVersion -> Text
versionText = showText . versionInt

positionText :: GlobalPosition -> Text
positionText = showText . positionInt

showText :: (Show a) => a -> Text
showText = Text.pack . show

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
