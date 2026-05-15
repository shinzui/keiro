module Keiro.Command
  ( CommandResult (..)
  , CommandError (..)
  , RunCommandOptions (..)
  , defaultRunCommandOptions
  , runCommand
  , runCommandWithSql
  , runCommandWithSqlEvents
  )
where

import Data.Int (Int32)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import GHC.Stack (HasCallStack)
import Hasql.Transaction qualified as Tx
import Keiki.Core (BoolAlg, RegFile)
import Keiki.Core qualified as Keiki
import Keiro.Codec (Codec, CodecError, decodeRecorded, encodeForAppend)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.Snapshot (hydrateWithSnapshot, writeSnapshot)
import Keiro.Snapshot.Policy (shouldSnapshot)
import Keiro.Stream (Stream)
import Prelude qualified
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Transaction (runTransactionAppending)
import Kiroku.Store.Types
  ( AppendResult
  , EventData
  , EventId
  , ExpectedVersion (..)
  , GlobalPosition
  , RecordedEvent
  , StreamVersion (..)
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly

data CommandResult target = CommandResult
  { target :: !(Stream target)
  , streamVersion :: !StreamVersion
  , globalPosition :: !(Maybe GlobalPosition)
  , eventsAppended :: !Int
  }
  deriving stock (Generic, Eq, Show)

data CommandError
  = HydrationDecodeFailed !CodecError
  | HydrationReplayFailed !StreamVersion
  | CommandRejected
  | EncodeFailed !CodecError
  | StoreFailed !StoreError
  | RetryExhausted !Int !StoreError
  deriving stock (Generic, Eq, Show)

data RunCommandOptions = RunCommandOptions
  { retryLimit :: !Int
  , pageSize :: !Int32
  , eventIds :: ![EventId]
  , beforeAppend :: !(IO ())
  }
  deriving stock (Generic)

defaultRunCommandOptions :: RunCommandOptions
defaultRunCommandOptions = RunCommandOptions
  { retryLimit = 3
  , pageSize = 256
  , eventIds = []
  , beforeAppend = pure ()
  }

data Hydrated rs s = Hydrated
  { state :: !s
  , registers :: !(RegFile rs)
  , streamVersion :: !StreamVersion
  , globalPosition :: !(Maybe GlobalPosition)
  }
  deriving stock (Generic)

data CommandPlan target rs s co
  = CommandNoOp !(CommandResult target)
  | CommandAppend !(Hydrated rs s) ![co] ![EventData]
  deriving stock (Generic)

hydrate ::
  forall phi rs s ci co es.
  (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci)) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  Eff es (Either CommandError (Hydrated rs s))
hydrate options eventStream targetStream =
  snapshotSeed >>= \case
    Nothing -> hydrateFull options eventStream targetStream
    Just seed -> do
      replayed <- replayFrom seed
      case replayed of
        Left _ -> hydrateFull options eventStream targetStream
        Right hydrated -> pure (Right hydrated)
  where
    snapshotSeed =
      case eventStream ^. #stateCodec of
        Nothing -> pure Nothing
        Just codec ->
          hydrateWithSnapshot ((eventStream ^. #streamName) targetStream) codec

    replayFrom seed =
      replay
        Hydrated
          { state = seed ^. #state
          , registers = seed ^. #registers
          , streamVersion = seed ^. #streamVersion
          , globalPosition = Nothing
          }
        (seed ^. #streamVersion)

    replay start cursor =
      Streamly.fold
        (Fold.foldlM' applyRecorded (pure (Right start)))
        (readStreamForwardStream ((eventStream ^. #streamName) targetStream) cursor (options ^. #pageSize))

    applyRecorded ::
      Either CommandError (Hydrated rs s) ->
      RecordedEvent ->
      Eff es (Either CommandError (Hydrated rs s))
    applyRecorded (Left err) _ = pure (Left err)
    applyRecorded (Right current) recorded =
      case decodeRecorded (eventStream ^. #eventCodec) recorded of
        Left err -> pure (Left (HydrationDecodeFailed err))
        Right event -> pure (applyEvent current recorded event)

    applyEvent current recorded event =
      case Keiki.applyEvent (eventStream ^. #transducer) (state current) (registers current) event of
        Nothing -> Left (HydrationReplayFailed (recorded ^. #streamVersion))
        Just (nextState, nextRegisters) ->
          Right Hydrated
            { state = nextState
            , registers = nextRegisters
            , streamVersion = recorded ^. #streamVersion
            , globalPosition = Just (recorded ^. #globalPosition)
            }

hydrateFull ::
  forall phi rs s ci co es.
  (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci)) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  Eff es (Either CommandError (Hydrated rs s))
hydrateFull options eventStream targetStream =
  Streamly.fold
    (Fold.foldlM' applyRecorded (pure (Right initialHydrated)))
    (readStreamForwardStream ((eventStream ^. #streamName) targetStream) (StreamVersion 0) (options ^. #pageSize))
  where
    initialHydrated = Hydrated
      { state = eventStream ^. #initialState
      , registers = eventStream ^. #initialRegisters
      , streamVersion = StreamVersion 0
      , globalPosition = Nothing
      }

    applyRecorded ::
      Either CommandError (Hydrated rs s) ->
      RecordedEvent ->
      Eff es (Either CommandError (Hydrated rs s))
    applyRecorded (Left err) _ = pure (Left err)
    applyRecorded (Right current) recorded =
      case decodeRecorded (eventStream ^. #eventCodec) recorded of
        Left err -> pure (Left (HydrationDecodeFailed err))
        Right event -> pure (applyEvent current recorded event)

    applyEvent current recorded event =
      case Keiki.applyEvent (eventStream ^. #transducer) (state current) (registers current) event of
        Nothing -> Left (HydrationReplayFailed (recorded ^. #streamVersion))
        Just (nextState, nextRegisters) ->
          Right Hydrated
            { state = nextState
            , registers = nextRegisters
            , streamVersion = recorded ^. #streamVersion
            , globalPosition = Just (recorded ^. #globalPosition)
            }

runCommand ::
  forall phi rs s ci co es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci)) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
runCommand options eventStream targetStream command =
  attempt (options ^. #retryLimit)
  where
    attempt remaining = do
      hydrated <- hydrate options eventStream targetStream
      either (pure . Left) (runPlan remaining) hydrated

    runPlan remaining current =
      case prepareCommandPlan options eventStream targetStream current command of
        Left err -> pure (Left err)
        Right (CommandNoOp result) -> pure (Right result)
        Right (CommandAppend current' events encoded) ->
          appendOnce remaining current' events encoded

    appendOnce remaining current events encoded = do
      liftIO (options ^. #beforeAppend)
      appended <- tryError @StoreError $
        appendToStream
          ((eventStream ^. #streamName) targetStream)
          (expectedVersion (current ^. #streamVersion))
          encoded
      case appended of
        Right appendResult -> do
          writeSnapshotIfNeeded eventStream current events appendResult
          pure (Right (appendedResult targetStream appendResult (Prelude.length encoded)))
        Left (_, storeError) ->
          retryOrFail options attempt remaining storeError

runCommandWithSql ::
  forall phi rs s ci co a es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci)) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  (AppendResult -> Tx.Transaction a) ->
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))
runCommandWithSql options eventStream targetStream command afterAppend =
  runCommandWithSqlEvents options eventStream targetStream command (\_ appendResult -> afterAppend appendResult)

runCommandWithSqlEvents ::
  forall phi rs s ci co a es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci)) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ([co] -> AppendResult -> Tx.Transaction a) ->
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co), Maybe a))
runCommandWithSqlEvents options eventStream targetStream command afterAppend =
  attempt (options ^. #retryLimit)
  where
    attempt remaining = do
      hydrated <- hydrate options eventStream targetStream
      either (pure . Left) (runPlan remaining) hydrated

    runPlan remaining current =
      case prepareCommandPlan options eventStream targetStream current command of
        Left err -> pure (Left err)
        Right (CommandNoOp result) -> pure (Right (result, Nothing))
        Right (CommandAppend current' events encoded) ->
          appendWithSqlOnce remaining current' events encoded

    appendWithSqlOnce remaining current events encoded = do
      liftIO (options ^. #beforeAppend)
      outcome <- tryError @StoreError $
        runTransactionAppending
          ((eventStream ^. #streamName) targetStream)
          (expectedVersion (current ^. #streamVersion))
          encoded
          ( \appendResult -> do
              userValue <- afterAppend events appendResult
              pure (appendResult, userValue)
          )
      case outcome of
        Right (Right (appendResult, userValue)) -> do
          writeSnapshotIfNeeded eventStream current events appendResult
          pure (Right (appendedResult targetStream appendResult (Prelude.length encoded), Just userValue))
        Right (Left storeError) ->
          retryOrFail options attempt remaining storeError
        Left (_, storeError) ->
          retryOrFail options attempt remaining storeError

prepareCommandPlan ::
  BoolAlg phi (RegFile rs, ci) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  Hydrated rs s ->
  ci ->
  Either CommandError (CommandPlan (EventStream phi rs s ci co) rs s co)
prepareCommandPlan options eventStream targetStream current command =
  case evaluateCommand eventStream current command of
    Left err -> Left err
    Right events -> toPlan events
  where
    toPlan [] =
      Right (CommandNoOp (noOpResult targetStream current))
    toPlan events =
      CommandAppend current events
        . assignEventIds (options ^. #eventIds)
        <$> encodeEvents (eventStream ^. #eventCodec) events

writeSnapshotIfNeeded ::
  forall phi rs s ci co es.
  (BoolAlg phi (RegFile rs, ci), Store :> es) =>
  EventStream phi rs s ci co ->
  Hydrated rs s ->
  [co] ->
  AppendResult ->
  Eff es ()
writeSnapshotIfNeeded eventStream current events appendResult =
  case eventStream ^. #stateCodec of
    Nothing -> pure ()
    Just codec ->
      case Keiki.applyEvents (eventStream ^. #transducer) (state current, registers current) events of
        Nothing -> pure ()
        Just finalState -> do
          let finalVersion = appendResult ^. #streamVersion
              terminal = Keiki.isFinal (eventStream ^. #transducer) (Prelude.fst finalState)
          when (shouldSnapshot (eventStream ^. #snapshotPolicy) terminal finalState finalVersion) $
            writeSnapshot (appendResult ^. #streamId) finalVersion codec finalState

retryOrFail ::
  RunCommandOptions ->
  (Int -> Eff es (Either CommandError a)) ->
  Int ->
  StoreError ->
  Eff es (Either CommandError a)
retryOrFail options retry remaining storeError
  | isRetryableConflict storeError
  , remaining > 0 =
      retry (remaining Prelude.- 1)
  | isRetryableConflict storeError =
      pure (Left (RetryExhausted (options ^. #retryLimit) storeError))
  | otherwise =
      pure (Left (StoreFailed storeError))

evaluateCommand ::
  BoolAlg phi (RegFile rs, ci) =>
  EventStream phi rs s ci co ->
  Hydrated rs s ->
  ci ->
  Either CommandError [co]
evaluateCommand eventStream current command =
  case Keiki.step (eventStream ^. #transducer) (state current, registers current) command of
    Nothing -> Left CommandRejected
    Just (_, _, Nothing) -> Right []
    Just (_, _, Just event) -> Right [event]

encodeEvents :: Codec co -> [co] -> Either CommandError [EventData]
encodeEvents codec = Prelude.mapM (mapLeft EncodeFailed . encodeForAppend codec)

assignEventIds :: [EventId] -> [EventData] -> [EventData]
assignEventIds [] events = events
assignEventIds _ [] = []
assignEventIds (supplied : suppliedRest) (event : eventRest) =
  (event & #eventId .~ Just supplied) : assignEventIds suppliedRest eventRest

expectedVersion :: StreamVersion -> ExpectedVersion
expectedVersion (StreamVersion 0) = NoStream
expectedVersion version = ExactVersion version

noOpResult ::
  Stream target ->
  Hydrated rs s ->
  CommandResult target
noOpResult targetStream current = CommandResult
  { target = targetStream
  , streamVersion = current ^. #streamVersion
  , globalPosition = current ^. #globalPosition
  , eventsAppended = 0
  }

appendedResult ::
  Stream target ->
  AppendResult ->
  Int ->
  CommandResult target
appendedResult targetStream appendResult count = CommandResult
  { target = targetStream
  , streamVersion = appendResult ^. #streamVersion
  , globalPosition = Just (appendResult ^. #globalPosition)
  , eventsAppended = count
  }

isRetryableConflict :: StoreError -> Bool
isRetryableConflict = \case
  WrongExpectedVersion{} -> True
  StreamAlreadyExists{} -> True
  _ -> False

mapLeft :: (e -> e') -> Either e a -> Either e' a
mapLeft f = \case
  Left err -> Left (f err)
  Right value -> Right value
