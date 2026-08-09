module Main (main) where

import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.Function qualified as Function
import Data.Functor ((<&>))
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Connection qualified as Hasql
import Hasql.Connection.Settings qualified as HasqlSettings
import Hasql.Session qualified as HasqlSession
import Keiro.DeadLetter
import Keiro.Inbox qualified as Inbox
import Keiro.Integration.Event
import Keiro.Ops.Env
import Keiro.Ops.Inbox qualified as OpsInbox
import Keiro.Ops.Outbox qualified as OpsOutbox
import Keiro.Ops.Parse (parseDuration)
import Keiro.Ops.Pgmq qualified as OpsPgmq
import Keiro.Ops.Projection qualified as OpsProjection
import Keiro.Ops.Render
import Keiro.Ops.Shard qualified as OpsShard
import Keiro.Ops.Snapshot qualified as OpsSnapshot
import Keiro.Ops.Stream qualified as OpsStream
import Keiro.Ops.Timer qualified as OpsTimer
import Keiro.Ops.Workflow qualified as OpsWorkflow
import Keiro.Outbox qualified as Outbox
import Keiro.PGMQ
import Keiro.Projection qualified as Projection
import Keiro.Snapshot.Schema
import Keiro.Subscription.Shard qualified as Shard
import Keiro.Test.Postgres (Fixture, withFreshDatabase, withFreshStore, withMigratedSuiteWith)
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (getStream, readStreamForward)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types
import Pgmq.Migration qualified as PgmqMigration
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

main :: IO ()
main = do
  pgmq <- either (fail . show) pure PgmqMigration.pgmqMigrations
  withMigratedSuiteWith [pgmq] $ \fixture -> hspec (spec fixture)

spec :: Fixture -> Spec
spec fixture = do
  describe "selectConnectionString" do
    it "prefers the explicit option, then the Keiro variable, then DATABASE_URL" do
      selectConnectionString (Just "explicit") (Just "keiro") (Just "database")
        `shouldBe` "explicit"
      selectConnectionString Nothing (Just "keiro") (Just "database")
        `shouldBe` "keiro"
      selectConnectionString Nothing Nothing (Just "database")
        `shouldBe` "database"

    it "uses an empty libpq string for standard PG environment fallbacks" do
      selectConnectionString Nothing Nothing Nothing `shouldBe` ""

  describe "parseDuration" do
    it "accepts bare seconds and the documented suffixes" do
      parseDuration "1.5" `shouldBe` Right 1.5
      parseDuration "2m" `shouldBe` Right 120
      parseDuration "3h" `shouldBe` Right 10800
      parseDuration "1d" `shouldBe` Right 86400

    it "rejects negative and malformed values" do
      parseDuration "-1s" `shouldSatisfy` isLeft
      parseDuration "soon" `shouldSatisfy` isLeft

  describe "renderHuman" do
    it "aligns columns without changing the structured JSON value" do
      let result =
            OpsResult
              { headers = ["name", "status"],
                rows = [["short", "running"], ["longer", "failed"]],
                jsonValue = object ["items" .= (["unchanged"] :: [String])]
              }
      renderHuman result
        `shouldBe` "name    status \n------  -------\nshort   running\nlonger  failed \n"

  describe "keiro-ops executable" $ around (withFreshDatabase fixture) do
    it "emits parseable JSON and refuses a mutation after schema drift" $ \connectionString -> do
      executable <- keiroOpsExecutable
      (listExit, listOutput, listError) <-
        readProcessWithExitCode
          executable
          ["--database-url", Text.unpack connectionString, "wf", "list", "--json"]
          ""
      listExit `shouldBe` ExitSuccess
      listError `shouldBe` ""
      Aeson.eitherDecodeStrict' (Text.Encoding.encodeUtf8 (Text.pack listOutput))
        `shouldBe` Right (Aeson.Array mempty)

      (previewExit, _, previewError) <-
        readProcessWithExitCode
          executable
          [ "--database-url",
            Text.unpack connectionString,
            "wf",
            "gc",
            "run-once",
            "--retention",
            "0s",
            "--json"
          ]
          ""
      previewExit `shouldBe` ExitFailure 1
      previewError `shouldSatisfy` Text.isInfixOf "preview only" . Text.pack
      previewError `shouldSatisfy` not . Text.isInfixOf "keiro-ops: ExitFailure" . Text.pack

      executeSql connectionString "ALTER TABLE keiro.keiro_timers ADD COLUMN ops_test_drift text"
      (mutationExit, _, mutationError) <-
        readProcessWithExitCode
          executable
          [ "--database-url",
            Text.unpack connectionString,
            "wf",
            "gc",
            "run-once",
            "--retention",
            "0s",
            "--force",
            "--json"
          ]
          ""
      mutationExit `shouldBe` ExitFailure 1
      mutationError `shouldSatisfy` Text.isInfixOf "refusing mutation" . Text.pack

  describe "workflow handlers" $ around (withFreshStore fixture) do
    it "lists and decodes a real journal without mutating it" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-1"
      seedStep store ref "received" (object ["amount" .= (42 :: Int)])

      listed <-
        OpsWorkflow.runCommand
          (opsEnv False store)
          (OpsWorkflow.List (OpsWorkflow.ListOptions [] Nothing Nothing 100))
      resultArrayLength listed `shouldBe` Just 1

      journal <-
        OpsWorkflow.runCommand
          (opsEnv False store)
          (OpsWorkflow.Journal (OpsWorkflow.InspectOptions ref Nothing))
      journalEventCount journal `shouldBe` Just 1

      row <- runStoreIO store (Instance.lookupInstance (WorkflowName "approval") (WorkflowId "wf-1"))
      fmap (fmap (.wakeAfter)) row `shouldBe` Right (Just Nothing)

    it "applies exact name/status filters and keyset cursors" $ \store -> do
      let first = OpsWorkflow.WorkflowRef "approval" "wf-a"
          second = OpsWorkflow.WorkflowRef "approval" "wf-b"
          other = OpsWorkflow.WorkflowRef "billing" "wf-c"
      seedStep store first "received" Aeson.Null
      seedStep store second "received" Aeson.Null
      seedStep store other "received" Aeson.Null

      page <-
        OpsWorkflow.runCommand
          (opsEnv False store)
          ( OpsWorkflow.List
              ( OpsWorkflow.ListOptions
                  [Instance.WfRunning]
                  (Just "approval")
                  (Just ("approval", "wf-a"))
                  1
              )
          )
      resultArrayLength page `shouldBe` Just 1
      firstWorkflowId page `shouldBe` Just "wf-b"

    it "previews cancellation without mutation, then records it with force" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-2"
      seedStep store ref "received" Aeson.Null

      preview <- OpsWorkflow.runCommand (opsEnv False store) (OpsWorkflow.Cancel ref)
      preview `shouldSatisfy` isPreview
      workflowStatus store ref `shouldReturn` Just Instance.WfRunning

      applied <- OpsWorkflow.runCommand (opsEnv True store) (OpsWorkflow.Cancel ref)
      applied `shouldSatisfy` isSucceeded
      workflowStatus store ref `shouldReturn` Just Instance.WfCancelled

    it "previews and applies failed-workflow resurrection and lease release" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-recover"
      now <- getCurrentTime
      expectStore store $
        appendJournalEntry
          (WorkflowName ref.workflowName)
          (WorkflowId ref.workflowId)
          WorkflowFailed {reason = "exhausted", recordedAt = now}

      resurrectPreview <- OpsWorkflow.runCommand (opsEnv False store) (OpsWorkflow.Resurrect ref)
      resurrectPreview `shouldSatisfy` isPreview
      workflowStatus store ref `shouldReturn` Just Instance.WfFailed

      resurrected <- OpsWorkflow.runCommand (opsEnv True store) (OpsWorkflow.Resurrect ref)
      resurrected `shouldSatisfy` isSucceeded
      workflowStatus store ref `shouldReturn` Just Instance.WfRunning

      claimed <-
        expectStore store $
          Instance.claimInstance
            "wedged-worker"
            300
            (WorkflowName ref.workflowName)
            (WorkflowId ref.workflowId)
      claimed `shouldBe` True

      releasePreview <- OpsWorkflow.runCommand (opsEnv False store) (OpsWorkflow.ReleaseLease ref)
      releasePreview `shouldSatisfy` isPreview
      workflowLeaseOwner store ref `shouldReturn` Just "wedged-worker"

      released <- OpsWorkflow.runCommand (opsEnv True store) (OpsWorkflow.ReleaseLease ref)
      released `shouldSatisfy` isSucceeded
      workflowLeaseOwner store ref `shouldReturn` Nothing

    it "previews and signals an awakeable through the supported library path" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-3"
          awakeableId = maybe (error "test UUID") Function.id (UUID.fromString "018f5f43-8a70-7b9a-9a9b-59d391a76710")
      seedStep store ref "awkid:approval" (Aeson.toJSON (AwakeableId awakeableId))
      expectStore store $ runTransaction (Awakeable.registerAwakeableTx awakeableId "approval" "wf-3")

      preview <-
        OpsWorkflow.runCommand
          (opsEnv False store)
          (OpsWorkflow.Awakeable (OpsWorkflow.AwakeableSignal awakeableId (OpsWorkflow.PayloadArg "{\"approved\":true}" (object ["approved" .= True]))))
      preview `shouldSatisfy` isPreview
      awakeableStatus store awakeableId `shouldReturn` Just Awakeable.Pending

      applied <-
        OpsWorkflow.runCommand
          (opsEnv True store)
          (OpsWorkflow.Awakeable (OpsWorkflow.AwakeableSignal awakeableId (OpsWorkflow.PayloadArg "{\"approved\":true}" (object ["approved" .= True]))))
      applied `shouldSatisfy` isSucceeded
      awakeableStatus store awakeableId `shouldReturn` Just Awakeable.Completed

    it "previews the exact GC candidates before deleting them" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-4"
          gcOptions = OpsWorkflow.GcOptions 0 10
      seedStep store ref "received" Aeson.Null
      _ <- OpsWorkflow.runCommand (opsEnv True store) (OpsWorkflow.Cancel ref)

      preview <- OpsWorkflow.runCommand (opsEnv False store) (OpsWorkflow.GcRunOnce gcOptions)
      resultArrayLengthFrom "candidates" preview `shouldBe` Just 1

      applied <- OpsWorkflow.runCommand (opsEnv True store) (OpsWorkflow.GcRunOnce gcOptions)
      applied `shouldSatisfy` isSucceeded
      workflowStatus store ref `shouldReturn` Nothing

  describe "timer handlers" $ around (withFreshStore fixture) do
    it "lists, previews, requeues, and dead-letters a stuck timer" $ \store -> do
      now <- getCurrentTime
      let request = timerRequest "018f5f43-8a70-7b9a-9a9b-59d391a76720" (addUTCTime (-60) now)
          timerId = request.timerId
      expectStore store (runTransaction (Timer.scheduleTimerTx request))
      claimed <- expectStore store (Timer.claimDueTimer now)
      fmap (.status) claimed `shouldBe` Just Timer.Firing

      tooManyAttempts <-
        OpsTimer.runCommand
          (opsEnv False store)
          (OpsTimer.StuckList (OpsTimer.StuckListOptions Nothing (Just 2)))
      resultArrayLength tooManyAttempts `shouldBe` Just 0

      listed <-
        OpsTimer.runCommand
          (opsEnv False store)
          (OpsTimer.StuckList (OpsTimer.StuckListOptions Nothing Nothing))
      resultArrayLength listed `shouldBe` Just 1

      preview <- OpsTimer.runCommand (opsEnv False store) (OpsTimer.Requeue timerId)
      preview `shouldSatisfy` isPreview
      timerStatus store timerId `shouldReturn` Just Timer.Firing

      requeued <- OpsTimer.runCommand (opsEnv True store) (OpsTimer.Requeue timerId)
      requeued `shouldSatisfy` isSucceeded
      timerStatus store timerId `shouldReturn` Just Timer.Scheduled

      retriedClaim <- expectStore store (Timer.claimDueTimer now)
      retriedClaim `shouldSatisfy` isJust
      retried <-
        OpsTimer.runCommand
          (opsEnv False store)
          (OpsTimer.StuckList (OpsTimer.StuckListOptions Nothing (Just 2)))
      resultArrayLength retried `shouldBe` Just 1

      deadPreview <- OpsTimer.runCommand (opsEnv False store) (OpsTimer.DeadLetter timerId "poison payload")
      deadPreview `shouldSatisfy` isPreview
      timerStatus store timerId `shouldReturn` Just Timer.Firing

      dead <- OpsTimer.runCommand (opsEnv True store) (OpsTimer.DeadLetter timerId "poison payload")
      dead `shouldSatisfy` isSucceeded
      timerStatus store timerId `shouldReturn` Just Timer.Dead

    it "previews and cancels a scheduled timer" $ \store -> do
      now <- getCurrentTime
      let request = timerRequest "018f5f43-8a70-7b9a-9a9b-59d391a76721" (addUTCTime 3600 now)
          timerId = request.timerId
      expectStore store (runTransaction (Timer.scheduleTimerTx request))

      preview <- OpsTimer.runCommand (opsEnv False store) (OpsTimer.Cancel timerId)
      preview `shouldSatisfy` isPreview
      timerStatus store timerId `shouldReturn` Just Timer.Scheduled

      cancelled <- OpsTimer.runCommand (opsEnv True store) (OpsTimer.Cancel timerId)
      cancelled `shouldSatisfy` isSucceeded
      timerStatus store timerId `shouldReturn` Just Timer.Cancelled

  describe "outbox handlers" $ around (withFreshStore fixture) do
    it "lists backlog and previews stale recovery without mutation" $ \store -> do
      now <- getCurrentTime
      let outboxId = testOutboxId "018f5f43-8a70-7b9a-9a9b-59d391a76801"
          event = sampleIntegrationEvent now "outbox-message"
      expectStore store (runTransaction (Outbox.enqueueOutboxTx (Outbox.OutboxMessage outboxId event)))

      backlog <- OpsOutbox.runCommand (opsEnv False store) OpsOutbox.Backlog
      resultCount backlog `shouldBe` Just 1

      claimNow <- getCurrentTime
      _ <- expectStore store (Outbox.claimOutboxBatch Outbox.BestEffort 1 claimNow)
      preview <- OpsOutbox.runCommand (opsEnv False store) (OpsOutbox.RequeueStuck 0 10)
      preview `shouldSatisfy` isPreview
      outboxStatus store outboxId `shouldReturn` Just Outbox.OutboxPublishing

      applied <- OpsOutbox.runCommand (opsEnv True store) (OpsOutbox.RequeueStuck 0 10)
      applied `shouldSatisfy` isSucceeded
      outboxStatus store outboxId `shouldReturn` Just Outbox.OutboxFailed

    it "surfaces dispatch dead letters through the supported API" $ \store -> do
      let sourceEvent = EventId (testUuid "018f5f43-8a70-7b9a-9a9b-59d391a76802")
      expectStore store $
        recordDispatchDeadLetter
          DispatchDeadLetter
            { dispatcherKind = DispatcherProcessManager,
              dispatcherName = "ops-pm",
              correlationId = "order-1",
              sourceEventId = sourceEvent,
              sourceGlobalPosition = GlobalPosition 1,
              emitIndex = 0,
              targetStreamName = StreamName "order-1",
              errorClass = "rejected",
              errorDetail = "operator fixture",
              attemptCount = 1
            }
      listed <- OpsOutbox.runCommand (opsEnv False store) (OpsOutbox.DispatchDeadLetters "ops-pm" 10)
      resultArrayLength listed `shouldBe` Just 1

  describe "inbox handlers" $ around (withFreshStore fixture) do
    it "previews poison marking and GC without bypassing inbox APIs" $ \store -> do
      now <- getCurrentTime
      let poison = sampleIntegrationEvent now "poison-message"
          completed = sampleIntegrationEvent now "completed-message"
      seedInbox store poison
      seedInbox store completed

      preview <- OpsInbox.runCommand (opsEnv False store) (OpsInbox.MarkFailed poison.source poison.messageId "poison")
      preview `shouldSatisfy` isPreview
      inboxStatus store poison.source poison.messageId `shouldReturn` Just Inbox.InboxCompleted

      marked <- OpsInbox.runCommand (opsEnv True store) (OpsInbox.MarkFailed poison.source poison.messageId "poison")
      marked `shouldSatisfy` isSucceeded
      inboxStatus store poison.source poison.messageId `shouldReturn` Just Inbox.InboxFailed

      gcPreview <- OpsInbox.runCommand (opsEnv False store) (OpsInbox.Gc 0)
      gcPreview `shouldSatisfy` isPreview
      inboxStatus store completed.source completed.messageId `shouldReturn` Just Inbox.InboxCompleted

      gcApplied <- OpsInbox.runCommand (opsEnv True store) (OpsInbox.Gc 0)
      gcApplied `shouldSatisfy` isSucceeded
      inboxStatus store completed.source completed.messageId `shouldReturn` Nothing

  describe "pgmq handlers" $ around (withFreshStore fixture) do
    it "previews and redrives a DLQ entry, which is then consumable" $ \store -> do
      let queue = "keiro_ops_test.redrive"
          job = rawValueJob queue
          runPgmqUnit action = do
            result <- runJobEff (JobRuntime store.pool Nothing) action
            either (fail . show) pure result
          depths = do
            result <- runJobEff (JobRuntime store.pool Nothing) $ do
              mainMetrics <- jobQueueMetrics job
              dlqMetrics <- jobDlqMetrics job
              pure (mainMetrics.queueLength, dlqMetrics.queueLength)
            either (fail . show) pure result
      runPgmqUnit $ do
        ensureJobQueue job
        _ <- enqueue job (object ["kind" .= ("poison" :: Text)])
        _ <- runJobOnce 1 job (\_ -> pure (Dead "bad"))
        pure ()

      preview <- OpsPgmq.runCommand (opsEnv False store) (OpsPgmq.Dlq (OpsPgmq.Redrive queue 10))
      preview `shouldSatisfy` isPreview
      (mainBefore, dlqBefore) <- depths
      (mainBefore, dlqBefore) `shouldBe` (0, 1)

      applied <- OpsPgmq.runCommand (opsEnv True store) (OpsPgmq.Dlq (OpsPgmq.Redrive queue 10))
      applied `shouldSatisfy` isSucceeded
      (mainAfter, dlqAfter) <- depths
      (mainAfter, dlqAfter) `shouldBe` (1, 0)

      runPgmqUnit (runJobOnce 1 job (\_ -> pure Done))
      (mainFinal, _) <- depths
      mainFinal `shouldBe` 0

      runPgmqUnit $ do
        _ <- enqueue job (object ["kind" .= ("purge-me" :: Text)])
        _ <- runJobOnce 1 job (\_ -> pure (Dead "still bad"))
        pure ()
      purgePreview <- OpsPgmq.runCommand (opsEnv False store) (OpsPgmq.Dlq (OpsPgmq.Purge queue))
      purgePreview `shouldSatisfy` isPreview
      (_, dlqBeforePurge) <- depths
      dlqBeforePurge `shouldBe` 1

      purged <- OpsPgmq.runCommand (opsEnv True store) (OpsPgmq.Dlq (OpsPgmq.Purge queue))
      purged `shouldSatisfy` isSucceeded
      (_, dlqAfterPurge) <- depths
      dlqAfterPurge `shouldBe` 0

  describe "projection handlers" $ around (withFreshStore fixture) do
    it "prunes only the named dedup rows" $ \store -> do
      _ <- seedKirokuEvent store "projection-source" "018f5f43-8a70-7b9a-9a9b-59d391a76810" Nothing
      events <- expectStore store (readStreamForward (StreamName "projection-source") (StreamVersion 0) 1)
      let recorded = Vector.head events
          projection =
            Projection.AsyncProjection
              { name = "ops-dedup",
                readModelName = "ops-read-model",
                subscriptionName = "ops-projection",
                applyRecorded = \_ -> pure (),
                idempotencyKey = (.eventId)
              }
      _ <- expectStore store (runTransaction (Projection.applyAsyncProjectionUnfenced projection recorded))
      future <- addUTCTime 60 <$> getCurrentTime
      prunePreview <- OpsProjection.runCommand (opsEnv False store) (OpsProjection.PruneDedup "ops-dedup" future)
      prunePreview `shouldSatisfy` isPreview
      jsonIntegerFromPreview "affected" prunePreview `shouldBe` Just 1
      pruned <- OpsProjection.runCommand (opsEnv True store) (OpsProjection.PruneDedup "ops-dedup" future)
      jsonInteger "affected" pruned `shouldBe` Just 1

  describe "shard handlers" $ around (withFreshStore fixture) do
    it "previews exact buckets and relinquishes them for another worker" $ \store -> do
      let subscription = SubscriptionName "ops-shards"
          worker = Shard.WorkerId (testUuid "018f5f43-8a70-7b9a-9a9b-59d391a76803")
          lease = Shard.ShardLease subscription worker 2 300
      expectStore store (Shard.ensureShards lease)
      _ <- expectStore store (Shard.acquireOwnedBuckets lease 1)
      _ <- expectStore store (Shard.acquireOwnedBuckets lease 1)

      status <- OpsShard.runCommand (opsEnv False store) (OpsShard.Status "ops-shards")
      resultArrayLengthFromObject "ownership" status `shouldBe` Just 2

      preview <- OpsShard.runCommand (opsEnv False store) (OpsShard.Relinquish "ops-shards" worker)
      preview `shouldSatisfy` isPreview
      ownersBefore <- expectStore store (Shard.ownershipSnapshotFor subscription)
      length [() | (_, Just owner, _) <- ownersBefore, owner == worker] `shouldBe` 2

      released <- OpsShard.runCommand (opsEnv True store) (OpsShard.Relinquish "ops-shards" worker)
      released `shouldSatisfy` isSucceeded
      ownersAfter <- expectStore store (Shard.ownershipSnapshotFor subscription)
      ownersAfter `shouldSatisfy` all (\(_, owner, _) -> owner == Nothing)

      let replacement = Shard.WorkerId (testUuid "018f5f43-8a70-7b9a-9a9b-59d391a76804")
          replacementLease = Shard.ShardLease subscription replacement 2 300
      _ <- expectStore store (Shard.acquireOwnedBuckets replacementLease 1)
      _ <- expectStore store (Shard.acquireOwnedBuckets replacementLease 1)
      replacementOwners <- expectStore store (Shard.ownershipSnapshotFor subscription)
      replacementOwners `shouldSatisfy` all (\(_, owner, _) -> owner == Just replacement)

  describe "snapshot handlers" $ around (withFreshStore fixture) do
    it "refuses uncovered truncation, passes matching coverage, and deletes advisories" $ \store -> do
      appended <- seedKirokuEvent store "snapshot-ops" "018f5f43-8a70-7b9a-9a9b-59d391a76811" Nothing
      let expected = OpsSnapshot.ExpectedDiscriminators 7 "regs-v7" "fold-v7"
      expectStore store $
        writeSnapshotRow
          SnapshotWrite
            { streamId = appended.streamId,
              streamVersion = appended.streamVersion,
              state = object ["count" .= (1 :: Int)],
              stateCodecVersion = expected.stateCodecVersion,
              regfileShapeHash = expected.regfileShapeHash,
              stateShapeHash = expected.stateShapeHash
            }

      missing <- OpsSnapshot.runCommand (opsEnv False store) (OpsSnapshot.TruncationPreflight "no-snapshot" (StreamVersion 2) (Just expected))
      jsonBool "passed" missing `shouldBe` Just False

      covered <- OpsSnapshot.runCommand (opsEnv False store) (OpsSnapshot.TruncationPreflight "snapshot-ops" (StreamVersion 2) (Just expected))
      jsonBool "passed" covered `shouldBe` Just True

      preview <- OpsSnapshot.runCommand (opsEnv False store) (OpsSnapshot.Delete "snapshot-ops")
      preview `shouldSatisfy` isPreview
      beforeDelete <- expectStore store (lookupSnapshotRow appended.streamId)
      beforeDelete `shouldSatisfy` isJust

      deleted <- OpsSnapshot.runCommand (opsEnv True store) (OpsSnapshot.Delete "snapshot-ops")
      deleted `shouldSatisfy` isSucceeded
      expectStore store (lookupSnapshotRow appended.streamId) `shouldReturn` Nothing

  describe "stream handlers" $ around (withFreshStore fixture) do
    it "reads causation and applies reversible lifecycle operations" $ \store -> do
      first <- seedKirokuEvent store "stream-ops" "018f5f43-8a70-7b9a-9a9b-59d391a76812" Nothing
      second <- seedKirokuEvent store "stream-ops" "018f5f43-8a70-7b9a-9a9b-59d391a76813" (Just (eventUuid first))

      shown <- OpsStream.runCommand (opsEnv False store) (OpsStream.Show "stream-ops" (StreamVersion 0) 10)
      resultArrayLengthFromObject "events" shown `shouldBe` Just 2

      causes <- OpsStream.runCommand (opsEnv False store) (OpsStream.Causation (EventId (eventUuid second)))
      resultArrayLength causes `shouldBe` Just 2

      softPreview <- OpsStream.runCommand (opsEnv False store) (OpsStream.SoftDelete "stream-ops")
      softPreview `shouldSatisfy` isPreview
      streamDeleted store "stream-ops" `shouldReturn` Just False

      softDeleted <- OpsStream.runCommand (opsEnv True store) (OpsStream.SoftDelete "stream-ops")
      softDeleted `shouldSatisfy` isSucceeded
      streamDeleted store "stream-ops" `shouldReturn` Just True

      restored <- OpsStream.runCommand (opsEnv True store) (OpsStream.Undelete "stream-ops")
      restored `shouldSatisfy` isSucceeded
      streamDeleted store "stream-ops" `shouldReturn` Just False

    it "previews and applies truncate markers and permanent deletion" $ \store -> do
      _ <- seedKirokuEvent store "stream-destructive" "018f5f43-8a70-7b9a-9a9b-59d391a76814" Nothing
      _ <- seedKirokuEvent store "stream-destructive" "018f5f43-8a70-7b9a-9a9b-59d391a76815" Nothing

      truncatePreview <-
        OpsStream.runCommand
          (opsEnv False store)
          (OpsStream.TruncateBefore (OpsStream.SetTruncateBefore "stream-destructive" (StreamVersion 2) Nothing True))
      truncatePreview `shouldSatisfy` isPreview
      streamTruncateBefore store "stream-destructive" `shouldReturn` Just (StreamVersion 0)

      truncated <-
        OpsStream.runCommand
          (opsEnv True store)
          (OpsStream.TruncateBefore (OpsStream.SetTruncateBefore "stream-destructive" (StreamVersion 2) Nothing True))
      truncated `shouldSatisfy` isSucceeded
      streamTruncateBefore store "stream-destructive" `shouldReturn` Just (StreamVersion 2)

      clearPreview <- OpsStream.runCommand (opsEnv False store) (OpsStream.TruncateBefore (OpsStream.ClearTruncateBefore "stream-destructive"))
      clearPreview `shouldSatisfy` isPreview
      streamTruncateBefore store "stream-destructive" `shouldReturn` Just (StreamVersion 2)

      cleared <- OpsStream.runCommand (opsEnv True store) (OpsStream.TruncateBefore (OpsStream.ClearTruncateBefore "stream-destructive"))
      cleared `shouldSatisfy` isSucceeded
      streamTruncateBefore store "stream-destructive" `shouldReturn` Just (StreamVersion 0)

      deletePreview <- OpsStream.runCommand (opsEnv False store) (OpsStream.HardDelete "stream-destructive")
      deletePreview `shouldSatisfy` isPreview
      beforeDelete <- expectStore store (getStream (StreamName "stream-destructive"))
      beforeDelete `shouldSatisfy` isJust

      deleted <- OpsStream.runCommand (opsEnv True store) (OpsStream.HardDelete "stream-destructive")
      deleted `shouldSatisfy` isSucceeded
      expectStore store (getStream (StreamName "stream-destructive")) `shouldReturn` Nothing

data SeededEvent = SeededEvent
  { streamId :: !StreamId,
    streamVersion :: !StreamVersion,
    globalPosition :: !GlobalPosition,
    eventId :: !EventId
  }

sampleIntegrationEvent :: UTCTime -> Text -> IntegrationEvent
sampleIntegrationEvent now messageId =
  IntegrationEvent
    { messageId,
      source = "ops-source",
      destination = "ops-destination",
      key = Just "entity-1",
      eventType = "ops.event",
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes = ByteString.pack "{\"ok\":true}",
      occurredAt = now,
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

seedInbox :: KirokuStore -> IntegrationEvent -> IO ()
seedInbox store event = do
  result <-
    expectStore store $
      Inbox.runInboxTransaction
        Nothing
        Inbox.PreferIntegrationMessageId
        event
        Nothing
        (\_ -> pure ())
  result `shouldBe` Right (Inbox.InboxProcessed ())

outboxStatus :: KirokuStore -> Outbox.OutboxId -> IO (Maybe Outbox.OutboxStatus)
outboxStatus store outboxId =
  expectStore store (Outbox.lookupOutbox outboxId) <&> fmap (.status)

inboxStatus :: KirokuStore -> Text -> Text -> IO (Maybe Inbox.InboxStatus)
inboxStatus store source messageId =
  expectStore store (Inbox.lookupInbox source messageId) <&> fmap (.status)

testOutboxId :: String -> Outbox.OutboxId
testOutboxId = Outbox.OutboxId . testUuid

testUuid :: String -> UUID.UUID
testUuid raw = maybe (error "test UUID") Function.id (UUID.fromString raw)

rawValueJob :: Text -> Job Aeson.Value
rawValueJob name =
  Job
    { jobName = name,
      jobQueue = queueRef name,
      jobCodec = aesonJobCodec,
      jobPolicy = defaultRetryPolicy
    }

seedKirokuEvent :: KirokuStore -> Text -> String -> Maybe UUID.UUID -> IO SeededEvent
seedKirokuEvent store name rawId cause = do
  let eventId = EventId (testUuid rawId)
  appended <-
    expectStore store $
      appendToStream
        (StreamName name)
        AnyVersion
        [ EventData
            { eventId = Just eventId,
              eventType = EventType "ops.event",
              payload = object ["stream" .= name],
              metadata = Nothing,
              causationId = cause,
              correlationId = Nothing
            }
        ]
  pure
    SeededEvent
      { streamId = appended.streamId,
        streamVersion = appended.streamVersion,
        globalPosition = appended.globalPosition,
        eventId
      }

eventUuid :: SeededEvent -> UUID.UUID
eventUuid seeded = case seeded.eventId of EventId value -> value

streamDeleted :: KirokuStore -> Text -> IO (Maybe Bool)
streamDeleted store name =
  expectStore store (getStream (StreamName name)) <&> fmap (isJust . (.deletedAt))

streamTruncateBefore :: KirokuStore -> Text -> IO (Maybe StreamVersion)
streamTruncateBefore store name =
  expectStore store (getStream (StreamName name)) <&> fmap (.truncateBefore)

opsEnv :: Bool -> KirokuStore -> OpsEnv
opsEnv force store =
  OpsEnv
    { store,
      outputMode = Json,
      force,
      schemaDrift = [],
      allowSchemaDrift = False
    }

seedStep :: KirokuStore -> OpsWorkflow.WorkflowRef -> Text -> Aeson.Value -> IO ()
seedStep store ref stepName payload = do
  now <- getCurrentTime
  expectStore store $
    appendJournalEntry
      (WorkflowName ref.workflowName)
      (WorkflowId ref.workflowId)
      StepRecorded {stepName, result = payload, recordedAt = now}

expectStore :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO a
expectStore store action = runStoreIO store action >>= either (fail . show) pure

workflowStatus :: KirokuStore -> OpsWorkflow.WorkflowRef -> IO (Maybe Instance.WorkflowStatus)
workflowStatus store ref = do
  result <- runStoreIO store (Instance.lookupInstance (WorkflowName ref.workflowName) (WorkflowId ref.workflowId))
  either (fail . show) (pure . fmap (.status)) result

workflowLeaseOwner :: KirokuStore -> OpsWorkflow.WorkflowRef -> IO (Maybe Text)
workflowLeaseOwner store ref = do
  result <- runStoreIO store (Instance.lookupInstance (WorkflowName ref.workflowName) (WorkflowId ref.workflowId))
  either (fail . show) (pure . (>>= (.leasedBy))) result

awakeableStatus :: KirokuStore -> UUID.UUID -> IO (Maybe Awakeable.AwakeableStatus)
awakeableStatus store awakeableId = do
  result <- runStoreIO store (Awakeable.lookupAwakeable awakeableId)
  either (fail . show) (pure . fmap (.status)) result

timerStatus :: KirokuStore -> Timer.TimerId -> IO (Maybe Timer.TimerStatus)
timerStatus store timerId = do
  result <- runStoreIO store (Timer.lookupTimer timerId)
  either (fail . show) (pure . fmap (.status)) result

timerRequest :: String -> UTCTime -> Timer.TimerRequest
timerRequest rawId fireAt =
  Timer.TimerRequest
    { timerId = Timer.TimerId (maybe (error "test timer UUID") Function.id (UUID.fromString rawId)),
      processManagerName = "billing",
      correlationId = "invoice-1",
      fireAt,
      payload = object ["kind" .= ("reminder" :: Text)]
    }

resultArrayLength :: OpsOutcome -> Maybe Int
resultArrayLength = \case
  Succeeded OpsResult {jsonValue = Aeson.Array values} -> Just (Vector.length values)
  _ -> Nothing

resultArrayLengthFrom :: Key -> OpsOutcome -> Maybe Int
resultArrayLengthFrom key = \case
  PreviewRequired OpsResult {jsonValue = Aeson.Object value} _ ->
    case KeyMap.lookup key value of
      Just (Aeson.Array values) -> Just (Vector.length values)
      _ -> Nothing
  _ -> Nothing

resultArrayLengthFromObject :: Key -> OpsOutcome -> Maybe Int
resultArrayLengthFromObject key = \case
  Succeeded OpsResult {jsonValue = Aeson.Object value} ->
    case KeyMap.lookup key value of
      Just (Aeson.Array values) -> Just (Vector.length values)
      _ -> Nothing
  _ -> Nothing

resultCount :: OpsOutcome -> Maybe Int
resultCount = fmap fromIntegral . jsonInteger "count"

jsonInteger :: Key -> OpsOutcome -> Maybe Int64
jsonInteger key = \case
  Succeeded OpsResult {jsonValue = Aeson.Object value} -> numberAt key value
  _ -> Nothing

jsonIntegerFromPreview :: Key -> OpsOutcome -> Maybe Int64
jsonIntegerFromPreview key = \case
  PreviewRequired OpsResult {jsonValue = Aeson.Object value} _ -> numberAt key value
  _ -> Nothing

numberAt :: Key -> KeyMap.KeyMap Aeson.Value -> Maybe Int64
numberAt key value = do
  Aeson.Number number <- KeyMap.lookup key value
  pure (floor number)

jsonBool :: Key -> OpsOutcome -> Maybe Bool
jsonBool key = \case
  Succeeded OpsResult {jsonValue = Aeson.Object value} -> do
    Aeson.Bool result <- KeyMap.lookup key value
    pure result
  _ -> Nothing

firstWorkflowId :: OpsOutcome -> Maybe Text
firstWorkflowId = \case
  Succeeded OpsResult {jsonValue = Aeson.Array values} -> do
    Aeson.Object first <- values Vector.!? 0
    Aeson.String workflowId <- KeyMap.lookup "workflow_id" first
    pure workflowId
  _ -> Nothing

journalEventCount :: OpsOutcome -> Maybe Int
journalEventCount = \case
  Succeeded OpsResult {jsonValue = Aeson.Object value} ->
    case KeyMap.lookup "events" value of
      Just (Aeson.Array events) -> Just (Vector.length events)
      _ -> Nothing
  _ -> Nothing

isPreview :: OpsOutcome -> Bool
isPreview PreviewRequired {} = True
isPreview _ = False

isSucceeded :: OpsOutcome -> Bool
isSucceeded Succeeded {} = True
isSucceeded _ = False

isLeft :: Either a b -> Bool
isLeft Left {} = True
isLeft Right {} = False

keiroOpsExecutable :: IO FilePath
keiroOpsExecutable = do
  (exitCode, stdoutText, stderrText) <-
    readProcessWithExitCode "cabal" ["list-bin", "exe:keiro-ops"] ""
  case exitCode of
    ExitSuccess -> pure (Text.unpack (Text.strip (Text.pack stdoutText)))
    ExitFailure code -> fail ("cabal list-bin keiro-ops failed (" <> show code <> "): " <> stderrText)

executeSql :: Text -> Text -> IO ()
executeSql connectionString sql =
  bracket acquire Hasql.release $ \connection -> do
    result <- Hasql.use connection (HasqlSession.script sql)
    either (fail . show) pure result
  where
    acquire = do
      result <- Hasql.acquire (HasqlSettings.connectionString connectionString)
      either (fail . show) pure result
