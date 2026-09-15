-- | Safe adapters for handlers used with delegated-idempotence inbox intake.
--
-- The wrappers in "Keiro.Inbox" deliberately accept any effectful handler, so
-- they cannot prove that its complete operation is idempotent. This module
-- supplies narrower adapters for one aggregate command or one already-resolved
-- process-manager command result. Both require a durable event receipt and
-- refuse to acknowledge failures or successful commands that appended no event.
module Keiro.Inbox.Delegated
  ( delegatedEventId,
    DelegatedCommandError (..),
    delegatedCommand,
    delegatedFromPMCommand,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, (:>))
import Keiro.Command (CommandError, CommandResult, RunCommandOptions)
import Keiro.DeterministicId (identitySeedBytes)
import Keiro.Inbox.Types (DelegatedOutcome (..))
import Keiro.Prelude
import Keiro.ProcessManager (PMCommandResult (..), dispatchDeduplicatedCommand)
import Kiroku.Store.Effect (Store)
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
