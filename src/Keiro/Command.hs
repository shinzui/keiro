module Keiro.Command
  ( CommandResult (..)
  , CommandError (..)
  , RunCommandOptions (..)
  , defaultRunCommandOptions
  , runCommand
  , runCommandWithSql
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
  }
  deriving stock (Generic, Eq, Show)

defaultRunCommandOptions :: RunCommandOptions
defaultRunCommandOptions = RunCommandOptions
  { retryLimit = 3
  , pageSize = 256
  }

data Hydrated rs s = Hydrated
  { state :: !s
  , registers :: !(RegFile rs)
  , streamVersion :: !StreamVersion
  , globalPosition :: !(Maybe GlobalPosition)
  }
  deriving stock (Generic)

hydrate ::
  forall phi rs s ci co es.
  (HasCallStack, Store :> es, BoolAlg phi (RegFile rs, ci)) =>
  RunCommandOptions ->
  EventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  Eff es (Either CommandError (Hydrated rs s))
hydrate options eventStream targetStream =
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
        Right event ->
          case Keiki.applyEvent (eventStream ^. #transducer) (state current) (registers current) event of
            Nothing -> pure (Left (HydrationReplayFailed (recorded ^. #streamVersion)))
            Just (nextState, nextRegisters) ->
              pure $ Right Hydrated
                { state = nextState
                , registers = nextRegisters
                , streamVersion = recorded ^. #streamVersion
                , globalPosition = Just (recorded ^. #globalPosition)
                }

runCommand ::
  forall phi rs s ci co es.
  (HasCallStack, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci)) =>
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
      case hydrated of
        Left err -> pure (Left err)
        Right current ->
          case evaluateCommand eventStream current command of
            Left err -> pure (Left err)
            Right [] -> pure (Right (noOpResult targetStream current))
            Right events ->
              case encodeEvents (eventStream ^. #eventCodec) events of
                Left err -> pure (Left err)
                Right encoded -> do
                  appended <- tryError @StoreError $
                    appendToStream
                      ((eventStream ^. #streamName) targetStream)
                      (expectedVersion (current ^. #streamVersion))
                      encoded
                  handleAppendOutcome remaining (Prelude.length encoded) appended

    handleAppendOutcome _ eventCount (Right appendResult) =
      pure (Right (appendedResult targetStream appendResult eventCount))
    handleAppendOutcome remaining _ (Left (_, storeError))
      | isRetryableConflict storeError
      , remaining > 0 =
          attempt (remaining Prelude.- 1)
      | isRetryableConflict storeError =
          pure (Left (RetryExhausted (options ^. #retryLimit) storeError))
      | otherwise =
          pure (Left (StoreFailed storeError))

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
  attempt (options ^. #retryLimit)
  where
    attempt remaining = do
      hydrated <- hydrate options eventStream targetStream
      case hydrated of
        Left err -> pure (Left err)
        Right current ->
          case evaluateCommand eventStream current command of
            Left err -> pure (Left err)
            Right [] -> pure (Right (noOpResult targetStream current, Nothing))
            Right events ->
              case encodeEvents (eventStream ^. #eventCodec) events of
                Left err -> pure (Left err)
                Right encoded -> do
                  outcome <- tryError @StoreError $
                    runTransactionAppending
                      ((eventStream ^. #streamName) targetStream)
                      (expectedVersion (current ^. #streamVersion))
                      encoded
                      ( \appendResult -> do
                          userValue <- afterAppend appendResult
                          pure (appendResult, userValue)
                      )
                  handleTransactionOutcome remaining (Prelude.length encoded) outcome

    handleTransactionOutcome _ eventCount (Right (Right (appendResult, userValue))) =
      pure (Right (appendedResult targetStream appendResult eventCount, Just userValue))
    handleTransactionOutcome remaining _ (Right (Left storeError)) =
      retryOrFail remaining storeError
    handleTransactionOutcome remaining _ (Left (_, storeError)) =
      retryOrFail remaining storeError

    retryOrFail remaining storeError
      | isRetryableConflict storeError
      , remaining > 0 =
          attempt (remaining Prelude.- 1)
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
