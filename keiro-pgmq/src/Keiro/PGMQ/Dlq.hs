{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- | Dead-letter queue inspection and redrive helpers.

The PGMQ adapter writes DLQ rows as a shibuya wrapper whose required keys are
@original_message@ and @dead_letter_reason@. Keiro's worker path always includes
metadata as well: @original_message_id@, @original_enqueued_at@, @last_read_at@,
@read_count@, and @original_headers@. These helpers parse the required keys and
treat metadata as optional so operators can still inspect legacy or hand-written
rows.

PGMQ does not expire DLQ rows by itself. The retention model is "archive-then-
purge": 'archiveDlq' retains dead letters by moving them into the archive table
@pgmq.a_<dlq>@ (preserving @enqueued_at@ / @read_ct@ and stamping @archived_at@)
for audit, while 'purgeDlq' deletes them permanently. An operator who needs an
audit trail runs 'archiveDlq' (retain) and may then 'purgeDlq' (clear the active
table); an operator who does not keeps using 'purgeDlq' alone. Either way, alert
on the DLQ's depth via 'Keiro.PGMQ.Metrics.jobDlqMetrics'.

Redrive is at-least-once: a crash after sending the original payload back to the
main queue but before deleting the DLQ row leaves the payload in both places.
Handlers must therefore be idempotent.
-}
module Keiro.PGMQ.Dlq (
    DlqEntry (..),
    readDlq,
    redriveDlq,
    purgeDlq,
    archiveDlq,
    archiveDlqEntry,
) where

import Keiro.PGMQ.Codec (JobDecodeError (..), decodeJob)
import Keiro.PGMQ.Job (Job (..))
import Keiro.PGMQ.Runtime (QueueRef (..))
import "aeson" Data.Aeson (Value (..), withObject, (.:), (.:?))
import "aeson" Data.Aeson.Types (Parser, parseEither)
import "base" Control.Monad (foldM, void)
import "base" Data.Foldable (toList)
import "base" Data.Int (Int32, Int64)
import "effectful-core" Effectful (Eff, IOE, (:>))
import "pgmq-effectful" Pgmq.Effectful (
    Message (..),
    MessageBody (..),
    MessageId,
    MessageQuery (..),
    Pgmq,
    ReadMessage (..),
    SendMessage (..),
 )
import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq
import "text" Data.Text (Text)
import "text" Data.Text qualified as Text
import "time" Data.Time (UTCTime)

-- | A decoded dead-letter entry: shibuya's DLQ wrapper, unwrapped.
data DlqEntry p = DlqEntry
    { dlqMessageId :: !MessageId
    -- ^ The DLQ row's own PGMQ message id.
    , reason :: !Text
    -- ^ @poison_pill: ...@, @invalid_payload: ...@, or @max_retries_exceeded@.
    , originalPayload :: !(Either JobDecodeError p)
    -- ^ The preserved @original_message@ decoded with the job's codec.
    , originalMessageId :: !(Maybe Int64)
    , originalEnqueuedAt :: !(Maybe UTCTime)
    , readCount :: !(Maybe Int64)
    , rawBody :: !Value
    -- ^ Full DLQ wrapper for forensics.
    }
    deriving stock (Show)

data DlqEnvelope = DlqEnvelope
    { originalMessage :: !Value
    , deadLetterReason :: !Text
    , envelopeOriginalMessageId :: !(Maybe Int64)
    , envelopeOriginalEnqueuedAt :: !(Maybe UTCTime)
    , envelopeReadCount :: !(Maybe Int64)
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
            pure
                DlqEnvelope
                    { originalMessage
                    , deadLetterReason
                    , envelopeOriginalMessageId
                    , envelopeOriginalEnqueuedAt
                    , envelopeReadCount
                    }

    firstText = \case
        Left err -> Left (Text.pack err)
        Right value -> Right value

{- | Read and decode up to @n@ DLQ entries. The read uses a 30 second visibility
timeout so concurrent inspections do not immediately see the same rows.
-}
readDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> Eff es [DlqEntry p]
readDlq job n
    | n <= 0 = pure []
    | otherwise = do
        messages <-
            Pgmq.readMessage
                ReadMessage
                    { queueName = job.jobQueue.dlqName
                    , delay = 30
                    , batchSize = Just n
                    , conditional = Nothing
                    }
        pure (fmap (toEntry job) (toList messages))

toEntry :: Job p -> Message -> DlqEntry p
toEntry job message =
    let body = unMessageBody message.body
     in case parseDlqEnvelope body of
            Left err ->
                DlqEntry
                    { dlqMessageId = message.messageId
                    , reason = "malformed_dlq_payload: " <> err
                    , originalPayload = Left (JobPayloadMalformed err)
                    , originalMessageId = Nothing
                    , originalEnqueuedAt = Nothing
                    , readCount = Nothing
                    , rawBody = body
                    }
            Right envelope ->
                DlqEntry
                    { dlqMessageId = message.messageId
                    , reason = envelope.deadLetterReason
                    , originalPayload = decodeJob job.jobCodec envelope.originalMessage
                    , originalMessageId = envelope.envelopeOriginalMessageId
                    , originalEnqueuedAt = envelope.envelopeOriginalEnqueuedAt
                    , readCount = envelope.envelopeReadCount
                    , rawBody = body
                    }

{- | Move up to @n@ DLQ rows back to the main queue. Redriven messages start a
fresh PGMQ @read_ct@ on the main queue. Malformed DLQ wrappers are left in the
DLQ for inspection.
-}
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
                        { queueName = job.jobQueue.dlqName
                        , delay = 30
                        , batchSize = Just (fromIntegral (min 100 (n - moved)))
                        , conditional = Nothing
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
                _ <-
                    Pgmq.sendMessage
                        SendMessage
                            { queueName = job.jobQueue.physicalName
                            , messageBody = MessageBody envelope.originalMessage
                            , delay = Nothing
                            }
                void $
                    Pgmq.deleteMessage
                        MessageQuery
                            { queueName = job.jobQueue.dlqName
                            , messageId = message.messageId
                            }
                pure (count + 1)

-- | Delete all rows currently in the DLQ.
purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es ()
purgeDlq job =
    void (Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName)

{- | Archive (retain) up to @n@ DLQ rows: move each out of the active DLQ table
@pgmq.q_<dlq>@ into the archive table @pgmq.a_<dlq>@, preserving @enqueued_at@ /
@read_ct@ and stamping @archived_at@. Returns the number archived. This is the
audit-retention counterpart to the delete-only 'purgeDlq'. At-most-once per row
per call; a crash before archiving leaves the row in the active DLQ for a re-run.
-}
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
                        { queueName = job.jobQueue.dlqName
                        , delay = 30
                        , batchSize = Just (fromIntegral (min 100 (n - archived)))
                        , conditional = Nothing
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

-- | Archive one specific DLQ row by message id. 'True' if a row was moved.
archiveDlqEntry :: (Pgmq :> es, IOE :> es) => Job p -> MessageId -> Eff es Bool
archiveDlqEntry job msgId =
    Pgmq.archiveMessage
        MessageQuery
            { queueName = job.jobQueue.dlqName
            , messageId = msgId
            }
