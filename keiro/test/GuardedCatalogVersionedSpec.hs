{-# LANGUAGE BlockArguments #-}

module GuardedCatalogVersionedSpec (spec) where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar
import Control.Exception (finally)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (secondsToDiffTime)
import GuardedCatalogExample qualified as Example
import GuardedCatalogSpec (awaitWorker, checked, script, waitSql, withController)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import Kiroku.Store.HistoryRetention
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = describe "guarded catalog commands serving revisions" $ do
  for_ ["v1", "v2"] \candidateVersion -> do
    it ("protects a writer before promotion to " <> Text.unpack candidateVersion) $
      withFreshResourceStoresSameDatabaseWithConnection fixture \connection ((_, writer), (_, promoter)) ->
        withController connection \controller -> do
          (catalog, request) <- setupVersioned writer candidateVersion
          -- Catch up without fencing the currently writable serving revision.
          _ <- checked writer (beginVersionedRebuild catalog request) >>= right
          _ <- driveToWritableReady writer catalog (request ^. #rebuildRunId)
          script controller "SELECT pg_advisory_lock(306)"
          done <- newEmptyMVar
          let note = Example.exampleNote "protected" "shared"
              guard context = do
                Tx.sql "SET LOCAL application_name = 'keiro-306-versioned-writer'; SELECT pg_advisory_xact_lock(306)"
                versionedGuard "v1" note context
          worker <- forkFinally (runGuarded writer catalog note guard) (putMVar done)
          flip finally (script controller "SELECT pg_advisory_unlock_all()" >> killThread worker) do
            waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name = 'keiro-306-versioned-writer' AND wait_event_type = 'Lock')"
            promotedDone <- newEmptyMVar
            promotion <- forkFinally (driveToPromoted promoter catalog (request ^. #rebuildRunId)) (putMVar promotedDone)
            flip finally (killThread promotion) do
              waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_stat_activity blocked, pg_stat_activity holder WHERE holder.application_name = 'keiro-306-versioned-writer' AND holder.pid = ANY(pg_blocking_pids(blocked.pid)))"
              script controller "SELECT pg_advisory_unlock(306)"
              awaitWorker done >>= (`shouldSatisfy` isAccepted)
              _ <- awaitWorker promotedDone
              runGuarded writer catalog (note {Example.noteId = "later"}) (versionedGuard candidateVersion note)
                `shouldReturn` Right (PreconditionRefused (Example.ExistingNote "protected"))

    it ("admits a writer coherently after waiting for promotion to " <> Text.unpack candidateVersion) $
      withFreshResourceStoresSameDatabaseWithConnection fixture \connection ((_, writer), (_, promoter)) ->
        withController connection \controller -> do
          (catalog, request) <- setupVersioned writer candidateVersion
          _ <- checked writer (beginVersionedRebuild catalog request) >>= right
          _ <- driveToReady writer catalog (request ^. #rebuildRunId)
          prepared <- checked writer (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= right
          prepared ^. #promotionPrepared `shouldBe` True
          -- Hold a real target lock on the third connection. Promotion takes
          -- its group lock first, then waits for the target; the writer's
          -- admission statement must cross the committed metadata transition.
          script controller "BEGIN; LOCK TABLE app.state_note_identity IN ACCESS SHARE MODE"
          promotionDone <- newEmptyMVar
          promotion <- forkFinally (checked promoter (resumeVersionedRebuild catalog (request ^. #rebuildRunId)) >>= right) (putMVar promotionDone)
          flip finally (script controller "ROLLBACK" >> killThread promotion) do
            waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE relation = 'app.state_note_identity'::regclass AND mode = 'AccessExclusiveLock' AND NOT granted)"
            writerDone <- newEmptyMVar
            let note = Example.exampleNote "late" "shared"
            worker <- forkFinally (runGuarded writer catalog note (versionedGuard candidateVersion note)) (putMVar writerDone)
            flip finally (killThread worker) do
              waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_stat_activity blocked, pg_locks holder WHERE holder.relation = 'app.state_note_identity'::regclass AND holder.mode = 'AccessExclusiveLock' AND NOT holder.granted AND holder.pid = ANY(pg_blocking_pids(blocked.pid)))"
              script controller "COMMIT"
              report <- awaitWorker promotionDone
              report ^. #phase `shouldBe` VersionedPromoted
              result <- awaitWorker writerDone
              result `shouldSatisfy` \case
                Right (CatalogCommandOutcome (DomainProjectionCommandApplied _)) -> True
                Right (CatalogCommandOutcome DomainProjectionCommandServingBindingInvalid {}) -> True
                Right (CatalogCommandOutcome DomainProjectionCommandServingRevisionUnavailable {}) -> True
                _ -> False
              -- A fresh statement after promotion must resolve the new binding.
              final <- runGuarded writer catalog note (versionedGuard candidateVersion note)
              final `shouldSatisfy` \case
                Right (PreconditionRefused (Example.ExistingNote "late")) -> True
                value -> isAccepted value

  around (withFreshResourceStore fixture) $ do
    it "refuses an unknown serving revision before invoking the guard" \(_, runner) -> do
      (catalog, request) <- setupVersioned runner "v2"
      _ <- checked runner (beginVersionedRebuild catalog request) >>= right
      let oldOnly = fromDefinition (versionedDefinition [revision "v2"])
          note = Example.exampleNote "unknown" "shared"
      result <- runGuarded runner oldOnly note (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right ()))
      result `shouldBe` Right (CatalogCommandOutcome (DomainProjectionCommandServingRevisionUnavailable Example.identityGroup (revisionIdFor "v1")))

    it "refuses an incomplete serving generation map before invoking the guard" \(_, runner) -> do
      (catalog, request) <- setupVersioned runner "v2"
      _ <- checked runner (beginVersionedRebuild catalog request) >>= right
      checked runner (Store.runTransaction (Tx.sql "UPDATE keiro.keiro_projection_target_generations SET lifecycle = 'retired', retired_at = now() WHERE lifecycle = 'serving'"))
      let note = Example.exampleNote "invalid" "shared"
      result <- runGuarded runner catalog note (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right ()))
      result `shouldSatisfy` \case Right (CatalogCommandOutcome DomainProjectionCommandServingBindingInvalid {}) -> True; _ -> False

type Outcome = Either CommandError (GuardedCatalogOutcome Example.NoteStream Example.NoteEvent Text Text Example.NoteRefusal)

runGuarded :: StoreRunner -> ValidatedProjectionCatalog -> Example.Note -> (CatalogPreconditionContext -> Tx.Transaction (Either Example.NoteRefusal ())) -> IO Outcome
runGuarded runner catalog note guard = checked runner (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (Example.handler 1) (stream (Example.noteId note)) (Example.CreateNote (Example.notePayload note)) catalog Example.commandSet guard)

isAccepted :: Outcome -> Bool
isAccepted = \case Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}})) -> True; _ -> False

versionedGuard :: Text -> Example.Note -> CatalogPreconditionContext -> Tx.Transaction (Either Example.NoteRefusal ())
versionedGuard expected note context = case catalogPreconditionBindings context of
  [binding] | binding ^. #writeRevisionId == Just (revisionIdFor expected) -> case resolvePhysicalTarget Example.identityTarget (binding ^. #writePhysicalTargets) of
    Just table -> do
      -- SQL for v2 actually requires its additional column. A stale serving
      -- revision or retired/candidate table cannot silently pass this check.
      when (expected == "v2") (Tx.sql (Encoding.encodeUtf8 ("SELECT v2_marker FROM " <> qualified table <> " LIMIT 1")))
      winner <- Tx.statement (Example.notePayload note) (Example.identityLookup table)
      pure (maybe (Right ()) (Left . Example.ExistingNote) winner)
    Nothing -> pure (Left (Example.GuardConfigurationFault "target absent"))
  _ -> pure (Left (Example.GuardConfigurationFault "wrong serving revision"))

setupVersioned :: StoreRunner -> Text -> IO (ValidatedProjectionCatalog, VersionedRebuildRequest)
setupVersioned runner candidate = do
  checked runner (Store.runTransaction (Tx.sql (Encoding.encodeUtf8 Example.setupSql)))
  let catalog = fromDefinition (versionedDefinition [revision "v1", revision "v2"])
  _ <- checked runner (registerProjectionCatalog catalog) >>= right
  let targets = either (error . show) id (mkPhysicalTargets [Example.identityTarget] (Map.singleton Example.identityTarget Example.identityTable))
      runId = Example.ident mkRebuildRunId "guarded-versioned-run"
      request =
        VersionedRebuildRequest
          runId
          Example.identityGroup
          (revisionIdFor "v1")
          (revisionIdFor candidate)
          targets
          ApplicationProvisioned
          100
          100
          5000
          1000000
          (HistoryRetentionLeaseRequest (Example.ident mkHistoryRetentionLeaseOwner "guarded-versioned-test") (Example.ident mkHistoryRetentionLeaseReason "guarded serving generation proof") (either (error . show) id (mkHistoryRetentionLeaseDuration (secondsToDiffTime 600))))
          "guarded-spec"
          "serving guard proof"
  pure (catalog, request)

versionedDefinition :: [ProjectionRevision] -> ProjectionCatalog
versionedDefinition revisions = Example.catalogDefinition {projectionRevisions = revisions}

fromDefinition :: ProjectionCatalog -> ValidatedProjectionCatalog
fromDefinition definition = case validateProjectionCatalog definition of Success value -> value; Failure diagnostics -> error (show diagnostics)

revisionIdFor :: Text -> ProjectionRevisionId
revisionIdFor version = Example.ident mkProjectionRevisionId ("note-" <> version)

revision :: Text -> ProjectionRevision
revision version =
  ProjectionRevision
    (revisionIdFor version)
    Example.identityGroup
    (Map.singleton Example.identityTarget provisioner)
    [RevisionLiveHandler ("note-live-" <> version) 1 (RevisionInlineDelivery Example.identityOwner "note-identity") [Example.identityTarget] applyRecorded]
    [RevisionReplayAdapter ("note-replay-" <> version) 1 [Example.identityTarget] (\targets recorded -> applyRecorded targets recorded >> pure (Right True))]
    []
    []
    Example.site
  where
    provisioner =
      TargetProvisioner
        ("note-provision-" <> version)
        1
        (TargetSchemaVersion version)
        ("note-shape-" <> version)
        ( \context -> do
            Tx.sql (Encoding.encodeUtf8 ("CREATE TABLE " <> qualified (context ^. #stagingTable) <> " (LIKE " <> qualified (context ^. #servingTable) <> " INCLUDING ALL)"))
            when (version == "v2") (Tx.sql (Encoding.encodeUtf8 ("ALTER TABLE " <> qualified (context ^. #stagingTable) <> " ADD COLUMN v2_marker text")))
        )
        ("note-validator-" <> version)
        1
        (Just validate)
        []
    validate context = do
      let table = context ^. #stagingTable
      oid <- Tx.statement () (preparable ("SELECT '" <> table ^. #schemaName <> "." <> table ^. #tableName <> "'::regclass::oid::bigint") E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
      pure (Right (TargetSchemaEvidence oid ("note-shape-" <> version) [] ("note-columns-" <> version)))
    applyRecorded targets recorded = case Example.decodeNoteRecorded recorded of
      ReplayRelevant (Example.NoteCreated payload) -> case resolvePhysicalTarget Example.identityTarget targets of
        Just table ->
          Tx.statement
            payload
            ( preparable
                ("INSERT INTO " <> qualified table <> "(anchor_type, anchor_id, property_id, state_id, note_id) SELECT $1::jsonb->>'anchorType',$1::jsonb->>'anchorId',$1::jsonb->>'propertyId',$1::jsonb->>'stateId',$1::jsonb->>'noteId'")
                Example.textParam
                D.noResult
            )
        Nothing -> error "validated target disappeared"
      _ -> pure ()

qualified :: QualifiedTable -> Text
qualified table = qualifyTable (table ^. #schemaName) (table ^. #tableName)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

driveToReady runner catalog runId = go (20 :: Int)
  where
    go 0 = fail "cutover did not become ready"
    go n = do
      report <- checked runner (resumeVersionedRebuild catalog runId) >>= right
      if report ^. #phase == VersionedCutoverReplaying && all (\source -> source ^. #exhaustedThrough == Just (source ^. #targetPosition)) (report ^. #sources) then pure report else go (n - 1)

driveToPromoted runner catalog runId = go (20 :: Int)
  where
    go 0 = fail "promotion did not finish"
    go n = do
      report <- checked runner (resumeVersionedRebuild catalog runId) >>= right
      if report ^. #phase == VersionedPromoted then pure report else go (n - 1)

driveToWritableReady runner catalog runId = go (20 :: Int)
  where
    go 0 = fail "ordinary replay did not finish"
    go n = do
      report <- checked runner (resumeVersionedRebuild catalog runId) >>= right
      if report ^. #phase == VersionedReplayRunning && all (\source -> source ^. #exhaustedThrough == Just (source ^. #targetPosition)) (report ^. #sources) then pure report else go (n - 1)
