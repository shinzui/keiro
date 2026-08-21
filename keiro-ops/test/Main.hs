module Main (main) where

import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.Either (isRight)
import Data.Function qualified as Function
import Data.Functor ((<&>))
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
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
import Hasql.Transaction qualified as Tx
import Keiro.DeadLetter
import Keiro.Inbox qualified as Inbox
import Keiro.Integration.Event
import Keiro.Ops (AppHooks (..))
import Keiro.Ops qualified as Ops
import Keiro.Ops.Env
import Keiro.Ops.Inbox qualified as OpsInbox
import Keiro.Ops.Outbox qualified as OpsOutbox
import Keiro.Ops.Parse (parseDuration)
import Keiro.Ops.Pgmq qualified as OpsPgmq
import Keiro.Ops.Projection qualified as OpsProjection
import Keiro.Ops.Rebuild qualified as OpsRebuild
import Keiro.Ops.Render
import Keiro.Ops.ReplayAudit qualified as OpsReplayAudit
import Keiro.Ops.Shard qualified as OpsShard
import Keiro.Ops.Snapshot qualified as OpsSnapshot
import Keiro.Ops.Stream qualified as OpsStream
import Keiro.Ops.Timer qualified as OpsTimer
import Keiro.Ops.Workflow qualified as OpsWorkflow
import Keiro.Outbox qualified as Outbox
import Keiro.PGMQ
import Keiro.Projection qualified as Projection
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.Projection.Catalog.Operations qualified as CatalogOperations
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Snapshot.Schema
import Keiro.Subscription.Shard qualified as Shard
import Keiro.Test.Postgres (Fixture, withFreshDatabase, withFreshStore, withMigratedSuiteWith)
import Keiro.Timer qualified as Timer
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Resume (WorkflowDef (..), defaultWorkflowResumeOptions)
import Keiro.Workflow.Sleep (sleepNamed)
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.HistoryRetention (StreamHistoryUnavailable (..))
import Kiroku.Store.Lifecycle (hardDeleteStream)
import Kiroku.Store.Read (getStream, readStreamForward)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types
import Options.Applicative qualified as Optparse
import Pgmq.Migration qualified as PgmqMigration
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

main :: IO ()
main = do
  pgmq <- either (fail . show) pure PgmqMigration.pgmqMigrations
  withMigratedSuiteWith [pgmq] $ \fixture -> hspec (spec fixture)

embeddedHooks :: AppHooks
embeddedHooks =
  AppHooks
    { workflowResume = Just (Map.empty, defaultWorkflowResumeOptions),
      timerFire = Just (\_ -> pure Nothing),
      replayAudit = Just (OpsReplayAudit.OpsAuditConfig []),
      projectionCatalog = Just emptyCatalogOperations
    }

emptyCatalogOperations :: CatalogOperations.ProjectionCatalogOperations
emptyCatalogOperations =
  case Catalog.validateProjectionCatalog Catalog.emptyProjectionCatalog of
    Catalog.Failure diagnostics -> error ("empty projection catalog was invalid: " <> show diagnostics)
    Catalog.Success catalog -> CatalogOperations.projectionCatalogOperations catalog

parseOps :: AppHooks -> [String] -> Optparse.ParserResult Ops.OpsInvocation
parseOps hooks = Optparse.execParserPure Optparse.defaultPrefs (Ops.opsCommandTree hooks)

isParseSuccess :: Optparse.ParserResult value -> Bool
isParseSuccess Optparse.Success {} = True
isParseSuccess _ = False

isParseFailure :: Optparse.ParserResult value -> Bool
isParseFailure Optparse.Failure {} = True
isParseFailure _ = False

spec :: Fixture -> Spec
spec fixture = do
  describe "embedded command tree" do
    it "omits code-dependent commands from the standalone tree" do
      isParseFailure (parseOps Ops.emptyAppHooks ["wf", "resume-once"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["timer", "drain-once"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["replay-audit", "--full"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["rebuild", "list"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["rebuild", "adopt", "ops-group"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["rebuild", "versioned", "status", "ops-run"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["rebuild", "retired"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["rebuild", "external-read", "counter_reader", "1"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["rebuild", "reproject-stream", "ops-group", "ops-projection", "orders-1"]) `shouldBe` True

    it "mounts every code-dependent command from typed application hooks" do
      isParseSuccess (parseOps embeddedHooks ["wf", "resume-once"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["timer", "drain-once"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["replay-audit", "--full"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "list"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "adopt", "ops-group"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "versioned", "status", "ops-run"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "versioned", "resume", "ops-run"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "versioned", "abandon", "ops-run"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "retired"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "drop-retired", "65b86cd6-550c-47c3-ae99-4039a85a11ad"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "external-read", "counter_reader", "1"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "retire-external-read", "counter_reader", "1"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["rebuild", "reproject-stream", "ops-group", "ops-projection", "orders-1"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["outbox", "list", "--source", "ops-source", "--status", "rejected"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["rebuild", "retire-external-read", "counter_reader", "0"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["rebuild", "reproject-stream", "ops-group", "ops-projection", "orders-1", "--page-size", "0"]) `shouldBe` True

    it "parses a complete versioned start and rejects malformed generation identities" do
      let versionedStart =
            [ "rebuild",
              "versioned",
              "start",
              "ops-group",
              "--run-id",
              "ops-versioned-run",
              "--serving-revision",
              "revision-v1",
              "--candidate-revision",
              "revision-v2",
              "--target-mode",
              "clone",
              "--requested-by",
              "operator",
              "--reason",
              "schema repair"
            ]
      isParseSuccess (parseOps embeddedHooks versionedStart) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["rebuild", "drop-retired", "not-a-uuid"]) `shouldBe` True

  describe "numeric option rejection" do
    it "rejects non-finite durations on every duration flag" do
      isParseFailure (parseOps embeddedHooks ["outbox", "gc-sent", "--older-than", "NaN"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["outbox", "requeue-stuck", "--older-than", "Infinity"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["inbox", "gc", "--older-than", "NaN"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["timer", "stuck", "list", "--min-age", "NaNd"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "NaN", "--batch", "100"]) `shouldBe` True

    it "rejects non-positive and wrapped integer options at parse time" do
      isParseFailure (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "30d", "--batch", "0"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "30d", "--batch=-5"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["wf", "list", "--limit", "0"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["replay-audit", "--full", "--resume-from", "-1"]) `shouldBe` True
      isParseFailure (parseOps embeddedHooks ["outbox", "list", "--source", "s", "--limit", "18446744073709551716"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["wf", "gc", "run-once", "--retention", "30d", "--batch", "100"]) `shouldBe` True
      isParseSuccess (parseOps embeddedHooks ["replay-audit", "--full", "--resume-from", "0"]) `shouldBe` True

    it "shares non-negative admission across global positions, stream versions, and generations" do
      let rebuild position = ["rebuild", "start", "ops-group", "--run-id", "ops-run", "--requested-by", "test", "--reason", "test", "--from", position]
          snapshot version = ["snapshot", "truncation-preflight", "--stream", "orders-1", "--before", version]
          stream version = ["stream", "show", "orders-1", "--from", version]
          workflow generation = ["wf", "steps", "orders", "1", "--generation", generation]
      mapM_ (\args -> isParseFailure (parseOps embeddedHooks args) `shouldBe` True) [rebuild "-1", snapshot "-1", stream "-1", workflow "-1"]
      mapM_ (\args -> isParseSuccess (parseOps embeddedHooks args) `shouldBe` True) [rebuild "0", snapshot "0", stream "0", workflow "0"]

  describe "targeted stream repair command" $
    around (withFreshStore fixture) $ do
      it "requires a positive event admission limit" $ \_ -> do
        let command limit =
              [ "rebuild",
                "reproject-stream",
                "ops-group",
                "ops-projection",
                "ops-1",
                "--max-events",
                limit
              ]
        isParseSuccess (parseOps embeddedHooks (command "100")) `shouldBe` True
        isParseFailure (parseOps embeddedHooks (command "0")) `shouldBe` True

      it "classifies the command as mutating and renders a stable typed refusal" $ \store -> do
        let command =
              OpsRebuild.ReprojectStream
                OpsRebuild.ReprojectStreamOptions
                  { groupId = either (error . show) Function.id (Catalog.mkRebuildGroupId "ops-group"),
                    projectionId = either (error . show) Function.id (Catalog.mkProjectionId "ops-projection"),
                    streamName = StreamName "orders-1",
                    pageSize = 500,
                    maxEvents = 1000
                  }
        OpsRebuild.isMutation command `shouldBe` True
        outcome <- OpsRebuild.runCommand (opsEnv False store) emptyCatalogOperations command
        case outcome of
          Failed detail ->
            detail `shouldSatisfy` Text.isPrefixOf "stream-reprojection-group-unregistered:"
          other -> expectationFailure ("expected a typed targeted-repair refusal, got " <> show other)

      it "keeps every typed refusal code distinct and stable" $ \_ -> do
        let group = opsGroupId
            otherGroup = opsGroupBId
            projection = catalogIdentity Catalog.mkProjectionId "ops-projection"
            revision = catalogIdentity Catalog.mkProjectionRevisionId "ops-revision"
            source = catalogIdentity Catalog.mkSourceId "ops-source"
            target = catalogIdentity Catalog.mkTargetId "ops-target"
            dedup = catalogIdentity Catalog.mkDedupKeyId "ops-dedup"
            stream = StreamName "ops-1"
            version = StreamVersion 1
            errors =
              [ Rebuild.StreamReprojectionInvalidPageSize 0,
                Rebuild.StreamReprojectionInvalidMaxEvents 0,
                Rebuild.StreamReprojectionEventLimitExceeded stream 2 1,
                Rebuild.StreamReprojectionGroupUnregistered group,
                Rebuild.StreamReprojectionActiveRebuild group (opsRebuildRunId "ops-active"),
                Rebuild.StreamReprojectionGroupUnavailable group "failed" False False,
                Rebuild.StreamReprojectionSliceDrift group "expected" "actual",
                Rebuild.StreamReprojectionServingRevisionUnavailable group revision,
                Rebuild.StreamReprojectionServingBindingInvalid group revision "invalid binding",
                Rebuild.StreamReprojectionUnknownProjection projection,
                Rebuild.StreamReprojectionProjectionGroupMismatch projection group otherGroup,
                Rebuild.StreamReprojectionPolicyUnavailable revision projection,
                Rebuild.StreamReprojectionSourceMismatch source stream,
                Rebuild.StreamReprojectionHistoryUnavailable (StreamHistoryNotFound stream),
                Rebuild.StreamReprojectionSoftDeleted stream,
                Rebuild.StreamReprojectionTruncated stream version,
                Rebuild.StreamReprojectionForeignEvent stream version,
                Rebuild.StreamReprojectionClearFailed "clear failed",
                Rebuild.StreamReprojectionClearEvidenceInvalid [target] [],
                Rebuild.StreamReprojectionDecodeFailed version (Catalog.ReplayDecodeError "decode failed"),
                Rebuild.StreamReprojectionVerificationFailed "verification failed",
                Rebuild.StreamReprojectionDedupIdentityUnavailable dedup,
                Rebuild.StreamReprojectionHistoryIncomplete version (StreamVersion 0)
              ]
        map OpsRebuild.streamReprojectionErrorCode errors
          `shouldBe` [ "stream-reprojection-invalid-page-size",
                       "stream-reprojection-invalid-max-events",
                       "stream-reprojection-event-limit-exceeded",
                       "stream-reprojection-group-unregistered",
                       "stream-reprojection-active-rebuild",
                       "stream-reprojection-group-unavailable",
                       "stream-reprojection-slice-drift",
                       "stream-reprojection-serving-revision-unavailable",
                       "stream-reprojection-serving-binding-invalid",
                       "stream-reprojection-unknown-projection",
                       "stream-reprojection-projection-group-mismatch",
                       "stream-reprojection-policy-unavailable",
                       "stream-reprojection-source-mismatch",
                       "stream-reprojection-history-unavailable",
                       "stream-reprojection-soft-deleted",
                       "stream-reprojection-truncated",
                       "stream-reprojection-foreign-event",
                       "stream-reprojection-clear-failed",
                       "stream-reprojection-clear-evidence-invalid",
                       "stream-reprojection-decode-failed",
                       "stream-reprojection-verification-failed",
                       "stream-reprojection-dedup-identity-unavailable",
                       "stream-reprojection-history-incomplete"
                     ]

  describe "catalog rebuild adoption" $ around (withFreshStore fixture) do
    it "previews exact slice changes and adopts them only with force" $ \store -> do
      expectStore store $ runTransaction $ Tx.sql (ByteString.pack "CREATE SCHEMA app; CREATE TABLE app.ops_catalog (id bigint PRIMARY KEY)")
      current <- expectValidatedCatalog (opsCatalog "ops-codec-v1")
      changed <- expectValidatedCatalog (opsCatalog "ops-codec-v2")
      registered <- expectStore store (Rebuild.registerProjectionCatalog current)
      registered `shouldSatisfy` isRight
      let operations = CatalogOperations.projectionCatalogOperations changed
          command = OpsRebuild.Adopt (OpsRebuild.AdoptOptions (NonEmpty.singleton opsGroupId))
          previewEnv =
            OpsEnv
              { store,
                outputMode = HumanTable,
                force = False,
                schemaDrift = [],
                allowSchemaDrift = False
              }

      preview <- OpsRebuild.runCommand previewEnv operations command
      case preview of
        PreviewRequired result invocation -> do
          result.headers `shouldBe` ["name", "kind", "state", "scope", "stored", "current"]
          case result.rows of
            [group, "group", state, scope, stored, currentSlice] : _ -> do
              group `shouldBe` "ops-group"
              state `shouldBe` "slice-changed"
              scope `shouldBe` "adopt"
              stored `shouldSatisfy` Text.isPrefixOf "slice-v6:"
              currentSlice `shouldSatisfy` Text.isPrefixOf "slice-v6:"
              stored `shouldNotBe` currentSlice
            otherRows -> expectationFailure ("unexpected adoption preview rows: " <> show otherRows)
          renderHuman result
            `shouldSatisfy` Text.isInfixOf "adoption changes only keiro-owned registration metadata"
          invocation
            `shouldBe` "'keiro-ops' 'rebuild' 'adopt' 'ops-group' '--force'"
        other -> expectationFailure ("expected adoption preview, got " <> show other)

      applied <- OpsRebuild.runCommand (opsEnv True store) operations command
      case applied of
        Succeeded result -> do
          result.headers `shouldBe` ["name", "kind", "outcome", "detail"]
          result.rows `shouldSatisfy` any (\row -> take 3 row == ["ops-group", "group", "live"])
          case result.jsonValue of
            Aeson.Object fields ->
              KeyMap.lookup "schema" fields
                `shouldBe` Just (Aeson.String "keiro/catalog-adoption-outcome/v2")
            value -> expectationFailure ("expected adoption outcome JSON object, got " <> show value)
        other -> expectationFailure ("expected adoption outcome, got " <> show other)
      registeredChanged <- expectStore store (Rebuild.registerProjectionCatalog changed)
      registeredChanged `shouldSatisfy` isRight
      begun <-
        expectStore
          store
          ( Rebuild.beginGroupRebuild
              changed
              opsGroupId
              Rebuild.RebuildRequest
                { rebuildRunId = opsRunId,
                  requestedBy = "keiro-ops-test",
                  requestReason = "prove adopted slice can rebuild",
                  replayFrom = GlobalPosition 0
                }
          )
      begun `shouldSatisfy` isRight

    it "annotates preview scope and warns about out-of-scope drift" $ \store -> do
      expectStore store $ runTransaction $ Tx.sql (ByteString.pack "CREATE SCHEMA app; CREATE TABLE app.ops_catalog (id bigint PRIMARY KEY); CREATE TABLE app.ops_catalog_b (id bigint PRIMARY KEY)")
      current <- expectValidatedCatalog (opsCatalogPair "ops-codec-a-v1" "ops-codec-b-v1")
      changed <- expectValidatedCatalog (opsCatalogPair "ops-codec-a-v2" "ops-codec-b-v2")
      registered <- expectStore store (Rebuild.registerProjectionCatalog current)
      registered `shouldSatisfy` isRight
      let operations = CatalogOperations.projectionCatalogOperations changed
          command = OpsRebuild.Adopt (OpsRebuild.AdoptOptions (NonEmpty.singleton opsGroupId))
      preview <- OpsRebuild.runCommand (opsEnv False store) operations command
      case preview of
        PreviewRequired result _ -> do
          result.headers `shouldBe` ["name", "kind", "state", "scope", "stored", "current"]
          result.rows `shouldSatisfy` any (\row -> take 4 row == ["ops-group", "group", "slice-changed", "adopt"])
          result.rows `shouldSatisfy` any (\row -> take 4 row == ["ops-group-b", "group", "slice-changed", "skip"])
          case result.jsonValue of
            Aeson.Object fields -> do
              KeyMap.lookup "schema" fields
                `shouldBe` Just (Aeson.String "keiro/catalog-adoption-preview/v2")
              KeyMap.lookup "outOfScopeChangedGroups" fields
                `shouldBe` Just (Aeson.toJSON (["ops-group-b"] :: [Text]))
            value -> expectationFailure ("expected adoption preview JSON object, got " <> show value)
          renderHuman result `shouldSatisfy` Text.isInfixOf "out-of-scope"
          renderHuman result `shouldSatisfy` Text.isInfixOf "ops-group-b"
        other -> expectationFailure ("expected scoped adoption preview, got " <> show other)

    it "refuses an adoption preview for a group absent from the catalog" $ \store -> do
      changed <- expectValidatedCatalog (opsCatalog "ops-codec-v2")
      let missingGroup = catalogIdentity Catalog.mkRebuildGroupId "ops-group-missing"
          operations = CatalogOperations.projectionCatalogOperations changed
          command = OpsRebuild.Adopt (OpsRebuild.AdoptOptions (NonEmpty.singleton missingGroup))
      preview <- OpsRebuild.runCommand (opsEnv False store) operations command
      case preview of
        Failed message -> message `shouldSatisfy` Text.isInfixOf "AdoptGroupNotInCatalog"
        other -> expectationFailure ("expected adoption preview refusal, got " <> show other)

    it "recovers a pre-canonical stranded run through preview and force" $ \store -> do
      expectStore store $ runTransaction $ Tx.sql (ByteString.pack "CREATE SCHEMA app; CREATE TABLE app.ops_catalog (id bigint PRIMARY KEY)")
      let strandedRun = opsRebuildRunId "ops-stranded-run"
          freshRun = opsRebuildRunId "ops-recovery-fresh"
          passingCatalog = opsCatalog "ops-codec-v1"
          failingHook =
            Catalog.RebuildVerification
              { verificationId = "ops-pre-canonical-verification",
                verificationVersion = "v1",
                verifyRebuild = pure (Left "fault injected by keiro-ops recovery spec")
              }
      healthy <- expectValidatedCatalog passingCatalog
      faulted <- expectValidatedCatalog (opsCatalogWithVerifications [failingHook] passingCatalog)
      _ <- expectStore store (Rebuild.registerProjectionCatalog faulted)
      initial <-
        expectStore
          store
          ( Rebuild.startCatalogRebuild
              faulted
              opsGroupId
              ( Rebuild.defaultRebuildOptions
                  Rebuild.RebuildRequest
                    { rebuildRunId = strandedRun,
                      requestedBy = "keiro-ops-test",
                      requestReason = "strand a pre-canonical run",
                      replayFrom = GlobalPosition 0
                    }
              )
          )
      initial `shouldSatisfy` \case
        Left Rebuild.CatalogRebuildVerificationFailed {} -> True
        _ -> False
      expectStore store $ runTransaction $ do
        Tx.sql
          "UPDATE keiro.keiro_projection_rebuild_runs SET group_slice_fingerprint = '$pre-canonical', contract_fingerprint = 'contract-v2:' || repeat('c', 64), runner_format = 'keiro/projection-replay/v2' WHERE run_id = 'ops-stranded-run'"
        Tx.sql
          "UPDATE keiro.keiro_projection_rebuild_groups SET slice_fingerprint = repeat('a', 64) WHERE group_id = 'ops-group'"

      let operations = CatalogOperations.projectionCatalogOperations healthy
          previewEnv =
            OpsEnv
              { store,
                outputMode = HumanTable,
                force = False,
                schemaDrift = [],
                allowSchemaDrift = False
              }
          forceEnv =
            OpsEnv
              { store,
                outputMode = HumanTable,
                force = True,
                schemaDrift = [],
                allowSchemaDrift = False
              }
          abandon =
            OpsRebuild.Abandon
              OpsRebuild.AbandonOptions
                { runId = strandedRun,
                  failureCode = "operator.pre-canonical",
                  failureDetail = "discard run stranded by migration 0024"
                }

      status <- OpsRebuild.runCommand previewEnv operations (OpsRebuild.Status strandedRun)
      case status of
        Succeeded result -> do
          result.headers
            `shouldBe` ["run", "group", "status", "group_slice", "captured_head", "sources", "adapters", "verifications"]
          result.rows `shouldSatisfy` \case
            [row] -> row !! 3 == "$pre-canonical"
            _ -> False
        other -> expectationFailure ("expected sentinel status, got " <> show other)

      renamedStatus <- OpsRebuild.runCommand previewEnv emptyCatalogOperations (OpsRebuild.Status strandedRun)
      renamedStatus `shouldSatisfy` isSucceeded

      abandonPreview <- OpsRebuild.runCommand previewEnv operations abandon
      case abandonPreview of
        PreviewRequired result invocation -> do
          result.rows `shouldSatisfy` \case
            [row] -> row !! 3 == "$pre-canonical"
            _ -> False
          invocation `shouldSatisfy` Text.isSuffixOf "'--force'"
        other -> expectationFailure ("expected abandon preview, got " <> show other)

      abandoned <- OpsRebuild.runCommand forceEnv operations abandon
      case abandoned of
        Succeeded result ->
          result.rows `shouldSatisfy` \case
            [row] -> row !! 2 == "RebuildRunFailed"
            _ -> False
        other -> expectationFailure ("expected forced abandon, got " <> show other)

      let adopt = OpsRebuild.Adopt (OpsRebuild.AdoptOptions (NonEmpty.singleton opsGroupId))
      adoptionPreview <- OpsRebuild.runCommand previewEnv operations adopt
      case adoptionPreview of
        PreviewRequired result _ ->
          result.rows `shouldSatisfy` \case
            row : _ -> row !! 1 == "group" && row !! 2 == "stale-format"
            _ -> False
        other -> expectationFailure ("expected adoption preview, got " <> show other)
      adopted <- OpsRebuild.runCommand forceEnv operations adopt
      case adopted of
        Succeeded result ->
          result.rows `shouldSatisfy` \case
            row : _ -> row !! 1 == "group" && row !! 2 == "failed" && Text.isPrefixOf "slice-v6:" (row !! 3)
            _ -> False
        other -> expectationFailure ("expected forced adoption, got " <> show other)

      promoted <-
        OpsRebuild.runCommand
          forceEnv
          operations
          ( OpsRebuild.Start
              OpsRebuild.StartOptions
                { groupId = opsGroupId,
                  runId = freshRun,
                  requestedBy = "keiro-ops-test",
                  reason = "fresh canonical recovery run",
                  replayFrom = GlobalPosition 0,
                  pageSize = 100
                }
          )
      case promoted of
        Succeeded result ->
          result.rows `shouldSatisfy` \case
            [row] -> row !! 2 == "RebuildRunPromoted"
            _ -> False
        other -> expectationFailure ("expected promoted fresh run, got " <> show other)

  describe "durable checkpoint inventory" do
    it "mounts both read-only commands in the standalone tree without a lag alias" do
      isParseSuccess (parseOps Ops.emptyAppHooks ["stream", "subscriptions"]) `shouldBe` True
      isParseSuccess (parseOps Ops.emptyAppHooks ["projection", "position", "--subscription", "orders"]) `shouldBe` True
      isParseFailure (parseOps Ops.emptyAppHooks ["projection", "lag", "--subscription", "orders"]) `shouldBe` True
      OpsStream.isMutation OpsStream.Subscriptions `shouldBe` False
      OpsProjection.isMutation (OpsProjection.Position "orders") `shouldBe` False

    around (withFreshStore fixture) do
      it "returns the captured store position with empty durable rows and null summaries" $ \store -> do
        streamOutcome <- OpsStream.runCommand (opsEnv False store) OpsStream.Subscriptions
        Succeeded streamResult <- pure streamOutcome
        streamResult.rows `shouldBe` []
        streamResult.jsonValue
          `shouldBe` object
            [ "store_position" .= (0 :: Int),
              "visible_store_head" .= (0 :: Int),
              "checkpoints" .= ([] :: [Aeson.Value])
            ]

        projectionOutcome <- OpsProjection.runCommand (opsEnv False store) (OpsProjection.Position "missing")
        Succeeded projectionResult <- pure projectionOutcome
        projectionResult.rows
          `shouldBe` [["missing", "", "", "", "0", "0", "", "", ""]]
        projectionResult.jsonValue
          `shouldBe` object
            [ "subscription" .= ("missing" :: Text),
              "store_position" .= (0 :: Int),
              "visible_store_head" .= (0 :: Int),
              "members" .= ([] :: [Aeson.Value]),
              "minimum_checkpoint_position" .= (Nothing :: Maybe Int64),
              "maximum_global_position_distance" .= (Nothing :: Maybe Int64)
            ]

      it "lists stopped-worker rows in name/member order and derives the member-aware floor" $ \store -> do
        seedCheckpointInventory store

        streamOutcome <- OpsStream.runCommand (opsEnv False store) OpsStream.Subscriptions
        Succeeded streamResult <- pure streamOutcome
        streamResult.rows
          `shouldBe` [ ["billing", "0", "4", "2026-08-09T14:02:00Z", "5", "5", "1"],
                       ["orders", "0", "2", "2026-08-09T14:00:00Z", "5", "5", "3"],
                       ["orders", "1", "3", "2026-08-09T14:01:00Z", "5", "5", "2"]
                     ]
        streamResult.jsonValue
          `shouldBe` object
            [ "store_position" .= (5 :: Int),
              "visible_store_head" .= (5 :: Int),
              "checkpoints"
                .= [ checkpointJsonFixture "billing" 0 4 "2026-08-09T14:02:00Z" 1,
                     checkpointJsonFixture "orders" 0 2 "2026-08-09T14:00:00Z" 3,
                     checkpointJsonFixture "orders" 1 3 "2026-08-09T14:01:00Z" 2
                   ]
            ]

        projectionOutcome <- OpsProjection.runCommand (opsEnv False store) (OpsProjection.Position "orders")
        Succeeded projectionResult <- pure projectionOutcome
        projectionResult.rows
          `shouldBe` [ ["orders", "0", "2", "2026-08-09T14:00:00Z", "5", "5", "3", "2", "3"],
                       ["orders", "1", "3", "2026-08-09T14:01:00Z", "5", "5", "2", "2", "3"]
                     ]
        projectionResult.jsonValue
          `shouldBe` object
            [ "subscription" .= ("orders" :: Text),
              "store_position" .= (5 :: Int),
              "visible_store_head" .= (5 :: Int),
              "members"
                .= [ checkpointJsonFixture "orders" 0 2 "2026-08-09T14:00:00Z" 3,
                     checkpointJsonFixture "orders" 1 3 "2026-08-09T14:01:00Z" 2
                   ],
              "minimum_checkpoint_position" .= (2 :: Int),
              "maximum_global_position_distance" .= (3 :: Int)
            ]

      it "diverges store_position from visible_store_head after a hard delete" $ \store -> do
        seedCheckpointInventory store
        Just _ <- expectStore store (hardDeleteStream (StreamName "checkpoint-inventory-5"))

        streamOutcome <- OpsStream.runCommand (opsEnv False store) OpsStream.Subscriptions
        Succeeded streamResult <- pure streamOutcome
        streamResult.rows
          `shouldBe` [ ["billing", "0", "4", "2026-08-09T14:02:00Z", "5", "4", "0"],
                       ["orders", "0", "2", "2026-08-09T14:00:00Z", "5", "4", "2"],
                       ["orders", "1", "3", "2026-08-09T14:01:00Z", "5", "4", "1"]
                     ]
        streamResult.jsonValue
          `shouldBe` object
            [ "store_position" .= (5 :: Int),
              "visible_store_head" .= (4 :: Int),
              "checkpoints"
                .= [ checkpointJsonFixture "billing" 0 4 "2026-08-09T14:02:00Z" 0,
                     checkpointJsonFixture "orders" 0 2 "2026-08-09T14:00:00Z" 2,
                     checkpointJsonFixture "orders" 1 3 "2026-08-09T14:01:00Z" 1
                   ]
            ]

        projectionOutcome <- OpsProjection.runCommand (opsEnv False store) (OpsProjection.Position "orders")
        Succeeded projectionResult <- pure projectionOutcome
        projectionResult.rows
          `shouldBe` [ ["orders", "0", "2", "2026-08-09T14:00:00Z", "5", "4", "2", "2", "2"],
                       ["orders", "1", "3", "2026-08-09T14:01:00Z", "5", "4", "1", "2", "2"]
                     ]
        projectionResult.jsonValue
          `shouldBe` object
            [ "subscription" .= ("orders" :: Text),
              "store_position" .= (5 :: Int),
              "visible_store_head" .= (4 :: Int),
              "members"
                .= [ checkpointJsonFixture "orders" 0 2 "2026-08-09T14:00:00Z" 2,
                     checkpointJsonFixture "orders" 1 3 "2026-08-09T14:01:00Z" 1
                   ],
              "minimum_checkpoint_position" .= (2 :: Int),
              "maximum_global_position_distance" .= (2 :: Int)
            ]

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
    it "rejects every non-finite spelling Read Double accepts" do
      parseDuration "NaN"
        `shouldBe` Left "invalid duration \"NaN\": expected a finite, non-negative number of seconds, optionally with an s, m, h, or d suffix"
      parseDuration "-NaN" `shouldSatisfy` isLeft
      parseDuration "Infinity" `shouldSatisfy` isLeft
      parseDuration "-Infinity" `shouldSatisfy` isLeft
      parseDuration "NaNs" `shouldSatisfy` isLeft
      parseDuration "NaNm" `shouldSatisfy` isLeft
      parseDuration "NaNh" `shouldSatisfy` isLeft
      parseDuration "NaNd" `shouldSatisfy` isLeft
      parseDuration "Infinityd" `shouldSatisfy` isLeft

    it "rejects finite durations the timestamptz wire encoding cannot represent" do
      parseDuration "1e13"
        `shouldBe` Left "invalid duration \"1e13\": exceeds the maximum supported duration of 9.0e12 seconds (about 285000 years)"
      parseDuration "1e308" `shouldSatisfy` isLeft
      parseDuration "1e308d" `shouldSatisfy` isLeft
      parseDuration "115740741000000d" `shouldSatisfy` isLeft

    it "still rejects lowercase non-finite spellings, negatives, and junk" do
      parseDuration "nan" `shouldSatisfy` isLeft
      parseDuration "infinity" `shouldSatisfy` isLeft
      parseDuration "-1" `shouldSatisfy` isLeft
      parseDuration "-1s" `shouldSatisfy` isLeft
      parseDuration "soon" `shouldSatisfy` isLeft
      parseDuration "" `shouldSatisfy` isLeft

    it "accepts integers, decimals, scientific notation, and suffixes unchanged" do
      parseDuration "0" `shouldBe` Right 0
      parseDuration "1.5" `shouldBe` Right 1.5
      parseDuration "2592000" `shouldBe` Right 2592000
      parseDuration "1e6" `shouldBe` Right 1000000
      parseDuration "2m" `shouldBe` Right 120
      parseDuration "3h" `shouldBe` Right 10800
      parseDuration "30d" `shouldBe` Right 2592000
      parseDuration "9.0e12" `shouldBe` Right 9000000000000

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

  describe "keiro-ops numeric argument rejection" do
    it "refuses a NaN duration before any preview or database contact" do
      executable <- keiroOpsExecutable
      (exit, _, errText) <-
        readProcessWithExitCode
          executable
          [ "--database-url",
            "postgresql://nobody@127.0.0.1:1/unreachable",
            "outbox",
            "gc-sent",
            "--older-than",
            "NaN"
          ]
          ""
      exit `shouldBe` ExitFailure 2
      errText `shouldSatisfy` Text.isInfixOf "invalid duration \"NaN\"" . Text.pack
      errText `shouldSatisfy` not . Text.isInfixOf "preview only" . Text.pack
      errText `shouldSatisfy` not . Text.isInfixOf "schema verification" . Text.pack

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
    it "previews and runs one bounded application-registry resume pass" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-resume"
          registry = Map.singleton (WorkflowName "approval") (WorkflowDef (\_ -> pure ("done" :: Text)))
          hook = Just (registry, defaultWorkflowResumeOptions)
          command = OpsWorkflow.ResumeOnce (OpsWorkflow.ResumeOptions 1)
      seedStep store ref "received" Aeson.Null

      preview <- OpsWorkflow.runCommandWithResume hook (opsEnv False store) command
      preview `shouldSatisfy` isPreview
      workflowStatus store ref `shouldReturn` Just Instance.WfRunning

      applied <- OpsWorkflow.runCommandWithResume hook (opsEnv True store) command
      applied `shouldSatisfy` isSucceeded
      jsonInteger "completed" applied `shouldBe` Just 1
      jsonInteger "advanced" applied `shouldBe` Just 1
      jsonStringArray "unregistered_names" applied `shouldBe` Just []
      workflowStatus store ref `shouldReturn` Just Instance.WfCompleted

    it "reports advanced work and the exact unregistered workflow names" $ \store -> do
      let registered = OpsWorkflow.WorkflowRef "approval" "wf-resume-registered"
          unregistered = OpsWorkflow.WorkflowRef "retired-approval" "wf-resume-unregistered"
          registry = Map.singleton (WorkflowName "approval") (WorkflowDef (\_ -> pure ("done" :: Text)))
          hook = Just (registry, defaultWorkflowResumeOptions)
          command = OpsWorkflow.ResumeOnce (OpsWorkflow.ResumeOptions 2)
      seedStep store registered "received" Aeson.Null
      seedStep store unregistered "received" Aeson.Null

      applied <- OpsWorkflow.runCommandWithResume hook (opsEnv True store) command
      applied `shouldSatisfy` isSucceeded
      jsonInteger "discovered" applied `shouldBe` Just 2
      jsonInteger "advanced" applied `shouldBe` Just 1
      jsonInteger "unknown_name" applied `shouldBe` Just 1
      jsonStringArray "unregistered_names" applied `shouldBe` Just ["retired-approval"]
      workflowStatus store registered `shouldReturn` Just Instance.WfCompleted
      workflowStatus store unregistered `shouldReturn` Just Instance.WfRunning

    it "classifies a due sleep with no timer worker as blocked, not advanced" $ \store -> do
      let ref = OpsWorkflow.WorkflowRef "approval" "wf-resume-due-sleep"
          registry =
            Map.singleton
              (WorkflowName "approval")
              (WorkflowDef (\_ -> sleepNamed (StepName "wait") (-1) *> pure ("done" :: Text)))
          hook = Just (registry, defaultWorkflowResumeOptions)
          command = OpsWorkflow.ResumeOnce (OpsWorkflow.ResumeOptions 1)
      seedStep store ref "received" Aeson.Null

      first <- OpsWorkflow.runCommandWithResume hook (opsEnv True store) command
      first `shouldSatisfy` isSucceeded
      jsonInteger "discovered" first `shouldBe` Just 1
      jsonInteger "advanced" first `shouldBe` Just 0
      jsonInteger "still_suspended" first `shouldBe` Just 1
      jsonInteger "sleep_due" first `shouldBe` Just 1
      humanField "sleep_due" first `shouldBe` Just "1"

      second <- OpsWorkflow.runCommandWithResume hook (opsEnv True store) command
      second `shouldSatisfy` isSucceeded
      jsonInteger "discovered" second `shouldBe` Just 1
      jsonInteger "advanced" second `shouldBe` Just 0
      jsonInteger "still_suspended" second `shouldBe` Just 1
      jsonInteger "sleep_due" second `shouldBe` Just 1
      humanField "sleep_due" second `shouldBe` Just "1"

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
      claimed `shouldBe` Instance.ClaimAcquired

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
    it "previews and dispatches one bounded due-timer pass through the mounted hook" $ \store -> do
      now <- getCurrentTime
      let request = timerRequest "018f5f43-8a70-7b9a-9a9b-59d391a76722" (addUTCTime (-60) now)
          fire _ = pure (Just (EventId (testUuid "018f5f43-8a70-7b9a-9a9b-59d391a76723")))
          command = OpsTimer.DrainOnce (OpsTimer.DrainOptions 1)
      expectStore store (runTransaction (Timer.scheduleTimerTx request))

      preview <- OpsTimer.runCommandWithFire (Just fire) (opsEnv False store) command
      preview `shouldSatisfy` isPreview
      timerStatus store request.timerId `shouldReturn` Just Timer.Scheduled

      applied <- OpsTimer.runCommandWithFire (Just fire) (opsEnv True store) command
      applied `shouldSatisfy` isSucceeded
      jsonInteger "processed" applied `shouldBe` Just 1
      timerStatus store request.timerId `shouldReturn` Just Timer.Fired

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

    it "filters and renders rejected rows with bounded audit fields" $ \store -> do
      now <- getCurrentTime
      let outboxId = testOutboxId "018f5f43-8a70-7b9a-9a9b-59d391a76811"
          event = sampleIntegrationEvent now "outbox-rejected-message"
      rejection <-
        either (fail . show) pure $
          Outbox.mkPublishRejection "authorization.denied" (Just "the sink policy refused this message")
      expectStore store (runTransaction (Outbox.enqueueOutboxTx (Outbox.OutboxMessage outboxId event)))
      summary <-
        expectStore store $
          Outbox.publishClaimedOutbox
            (\rows -> pure [(row.outboxId, Outbox.PublishRejected rejection) | row <- rows])
            Outbox.defaultPublishOptions
            Nothing
      summary.rejected `shouldBe` 1

      listed <-
        OpsOutbox.runCommand
          (opsEnv False store)
          ( OpsOutbox.List
              OpsOutbox.ListOptions
                { source = "ops-source",
                  status = Just Outbox.OutboxRejected,
                  destination = Nothing,
                  limit = 10
                }
          )
      humanField "status" listed `shouldBe` Just "rejected"
      humanField "rejection_code" listed `shouldBe` Just "authorization.denied"
      humanField "rejection_detail" listed `shouldBe` Just "the sink policy refused this message"
      humanField "rejected_at" listed `shouldSatisfy` maybe False (not . Text.null)
      case listed of
        Succeeded OpsResult {jsonValue = Aeson.Array values} ->
          case values Vector.!? 0 of
            Just (Aeson.Object row) -> do
              KeyMap.lookup "status" row `shouldBe` Just (Aeson.String "rejected")
              KeyMap.lookup "rejection_code" row `shouldBe` Just (Aeson.String "authorization.denied")
              KeyMap.lookup "rejection_detail" row `shouldBe` Just (Aeson.String "the sink policy refused this message")
              KeyMap.lookup "rejected_at" row `shouldSatisfy` maybe False (/= Aeson.Null)
            other -> expectationFailure ("expected one rejected JSON object, got " <> show other)
        other -> expectationFailure ("expected a successful rejected-row listing, got " <> show other)

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

seedCheckpointInventory :: KirokuStore -> IO ()
seedCheckpointInventory store = do
  let seeds =
        [ ("checkpoint-inventory-1", "018f5f43-8a70-7b9a-9a9b-59d391a76821"),
          ("checkpoint-inventory-2", "018f5f43-8a70-7b9a-9a9b-59d391a76822"),
          ("checkpoint-inventory-3", "018f5f43-8a70-7b9a-9a9b-59d391a76823"),
          ("checkpoint-inventory-4", "018f5f43-8a70-7b9a-9a9b-59d391a76824"),
          ("checkpoint-inventory-5", "018f5f43-8a70-7b9a-9a9b-59d391a76825")
        ]
  mapM_ (\(name, eventId) -> seedKirokuEvent store name eventId Nothing) seeds
  expectStore store $
    runTransaction $
      Tx.sql
        "INSERT INTO subscriptions (subscription_name, stream_name, consumer_group_member, consumer_group_size, last_seen, updated_at) VALUES ('orders', '$all', 1, 2, 3, '2026-08-09 14:01:00+00'), ('billing', '$all', 0, 1, 4, '2026-08-09 14:02:00+00'), ('orders', '$all', 0, 2, 2, '2026-08-09 14:00:00+00')"

checkpointJsonFixture :: Text -> Int -> Int -> Text -> Int -> Aeson.Value
checkpointJsonFixture subscription member position updatedAt distance =
  object
    [ "subscription" .= subscription,
      "member" .= member,
      "checkpoint_position" .= position,
      "checkpoint_updated_at" .= updatedAt,
      "global_position_distance" .= distance
    ]

eventUuid :: SeededEvent -> UUID.UUID
eventUuid seeded = case seeded.eventId of EventId value -> value

streamDeleted :: KirokuStore -> Text -> IO (Maybe Bool)
streamDeleted store name =
  expectStore store (getStream (StreamName name)) <&> fmap (isJust . (.deletedAt))

streamTruncateBefore :: KirokuStore -> Text -> IO (Maybe StreamVersion)
streamTruncateBefore store name =
  expectStore store (getStream (StreamName name)) <&> fmap (.truncateBefore)

data OpsCatalogEvent

opsCatalog :: Text -> Catalog.ProjectionCatalog
opsCatalog codecFingerprint =
  Catalog.ProjectionCatalog
    { sources =
        [ Catalog.SourceDeclaration
            { sourceId = opsSourceId,
              sourceScope = Catalog.CategorySource (CategoryName "ops-catalog"),
              codecFingerprint,
              claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:source"
            }
        ],
      targets =
        [ Catalog.TargetDeclaration
            { targetId = opsTargetId,
              qualifiedTable = Catalog.QualifiedTable "app" "ops_catalog",
              resetPolicy = Catalog.ClearBeforeReplay,
              dependsOn = [],
              claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:target"
            }
        ],
      rebuildGroups =
        [ Catalog.RebuildGroupDeclaration
            { rebuildGroupId = opsGroupId,
              orderedTargets = [opsTargetId],
              verificationHooks = [],
              claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:group"
            }
        ],
      projectionRevisions = [],
      externalReadContracts = [],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [],
      projectionSets = [Catalog.SomeProjectionSet opsProjectionSet]
    }

opsCatalogPair :: Text -> Text -> Catalog.ProjectionCatalog
opsCatalogPair firstCodec secondCodec =
  let first = opsCatalog firstCodec
   in first
        { Catalog.sources =
            first.sources
              <> [ Catalog.SourceDeclaration
                     { sourceId = opsSourceBId,
                       sourceScope = Catalog.CategorySource (CategoryName "ops-catalog-b"),
                       codecFingerprint = secondCodec,
                       claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:source-b"
                     }
                 ],
          Catalog.targets =
            first.targets
              <> [ Catalog.TargetDeclaration
                     { targetId = opsTargetBId,
                       qualifiedTable = Catalog.QualifiedTable "app" "ops_catalog_b",
                       resetPolicy = Catalog.ClearBeforeReplay,
                       dependsOn = [],
                       claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:target-b"
                     }
                 ],
          Catalog.rebuildGroups =
            first.rebuildGroups
              <> [ Catalog.RebuildGroupDeclaration
                     { rebuildGroupId = opsGroupBId,
                       orderedTargets = [opsTargetBId],
                       verificationHooks = [],
                       claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:group-b"
                     }
                 ],
          Catalog.projectionSets = first.projectionSets <> [Catalog.SomeProjectionSet opsProjectionSetB]
        }

opsCatalogWithVerifications :: [Catalog.RebuildVerification] -> Catalog.ProjectionCatalog -> Catalog.ProjectionCatalog
opsCatalogWithVerifications verifications catalog =
  catalog
    { Catalog.rebuildGroups =
        [ group {Catalog.verificationHooks = verifications}
        | group <- catalog.rebuildGroups
        ]
    }

opsProjectionSet :: Catalog.ProjectionSet OpsCatalogEvent
opsProjectionSet =
  Catalog.ProjectionSet
    { projectionSource = opsSourceId,
      projectionDefinitions = NonEmpty.singleton opsProjectionDefinition,
      claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:set"
    }

opsProjectionDefinition :: Catalog.ProjectionDefinition OpsCatalogEvent
opsProjectionDefinition =
  Catalog.ProjectionDefinition
    { projectionId = catalogIdentity Catalog.mkProjectionId "ops-owner",
      rebuildGroup = opsGroupId,
      ownedTargets = NonEmpty.singleton opsTargetId,
      replayPolicy =
        Catalog.Replayable
          Catalog.ReplayAdapter
            { decodeForReplay = const Catalog.ReplayIrrelevant,
              applyForReplay = \_ _ -> pure ()
            },
      handlers =
        NonEmpty.singleton
          ( Catalog.InlineHandler
              Projection.InlineProjection
                { name = "ops-inline",
                  apply = \_ _ -> pure ()
                }
              (catalogIdentity Catalog.mkClaimSite "ops-test:inline-handler")
          ),
      claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:projection"
    }

opsProjectionSetB :: Catalog.ProjectionSet OpsCatalogEvent
opsProjectionSetB =
  Catalog.ProjectionSet
    { projectionSource = opsSourceBId,
      projectionDefinitions = NonEmpty.singleton opsProjectionDefinitionB,
      claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:set-b"
    }

opsProjectionDefinitionB :: Catalog.ProjectionDefinition OpsCatalogEvent
opsProjectionDefinitionB =
  Catalog.ProjectionDefinition
    { projectionId = catalogIdentity Catalog.mkProjectionId "ops-owner-b",
      rebuildGroup = opsGroupBId,
      ownedTargets = NonEmpty.singleton opsTargetBId,
      replayPolicy =
        Catalog.Replayable
          Catalog.ReplayAdapter
            { decodeForReplay = const Catalog.ReplayIrrelevant,
              applyForReplay = \_ _ -> pure ()
            },
      handlers =
        NonEmpty.singleton
          ( Catalog.InlineHandler
              Projection.InlineProjection
                { name = "ops-inline-b",
                  apply = \_ _ -> pure ()
                }
              (catalogIdentity Catalog.mkClaimSite "ops-test:inline-handler-b")
          ),
      claimSite = catalogIdentity Catalog.mkClaimSite "ops-test:projection-b"
    }

opsGroupId :: Catalog.RebuildGroupId
opsGroupId = catalogIdentity Catalog.mkRebuildGroupId "ops-group"

opsSourceId :: Catalog.SourceId
opsSourceId = catalogIdentity Catalog.mkSourceId "ops-source"

opsTargetId :: Catalog.TargetId
opsTargetId = catalogIdentity Catalog.mkTargetId "ops-target"

opsGroupBId :: Catalog.RebuildGroupId
opsGroupBId = catalogIdentity Catalog.mkRebuildGroupId "ops-group-b"

opsSourceBId :: Catalog.SourceId
opsSourceBId = catalogIdentity Catalog.mkSourceId "ops-source-b"

opsTargetBId :: Catalog.TargetId
opsTargetBId = catalogIdentity Catalog.mkTargetId "ops-target-b"

opsRunId :: Rebuild.RebuildRunId
opsRunId =
  opsRebuildRunId "ops-adoption-run"

opsRebuildRunId :: Text -> Rebuild.RebuildRunId
opsRebuildRunId identity =
  case Rebuild.mkRebuildRunId identity of
    Left err -> error (Text.unpack err)
    Right value -> value

catalogIdentity :: (Show err) => (Text -> Either err value) -> Text -> value
catalogIdentity constructor value =
  case constructor value of
    Left err -> error (show err)
    Right identity -> identity

expectValidatedCatalog :: Catalog.ProjectionCatalog -> IO Catalog.ValidatedProjectionCatalog
expectValidatedCatalog catalog =
  case Catalog.validateProjectionCatalog catalog of
    Catalog.Failure diagnostics -> expectationFailure (show diagnostics) >> error "unreachable"
    Catalog.Success validated -> pure validated

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

humanField :: Text -> OpsOutcome -> Maybe Text
humanField key = \case
  Succeeded OpsResult {headers, rows = [row]} -> lookup key (zip headers row)
  _ -> Nothing

jsonStringArray :: Key -> OpsOutcome -> Maybe [Text]
jsonStringArray key = \case
  Succeeded OpsResult {jsonValue = Aeson.Object value} -> do
    Aeson.Array values <- KeyMap.lookup key value
    traverse
      ( \case
          Aeson.String item -> Just item
          _ -> Nothing
      )
      (Vector.toList values)
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
