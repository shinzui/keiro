{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- | Dead-letter queue inspection and redrive helpers.
--
-- The PGMQ adapter writes DLQ rows as a shibuya wrapper whose required keys are
-- @original_message@ and @dead_letter_reason@. Keiro's worker path always includes
-- metadata as well: @original_message_id@, @original_enqueued_at@, @last_read_at@,
-- @read_count@, and @original_headers@. These helpers parse the required keys and
-- treat metadata as optional so operators can still inspect legacy or hand-written
-- rows.
--
-- 'readDlq', 'redriveDlq', and count-based 'archiveDlq' read visible rows and hide
-- each row they inspect for 30 seconds. To retain inspected rows without waiting,
-- keep their 'dlqMessageId' values and pass them to 'archiveDlqEntries'. Verify
-- that every requested id was returned before considering retention complete:
--
-- @
-- entries <- readDlq job 100
-- let requested = fmap dlqMessageId entries
-- archived <- archiveDlqEntries job requested
-- if Set.fromList archived /= Set.fromList requested
--   then stopAndInvestigate
--   else purgeDlq job
-- @
--
-- PGMQ does not expire ordinary DLQ rows by itself. Archiving moves active rows
-- into @pgmq.a_<dlq>@ for audit. Partitioned archive retention remains subject to
-- its configured partition maintenance; archiving does not promise indefinite
-- retention. 'purgeDlq' deletes only after a metrics snapshot reports no hidden
-- rows, returning 'PurgeDlqBlocked' otherwise. The snapshot and deletion are not
-- atomic. For a full-queue audit, pause producers and other operators, inspect and
-- archive every row that requires retention, verify the active depth is zero, and
-- only then consider purge. A bounded read followed by purge can still delete
-- uninspected visible rows. 'purgeDlqForce' is the explicitly unconditional escape
-- hatch and permanently deletes hidden rows too. Alert on DLQ depth via
-- 'Keiro.PGMQ.Metrics.jobDlqMetrics'.
--
-- Redrive preserves the wrapper's original producer headers, including FIFO group
-- and trace metadata, but it sends a new main-queue row with a new id, a fresh read
-- count, and a new position at the back of its group. Redrive is at-least-once: a
-- crash after sending the original payload but before deleting the DLQ row leaves
-- the payload in both places. Handlers must therefore be idempotent.
module Keiro.PGMQ.Dlq
  ( DlqEntry (..),
    readDlq,
    redriveDlq,
    PurgeDlqResult (..),
    purgeDlq,
    purgeDlqForce,
    archiveDlq,
    archiveDlqEntries,
    archiveDlqEntry,
    archiveDlqEntryById,
  )
where

import Keiro.PGMQ.Codec (JobDecodeError (..), decodeJob)
import Keiro.PGMQ.Job (Job (..))
import Keiro.PGMQ.Runtime (QueueRef (..))
import "aeson" Data.Aeson (Value (..), withObject, (.:), (.:?))
import "aeson" Data.Aeson.Types (Parser, parseEither)
import "base" Control.Monad (foldM, void)
import "base" Data.Foldable (toList)
import "base" Data.Int (Int32, Int64)
import "effectful-core" Effectful (Eff, IOE, (:>))
import "pgmq-effectful" Pgmq.Effectful
  ( BatchMessageQuery (..),
    Message (..),
    MessageBody (..),
    MessageHeaders (..),
    MessageId (..),
    MessageQuery (..),
    Pgmq,
    QueueMetrics (..),
    ReadMessage (..),
    SendMessage (..),
    SendMessageWithHeaders (..),
  )
import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq
import "text" Data.Text (Text)
import "text" Data.Text qualified as Text
import "time" Data.Time (UTCTime)

-- | A decoded dead-letter entry: shibuya's DLQ wrapper, unwrapped.
data DlqEntry p = DlqEntry
  { -- | The DLQ row's own PGMQ message id.
    dlqMessageId :: !MessageId,
    -- | @poison_pill: ...@, @invalid_payload: ...@, or @max_retries_exceeded@.
    reason :: !Text,
    -- | The preserved @original_message@ decoded with the job's codec.
    originalPayload :: !(Either JobDecodeError p),
    originalMessageId :: !(Maybe Int64),
    originalEnqueuedAt :: !(Maybe UTCTime),
    readCount :: !(Maybe Int64),
    -- | The producer headers preserved in the DLQ wrapper, when present.
    originalHeaders :: !(Maybe Value),
    -- | Full DLQ wrapper for forensics.
    rawBody :: !Value
  }
  deriving stock (Show)

data DlqEnvelope = DlqEnvelope
  { originalMessage :: !Value,
    deadLetterReason :: !Text,
    envelopeOriginalMessageId :: !(Maybe Int64),
    envelopeOriginalEnqueuedAt :: !(Maybe UTCTime),
    envelopeReadCount :: !(Maybe Int64),
    envelopeOriginalHeaders :: !(Maybe Value)
  }

parseDlqEnvelope :: Value -> Either Text DlqEnvelope
parseDlqEnvelope =
  firstText . parseEither parser
  where
    parser :: Value -> Parser DlqEnvelope
    parser =
      withObject "DLQ payload" \obj -> do
        originalMessage <- obj .: "original_message"
        deadLetterReason <- obj .: "dead_letter_reason"
        envelopeOriginalMessageId <- obj .:? "original_message_id"
        envelopeOriginalEnqueuedAt <- obj .:? "original_enqueued_at"
        envelopeReadCount <- obj .:? "read_count"
        envelopeOriginalHeaders <- obj .:? "original_headers"
        pure
          DlqEnvelope
            { originalMessage,
              deadLetterReason,
              envelopeOriginalMessageId,
              envelopeOriginalEnqueuedAt,
              envelopeReadCount,
              envelopeOriginalHeaders
            }

    firstText = \case
      Left err -> Left (Text.pack err)
      Right value -> Right value

-- | Read and decode up to @n@ DLQ entries. The read uses a 30 second visibility
-- timeout so concurrent inspections do not immediately see the same rows.
readDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> Eff es [DlqEntry p]
readDlq job n
  | n <= 0 = pure []
  | otherwise = do
      messages <-
        Pgmq.readMessage
          ReadMessage
            { queueName = job.jobQueue.dlqName,
              delay = 30,
              batchSize = Just n,
              conditional = Nothing
            }
      pure (fmap (toEntry job) (toList messages))

toEntry :: Job p -> Message -> DlqEntry p
toEntry job message =
  let body = unMessageBody message.body
   in case parseDlqEnvelope body of
        Left err ->
          DlqEntry
            { dlqMessageId = message.messageId,
              reason = "malformed_dlq_payload: " <> err,
              originalPayload = Left (JobPayloadMalformed err),
              originalMessageId = Nothing,
              originalEnqueuedAt = Nothing,
              readCount = Nothing,
              originalHeaders = Nothing,
              rawBody = body
            }
        Right envelope ->
          DlqEntry
            { dlqMessageId = message.messageId,
              reason = envelope.deadLetterReason,
              originalPayload = decodeJob job.jobCodec envelope.originalMessage,
              originalMessageId = envelope.envelopeOriginalMessageId,
              originalEnqueuedAt = envelope.envelopeOriginalEnqueuedAt,
              readCount = envelope.envelopeReadCount,
              originalHeaders = envelope.envelopeOriginalHeaders,
              rawBody = body
            }

-- | Move up to @n@ visible DLQ rows back to the main queue. Each read hides the
-- DLQ row for 30 seconds. Redriven messages preserve wrapper producer headers but
-- receive a new id, queue position, and fresh PGMQ @read_ct@. Malformed wrappers
-- are left in the DLQ for inspection.
redriveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int
redriveDlq job n
  | n <= 0 = pure 0
  | otherwise = loop 0
  where
    loop moved
      | moved >= n = pure moved
      | otherwise = do
          messages <-
            Pgmq.readMessage
              ReadMessage
                { queueName = job.jobQueue.dlqName,
                  delay = 30,
                  batchSize = Just (fromIntegral (min 100 (n - moved))),
                  conditional = Nothing
                }
          if null messages
            then pure moved
            else do
              movedInBatch <- foldM redriveOne 0 messages
              if movedInBatch == 0
                then pure moved
                else loop (moved + movedInBatch)

    redriveOne count message =
      case parseDlqEnvelope (unMessageBody message.body) of
        Left _err ->
          pure count
        Right envelope -> do
          _ <- case envelope.envelopeOriginalHeaders of
            Just headers ->
              Pgmq.sendMessageWithHeaders
                SendMessageWithHeaders
                  { queueName = job.jobQueue.physicalName,
                    messageBody = MessageBody envelope.originalMessage,
                    messageHeaders = MessageHeaders headers,
                    delay = Nothing
                  }
            Nothing ->
              Pgmq.sendMessage
                SendMessage
                  { queueName = job.jobQueue.physicalName,
                    messageBody = MessageBody envelope.originalMessage,
                    delay = Nothing
                  }
          void $
            Pgmq.deleteMessage
              MessageQuery
                { queueName = job.jobQueue.dlqName,
                  messageId = message.messageId
                }
          pure (count + 1)

-- | Result of a visibility-safe DLQ purge attempt.
data PurgeDlqResult
  = -- | The DLQ had no hidden rows at the metrics snapshot and was purged.
    PurgeDlqPurged !Int64
  | -- | Purge was refused because this many rows were hidden at the snapshot.
    PurgeDlqBlocked !Int64
  deriving stock (Eq, Show)

-- | Delete all rows currently in the DLQ only when none are hidden by a prior
-- read. The metrics check and deletion are separate operations, so callers that
-- need a full-queue audit must also quiesce concurrent readers and writers.
purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es PurgeDlqResult
purgeDlq job = do
  metrics <- Pgmq.queueMetrics job.jobQueue.dlqName
  let invisible = metrics.queueLength - metrics.queueVisibleLength
  if invisible > 0
    then pure (PurgeDlqBlocked invisible)
    else PurgeDlqPurged <$> Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName

-- | Unconditionally delete every active DLQ row, including hidden rows.
purgeDlqForce :: (Pgmq :> es, IOE :> es) => Job p -> Eff es Int64
purgeDlqForce job =
  Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName

-- | Archive (retain) up to @n@ visible DLQ rows, hiding each inspected row for
-- 30 seconds: move each out of the active DLQ table
-- @pgmq.q_<dlq>@ into the archive table @pgmq.a_<dlq>@, preserving @enqueued_at@ /
-- @read_ct@ and stamping @archived_at@. Returns the number archived. This is the
-- audit-retention counterpart to the delete-only 'purgeDlq'. At-most-once per row
-- per call; a crash before archiving leaves the row in the active DLQ for a re-run.
archiveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int
archiveDlq job n
  | n <= 0 = pure 0
  | otherwise = loop 0
  where
    loop archived
      | archived >= n = pure archived
      | otherwise = do
          messages <-
            Pgmq.readMessage
              ReadMessage
                { queueName = job.jobQueue.dlqName,
                  delay = 30,
                  batchSize = Just (fromIntegral (min 100 (n - archived))),
                  conditional = Nothing
                }
          if null messages
            then pure archived
            else do
              archivedInBatch <- foldM archiveOne 0 messages
              if archivedInBatch == 0
                then pure archived
                else loop (archived + archivedInBatch)

    archiveOne count message = do
      moved <- archiveDlqEntry job message.messageId
      pure (if moved then count + 1 else count)

-- | Archive the specified DLQ rows, including rows hidden by a prior read.
-- Returns only ids that were present and moved; returned order is unspecified.
archiveDlqEntries :: (Pgmq :> es, IOE :> es) => Job p -> [MessageId] -> Eff es [MessageId]
archiveDlqEntries _job [] = pure []
archiveDlqEntries job messageIds =
  Pgmq.batchArchiveMessages
    BatchMessageQuery
      { queueName = job.jobQueue.dlqName,
        messageIds
      }

-- | Archive one specific DLQ row by message id. 'True' if a row was moved.
archiveDlqEntry :: (Pgmq :> es, IOE :> es) => Job p -> MessageId -> Eff es Bool
archiveDlqEntry job msgId =
  Pgmq.archiveMessage
    MessageQuery
      { queueName = job.jobQueue.dlqName,
        messageId = msgId
      }

-- | Numeric-id convenience wrapper for operator surfaces that should not need
-- a direct dependency on the lower-level @pgmq-effectful@ package.
archiveDlqEntryById :: (Pgmq :> es, IOE :> es) => Job p -> Int64 -> Eff es Bool
archiveDlqEntryById job = archiveDlqEntry job . MessageId
