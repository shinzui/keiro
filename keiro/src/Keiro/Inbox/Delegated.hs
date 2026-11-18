-- | Safe adapters for handlers used with delegated-idempotence inbox intake.
--
-- The wrappers in "Keiro.Inbox" deliberately accept any effectful handler, so
-- they cannot prove that its complete operation is idempotent. This module
-- supplies narrower adapters for one aggregate command or one already-resolved
-- process-manager command result.
--
-- 'delegatedCommand' and 'delegatedFromPMCommand' require a durable event
-- receipt and refuse to acknowledge failures or successful commands that
-- appended no event.
--
-- 'delegatedDomainCommand' runs one typed domain command (see
-- 'Keiro.Command.runDomainCommand'). An accepted decision is acknowledged by
-- its marker event exactly as in 'delegatedCommand'. A typed no-op
-- ('DomainNoOp') is acknowledged only after the adapter commits a completed
-- @keiro_inbox@ row under the reserved key 'delegatedNoOpReceiptKey', and only
-- when the caller guarantees the no-op is replay-stable. Typed rejections,
-- command failures, and untyped zero-event successes are never acknowledged.
module Keiro.Inbox.Delegated
  ( delegatedEventId,
    DelegatedCommandError (..),
    delegatedCommand,
    delegatedFromPMCommand,

    -- * Typed domain commands with a no-op receipt
    delegatedNoOpReceiptKey,
    DelegatedNoOpReceipt (..),
    DelegatedDomainResult (..),
    DelegatedDomainCommandError (..),
    delegatedDomainCommand,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Keiro.Command
  ( CommandError,
    CommandResult,
    DomainCommandOutcome (..),
    DomainDecision (..),
    RunCommandOptions,
  )
import Keiro.DeterministicId (identitySeedBytes)
import Keiro.Inbox.Schema (CompletedInsert (..), insertCompletedStrictTx, lookupInbox)
import Keiro.Inbox.Types
  ( DelegatedOutcome (..),
    InboxPersistence,
    InboxRow,
    InboxStatus (..),
    KafkaDeliveryRef,
  )
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Prelude
import Keiro.ProcessManager (PMCommandResult (..), dispatchDeduplicatedCommand, eventAlreadyIn)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), StreamName (..))

-- | Derive the permanent first-event receipt for one delegated command.
--
-- The identity contains a version tag followed by consumer, integration source,
-- inbox dedupe key, resolved target stream, and stable operation name. Every
-- field is prefixed with its UTF-8 byte length, making boundaries unambiguous
-- even for empty, Unicode, or delimiter-containing values. These inputs and the
-- version-1 recipe are replay identity and must remain stable for the full
-- redelivery horizon.
delegatedEventId :: Text -> Text -> Text -> StreamName -> Text -> EventId
delegatedEventId consumer source dedupe (StreamName target) operation =
  EventId
    ( UUID.V5.generateNamed
        UUID.V5.namespaceURL
        ( identitySeedBytes
            ( Text.concat
                ( encodeField
                    <$> [ "keiro/inbox-delegated/1",
                          consumer,
                          source,
                          dedupe,
                          target,
                          operation
                        ]
                )
            )
        )
    )
  where
    encodeField field =
      Text.pack (show (ByteString.length (Text.Encoding.encodeUtf8 field)))
        <> ":"
        <> field

-- | Why a command cannot serve as a delegated-idempotence receipt.
data DelegatedCommandError
  = -- | The command failed; the target name is retained for retry and diagnostics.
    DelegatedCommandFailed !StreamName !CommandError
  | -- | The command succeeded without appending an event, so it left no durable
    -- receipt for this intake identity.
    DelegatedCommandWithoutReceipt !StreamName
  deriving stock (Generic, Eq, Show)

-- | Protect one atomic command append with a deterministic first-event receipt.
--
-- The adapter probes @markerId@ in @targetStream@ before invoking the callback,
-- preventing hydration or dispatch on a confirmed replay. It replaces the
-- options' event-id list with the singleton marker, then passes those prepared
-- options to the callback. The callback must use the supplied options and target,
-- perform exactly one atomic append, and include all protected SQL, projection,
-- and outbox work in that append transaction.
--
-- A positive append is fresh; a preflight hit or a concurrently confirmed append
-- is duplicate. A zero-event success and every unconfirmed command error remain
-- typed failures. In particular, callers must inspect 'Left' and apply their
-- retry or dead-letter policy; wrapping this whole result in 'DelegatedFresh'
-- would acknowledge a failed operation.
delegatedCommand ::
  forall target es.
  (Store :> es) =>
  RunCommandOptions ->
  StreamName ->
  EventId ->
  (RunCommandOptions -> Eff es (Either CommandError (CommandResult target))) ->
  Eff es (Either DelegatedCommandError (DelegatedOutcome (CommandResult target)))
delegatedCommand baseOptions targetStream markerId dispatch =
  dispatchDeduplicatedCommand
    preparedOptions
    targetStream
    (markerId :| [])
    (const (Right DelegatedDuplicate))
    (Left . DelegatedCommandFailed targetStream)
    classifySuccess
    (dispatch preparedOptions)
  where
    preparedOptions = baseOptions & #eventIds .~ [markerId]
    classifySuccess result
      | result ^. #eventsAppended > 0 = Right (DelegatedFresh result)
      | otherwise = Left (DelegatedCommandWithoutReceipt targetStream)

-- | Adapt one process-manager command result after its deterministic dispatch.
--
-- This is valid only for a single dispatch whose command identity already
-- absorbs the intake identity. It does not prove that an arbitrary multi-command
-- process-manager reaction completed.
delegatedFromPMCommand ::
  StreamName ->
  PMCommandResult target ->
  Either DelegatedCommandError (DelegatedOutcome (CommandResult target))
delegatedFromPMCommand resolvedTarget = \case
  PMCommandDuplicate _ -> Right DelegatedDuplicate
  PMCommandAppended result
    | result ^. #eventsAppended > 0 -> Right (DelegatedFresh result)
    | otherwise -> Left (DelegatedCommandWithoutReceipt resolvedTarget)
  PMCommandFailed failedTarget err -> Left (DelegatedCommandFailed failedTarget err)

-- | The reserved inbox row key for one delegated command's no-op receipt:
-- @"keiro/inbox-delegated-noop/1:" <> UUID.toText marker@, where @marker@ is
-- the command's 'delegatedEventId'.
--
-- The row is stored under the envelope @source@ and this key. The prefix and
-- the marker inputs are persisted replay identity: changing either makes an
-- earlier no-op receipt unreachable. Adopters reserve the prefix among every
-- writer of @keiro_inbox@ for a participating source.
delegatedNoOpReceiptKey :: EventId -> Text
delegatedNoOpReceiptKey (EventId marker) =
  "keiro/inbox-delegated-noop/1:" <> UUID.toText marker

-- | What 'delegatedDomainCommand' needs to derive the marker and, for a typed
-- no-op, to write the inbox row that acknowledges it.
--
-- @consumer@ and @operation@ are the stable names passed to
-- 'delegatedEventId'; @dedupeKey@ is the key the delegated wrapper passes to
-- the handler; @event@ is the delivered envelope, whose @source@ becomes the
-- row's source. @kafka@ and @persistence@ only shape the stored row.
data DelegatedNoOpReceipt = DelegatedNoOpReceipt
  { consumer :: !Text,
    operation :: !Text,
    dedupeKey :: !Text,
    event :: !IntegrationEvent,
    kafka :: !(Maybe KafkaDeliveryRef),
    persistence :: !InboxPersistence
  }
  deriving stock (Generic)

-- | The first-time result of a delegated domain command.
data DelegatedDomainResult target co noOp
  = -- | Events were appended and the first carries the marker. No inbox row
    -- was written.
    DelegatedDomainAccepted !(NonEmpty co) !(CommandResult target)
  | -- | A typed no-op whose completed inbox row this call committed.
    DelegatedDomainNoOp !noOp !(CommandResult target)
  deriving stock (Generic, Eq, Show)

-- | Why a delegated domain command was not acknowledged.
--
-- None of these is a basis for acknowledging the delivery. The rejection
-- payload stays in this typed value; callers must keep it out of generic
-- errors, telemetry, and logs.
data DelegatedDomainCommandError rejection
  = -- | An unconfirmed command failure, or an accepted decision that appended
    -- no event ('DelegatedCommandWithoutReceipt').
    DelegatedDomainCommandError !DelegatedCommandError
  | -- | A typed rejection. It is never acknowledged; the caller owns its retry
    -- or dead-letter policy.
    DelegatedDomainRejected !StreamName !rejection
  | -- | An inbox row for this receipt key exists in a non-completed status.
    DelegatedNoOpReceiptUnavailable !StreamName !InboxStatus
  | -- | The receipt insert conflicted with a row that disappeared before it
    -- could be read (typically concurrent retention). Nothing proves the
    -- delivery was handled; retry it.
    DelegatedNoOpReceiptLost !StreamName
  deriving stock (Generic, Eq, Show)

-- | Run one typed domain command as a delegated-intake receipt, acknowledging
-- an accepted decision by its marker event and a replay-stable typed no-op by
-- a completed inbox row.
--
-- __Caller contract.__ The callback must run exactly one domain command (for
-- example 'Keiro.Command.runDomainCommand') on @targetStream@ with the
-- supplied options, return its actual outcome, and perform every protected
-- side effect inside that command's event append. A silent decision performs
-- no side effects. Use this adapter only when every no-op the command can
-- return for this delivery is /replay-stable/: once the delivery is a no-op,
-- replaying it remains a no-op in every later reachable state, including
-- retries after a crash and replays after receipt retention. The adapter
-- cannot infer that property from the no-op value.
--
-- __Guarantee.__ An accepted command commits its deterministic marker
-- ('delegatedEventId' of consumer, envelope source, dedupe key, target and
-- operation) as its first event. A qualifying no-op is fresh only after the
-- adapter commits its completed inbox row at ('IntegrationEvent' source,
-- 'delegatedNoOpReceiptKey' marker). A matching marker in the target stream or
-- a matching completed row proves a duplicate; the callback is not invoked. A
-- competing marker takes precedence when dispatch observes the no-op or
-- rejection left by that append: both decisions recheck the marker and return
-- 'DelegatedDuplicate' on a hit.
--
-- A crash after the silent decision and before the receipt commit leaves the
-- delivery unacknowledged, and a retry evaluates the command again. Set
-- retention ('Keiro.Inbox.Schema.garbageCollectCompleted') beyond the required
-- redelivery horizon; once a row is removed, a later replay may report fresh
-- again and must still append nothing. A typed rejection, an unconfirmed
-- command failure, a missing receipt after an insert conflict, an existing
-- non-completed row, and an untyped zero-event success return 'Left' and must
-- not be acknowledged. Store and commit failures propagate through the
-- store's ordinary error channel.
--
-- The executing role needs @SELECT@ on @keiro.keiro_inbox@ for every marker
-- miss and @INSERT@ for every no-op.
delegatedDomainCommand ::
  forall target co rejection noOp es.
  (IOE :> es, Store :> es) =>
  DelegatedNoOpReceipt ->
  RunCommandOptions ->
  StreamName ->
  (RunCommandOptions -> Eff es (Either CommandError (DomainCommandOutcome target co rejection noOp))) ->
  Eff es (Either (DelegatedDomainCommandError rejection) (DelegatedOutcome (DelegatedDomainResult target co noOp)))
delegatedDomainCommand receipt baseOptions targetStream dispatch =
  dispatchDeduplicatedCommand
    preparedOptions
    targetStream
    (marker :| [])
    (const (Right DelegatedDuplicate))
    (Left . DelegatedDomainCommandError . DelegatedCommandFailed targetStream)
    id
    attempt
  where
    source = receipt ^. #event . #source
    marker =
      delegatedEventId
        (receipt ^. #consumer)
        source
        (receipt ^. #dedupeKey)
        targetStream
        (receipt ^. #operation)
    rowKey = delegatedNoOpReceiptKey marker
    preparedOptions = baseOptions & #eventIds .~ [marker]

    -- Runs only after a preflight marker miss. Returning 'Left' hands a
    -- command error back to the dispatch helper for duplicate confirmation.
    attempt = do
      existing <- lookupInbox source rowKey
      case existing of
        Just row -> pure (Right (existingRow row))
        Nothing -> do
          outcome <- dispatch preparedOptions
          case outcome of
            Left err -> pure (Left err)
            Right domain -> Right <$> classify domain

    classify DomainCommandOutcome {decision, result} = case decision of
      DomainAccepted events
        | result ^. #eventsAppended > 0 ->
            pure (Right (DelegatedFresh (DelegatedDomainAccepted events result)))
        | otherwise ->
            pure (Left (DelegatedDomainCommandError (DelegatedCommandWithoutReceipt targetStream)))
      DomainRejected rejection -> do
        competing <- eventAlreadyIn preparedOptions targetStream marker
        pure
          ( if competing
              then Right DelegatedDuplicate
              else Left (DelegatedDomainRejected targetStream rejection)
          )
      DomainNoOp noOp -> do
        competing <- eventAlreadyIn preparedOptions targetStream marker
        if competing
          then pure (Right DelegatedDuplicate)
          else do
            now <- liftIO getCurrentTime
            inserted <-
              runTransaction $
                insertCompletedStrictTx
                  (receipt ^. #persistence)
                  source
                  rowKey
                  (receipt ^. #event)
                  (receipt ^. #kafka)
                  now
            pure $ case inserted of
              CompletedInserted -> Right (DelegatedFresh (DelegatedDomainNoOp noOp result))
              CompletedExisting row -> existingRow row
              CompletedConflictVanished -> Left (DelegatedNoOpReceiptLost targetStream)

    existingRow :: InboxRow -> Either (DelegatedDomainCommandError rejection) (DelegatedOutcome (DelegatedDomainResult target co noOp))
    existingRow row = case row ^. #status of
      InboxCompleted -> Right DelegatedDuplicate
      status -> Left (DelegatedNoOpReceiptUnavailable targetStream status)
