module Main (main) where

import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
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
import Keiro.Ops.Env
import Keiro.Ops.Parse (parseDuration)
import Keiro.Ops.Render
import Keiro.Ops.Timer qualified as OpsTimer
import Keiro.Ops.Workflow qualified as OpsWorkflow
import Keiro.Test.Postgres (withFreshDatabase, withFreshStore, withMigratedSuite)
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

main :: IO ()
main = withMigratedSuite $ \fixture -> hspec do
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
          awakeableId = maybe (error "test UUID") id (UUID.fromString "018f5f43-8a70-7b9a-9a9b-59d391a76710")
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
    { timerId = Timer.TimerId (maybe (error "test timer UUID") id (UUID.fromString rawId)),
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
