{-# LANGUAGE BlockArguments #-}

module GuardedCatalogSpec (spec, checked, withController, script, waitSql, awaitWorker) where

import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (bracket, finally)
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GuardedCatalogExample qualified as Example
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Keiki.Core qualified as Keiki
import Keiro
import Keiro.Prelude
import Keiro.Projection
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild qualified
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (..))
import Kiroku.Store.Types (GlobalPosition (..), StreamName (..), StreamVersion (..))
import System.Timeout (timeout)
import Test.Hspec hiding (parallel)
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = describe "guarded catalog commands" $ do
  for_ [("fresh refusal", 3), ("exhaustion", 0)] \(label, budget) ->
    it ("discards an OCC-conflicting decision before " <> label) $
      withFreshResourceStoresSameDatabase fixture \((_, retrying), (_, winner)) ->
        occScenario retrying winner (Example.handler 1) budget (if budget == 0 then "exhausted" else "reuse")
  it "returns a silent decision after OCC retry without invoking a guard" $
    withFreshResourceStoresSameDatabase fixture \((_, retrying), (_, winner)) ->
      occScenario retrying winner onceHandler 3 "noop"
  it "opens distinct backends in the same database and schema" $
    withFreshResourceStoresSameDatabase fixture \((_, StoreRunner first), (_, StoreRunner second)) -> do
      let facts =
            Store.runTransaction $
              Tx.statement () $
                preparable
                  "SELECT pg_backend_pid(), current_database()::text, current_schema()::text FROM pg_sleep(0.1)"
                  E.noParams
                  (D.singleRow ((,,) <$> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))
      results <- parallel (first facts) (second facts)
      case results of
        (Right (pidA, dbA, schemaA), Right (pidB, dbB, schemaB)) -> do
          pidA `shouldNotBe` pidB
          dbA `shouldBe` dbB
          schemaA `shouldBe` schemaB
        other -> expectationFailure (show other)

  around (withFreshResourceStore fixture) $ do
    it "preserves encode failures before callback or append" \(_, runner) -> do
      Example.setup runner
      let options = defaultRunCommandOptions & #metadata ?~ Aeson.Null
      result <- checked runner (runDomainCommandWithCatalogProjectionsGuarded options (Example.handler 1) (stream "encode-failure") (Example.CreateNote (Example.notePayload (Example.exampleNote "encode-failure" "shared"))) Example.catalog Example.commandSet (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right () :: Either Example.NoteRefusal ())))
      result `shouldBe` Left (EncodeFailed (NonObjectCallerMetadata Aeson.Null))
      counts runner `shouldReturn` (0, 0, 0, 0)

    it "reuses canonical identity keys without replacing the original payload" \(_, runner) -> do
      Example.setup runner
      let first = (Example.exampleNote "winner" " shared ") {Example.anchorType = " Intention ", Example.propertyId = " status ", Example.stateId = " ready "}
          second = Example.exampleNote "duplicate" "shared"
      Example.ensureStateNoteExample runner first `shouldReturn` Right ("winner", True)
      Example.ensureStateNoteExample runner second `shouldReturn` Right ("winner", False)
      counts runner `shouldReturn` (1, 1, 0, 0)

    it "does not advance a snapshot or fixture effects on refusal" \(_, runner) -> do
      Example.setup runner
      checked runner (Store.runTransaction (Tx.sql "CREATE TABLE app.fixture_outbox(note_id text); CREATE TABLE app.fixture_reactors(note_id text)"))
      let raw = unvalidated (Example.validated 1)
          codec :: StateCodec (Example.NoteState, Keiki.RegFile '[])
          codec = StateCodec 1 "guarded-ready" "guarded-ready" (const Aeson.Null) (const (Right (Example.Ready, Keiki.RNil)))
          validated = either (error . show) id (mkEventStream "guarded-snapshot" raw {snapshotPolicy = Every 1, stateCodec = Just codec})
          handler = (Example.handler 1) {eventStream = validated}
          note = Example.exampleNote "snapshot-refusal" "shared"
      result <-
        checked
          runner
          ( runDomainCommandWithCatalogProjectionsGuarded
              defaultRunCommandOptions
              handler
              (stream "snapshot-refusal")
              (Example.CreateNote (Example.notePayload note))
              Example.catalog
              Example.commandSet
              ( \_ -> do
                  Tx.sql "INSERT INTO app.fixture_outbox VALUES ('snapshot-refusal'); INSERT INTO app.fixture_reactors VALUES ('snapshot-refusal')"
                  pure (Left (Example.ExistingNote "winner"))
              )
          )
      result `shouldBe` Right (PreconditionRefused (Example.ExistingNote "winner"))
      checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT (SELECT count(*) FROM keiro.keiro_snapshots), (SELECT count(*) FROM app.fixture_outbox), (SELECT count(*) FROM app.fixture_reactors)" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))))) `shouldReturn` (0, 0, 0)
      counts runner `shouldReturn` (0, 0, 0, 0)
      let acceptedNote = note {Example.noteId = "snapshot-accepted"}
      acceptedResult <- checked runner (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions handler (stream "snapshot-accepted") (Example.CreateNote (Example.notePayload acceptedNote)) Example.catalog Example.commandSet (\_ -> pure (Right () :: Either Example.NoteRefusal ())))
      acceptedResult `shouldSatisfy` accepted
      checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT count(*) FROM keiro.keiro_snapshots" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))))) `shouldReturn` 1

    it "rebuilds both catalog owners without invoking the command guard" \(_, runner) -> do
      Example.setup runner
      checked runner (Store.initializeSubscriptionCheckpoint (Store.SubscriptionName "note-rich-worker") 0 FromBeginning) >>= (`shouldSatisfy` either (const False) (const True))
      let note = Example.exampleNote "winner" "shared"
      Example.ensureStateNoteExample runner note `shouldReturn` Right ("winner", True)
      for_ [(Example.identityGroup, "identity-rebuild"), (Example.richGroup, "rich-rebuild")] \(group, runName) -> do
        let runId = Example.ident Keiro.ReadModel.Rebuild.mkRebuildRunId runName
            request = Keiro.ReadModel.Rebuild.RebuildRequest runId "guarded-spec" "rebuild event-derived note owners" (GlobalPosition 0)
            options = Keiro.ReadModel.Rebuild.defaultRebuildOptions request
        report <- checked runner (Keiro.ReadModel.Rebuild.startCatalogRebuild Example.catalog group options) >>= either (fail . show) pure
        report ^. #runStatus `shouldBe` Keiro.ReadModel.Rebuild.RebuildRunPromoted
      Example.ensureStateNoteExample runner (note {Example.noteId = "duplicate"}) `shouldReturn` Right ("winner", False)
      counts runner `shouldReturn` (1, 1, 1, 0)
      payload <- checked runner (Store.runTransaction (Tx.statement "winner" Example.richLookup))
      fmap (Aeson.eitherDecodeStrictText :: Text -> Either String Example.Note) payload `shouldBe` Just (Right note)

    it "preserves early catalog mismatch even for a selected silent command" \(_, runner) -> do
      Example.setup runner
      let wrong = Example.commandSet & #projectionSource .~ Example.ident mkSourceId "wrong-source"
      result <- checked runner (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (Example.handler 1) (stream "silent") Example.IgnoreNote Example.catalog wrong (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right () :: Either Example.NoteRefusal ())))
      result `shouldBe` Right (CatalogCommandOutcome (DomainProjectionCommandCatalogMismatch (Example.ident mkSourceId "wrong-source")))

    it "preserves sorted group, declared handler, then event delivery order" \(_, runner) -> do
      Example.setup runner
      let trace label = InlineHandler (InlineProjection label (\event _ -> Tx.statement (label <> ":" <> case event of Example.NoteCreated _ -> "created"; _ -> "audited") (preparable "INSERT INTO app.guard_markers VALUES ($1)" Example.textParam D.noResult))) Example.site
          a = Example.identityDefinition & #handlers .~ (trace "a" :| [trace "b"])
          b = Example.richDefinition & #handlers .~ (trace "c" :| [])
          set = Example.fullSet & #projectionDefinitions .~ (b :| [a])
          definition = Example.catalogDefinition {projectionSets = [SomeProjectionSet set], subscriptions = [], dedupKeys = [], queryModels = []}
          catalog = case validateProjectionCatalog definition of Success value -> value; Failure diagnostics -> error (show diagnostics)
      -- Re-registering a changed group slice is deliberately refused. Reset
      -- the isolated fixture metadata, then register this trace-only catalog.
      checked runner (Store.runTransaction (Tx.sql "DELETE FROM keiro.keiro_read_models; DELETE FROM keiro.keiro_projection_rebuild_groups"))
      checked runner (Keiro.ReadModel.Rebuild.registerProjectionCatalog catalog) >>= (`shouldSatisfy` either (const False) (const True))
      result <-
        checked
          runner
          ( runDomainCommandWithCatalogProjectionsGuarded
              defaultRunCommandOptions
              (Example.handler 4)
              (stream "trace")
              (Example.CreateNote (Example.notePayload (Example.exampleNote "trace" "trace")))
              catalog
              set
              ( \context -> do
                  map (^. #writeGroupId) (catalogPreconditionBindings context) `seq` pure (Right () :: Either Example.NoteRefusal ())
              )
          )
      result `shouldSatisfy` accepted
      checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT marker FROM app.guard_markers ORDER BY ctid" E.noParams (D.rowList (D.column (D.nonNullable D.text))))))
        `shouldReturn` concatMap (\label -> [label <> ":created", label <> ":audited", label <> ":audited", label <> ":audited"]) ["a", "b", "c"]

    it "rolls back a refusing guard's marker, events, global links and inline rows" \(_, runner) -> do
      Example.setup runner
      outcome <- guarded runner "loser" (Example.CreateNote (Example.notePayload (Example.exampleNote "loser" "shared"))) $ \_ -> do
        Tx.sql "INSERT INTO app.guard_markers VALUES ('private-refusal')"
        pure (Left (Example.ExistingNote "winner"))
      outcome `shouldBe` Right (PreconditionRefused (Example.ExistingNote "winner"))
      checked runner (Store.readStreamForward (StreamName "loser") (StreamVersion 0) 100) `shouldReturn` mempty
      counts runner `shouldReturn` (0, 0, 0, 0)

    it "never invokes a faulting inline handler after refusal" \(_, runner) -> do
      Example.setup runner
      let projection :: InlineProjection Example.NoteEvent
          projection = InlineProjection "note-identity" (\_ _ -> Tx.sql "SELECT 1 / 0")
          definition = Example.identityDefinition & #handlers .~ (InlineHandler projection Example.site :| [])
          set = Example.commandSet & #projectionDefinitions .~ (definition :| [])
          run guard = checked runner (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (Example.handler 1) (stream "handler-fault") (Example.CreateNote (Example.notePayload (Example.exampleNote "handler-fault" "shared"))) Example.catalog set guard)
      run (\_ -> pure (Left (Example.ExistingNote "winner"))) `shouldReturn` Right (PreconditionRefused (Example.ExistingNote "winner"))
      -- Positive control proves the handler fault is observable if admitted.
      run (\_ -> pure (Right ())) >>= (`shouldSatisfy` \case Left StoreFailed {} -> True; _ -> False)
      counts runner `shouldReturn` (0, 0, 0, 0)

    it "commits the complete four-event batch only after a successful guard" \(_, runner) -> do
      Example.setup runner
      let note = Example.exampleNote "winner" "shared"
      result <- guarded runner "winner" (Example.CreateNote (Example.notePayload note)) (Example.noteGuard note)
      result `shouldSatisfy` accepted
      events <- checked runner (Store.readStreamForward (StreamName "winner") (StreamVersion 0) 100)
      length events `shouldBe` 4
      counts runner `shouldReturn` (4, 1, 0, 0)
      forM_ events \event -> checked runner (Store.runTransaction (applyAsyncProjectionFromCatalog Example.catalog Example.richOwner Example.richProjection event)) >>= (`shouldBe` CatalogAsyncApplied)
      counts runner `shouldReturn` (4, 1, 1, 0)
      payload <- checked runner (Store.runTransaction (Tx.statement "winner" Example.richLookup))
      fmap (Aeson.eitherDecodeStrictText :: Text -> Either String Example.Note) payload `shouldBe` Just (Right note)

    forM_ [Example.IgnoreNote, Example.RejectNote] \command ->
      it ("skips catalog and callback SQL for " <> show command) \(_, runner) -> do
        Example.setup runner
        checked runner (Store.runTransaction (Tx.sql "DELETE FROM keiro.keiro_read_models; DELETE FROM keiro.keiro_projection_rebuild_groups"))
        result <- guarded runner "silent" command (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right ()))
        result `shouldSatisfy` \case Right (CatalogCommandOutcome (DomainProjectionCommandApplied _)) -> True; _ -> False
        counts runner `shouldReturn` (0, 0, 0, 0)

    it "keeps unmatched commands and genuine guard SQL failures operational" \(_, runner) -> do
      Example.setup runner
      guarded runner "unmatched" Example.UnmatchedNote (\_ -> pure (Right ())) `shouldReturn` Left CommandRejected
      let StoreRunner run = runner
      failure <- run (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (Example.handler 1) (stream "fault") (Example.CreateNote (Example.notePayload (Example.exampleNote "fault" "fault"))) Example.catalog Example.commandSet (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right () :: Either Example.NoteRefusal ())))
      failure `shouldSatisfy` \case Right (Left (StoreFailed _)) -> True; _ -> False
      counts runner `shouldReturn` (0, 0, 0, 0)

    forM_ ["missing", "rebuilding", "failed"] \status ->
      it ("gives a " <> status <> " catalog precedence over duplicate refusal") \(_, runner) -> do
        Example.setup runner
        checked
          runner
          ( Store.runTransaction
              ( Tx.sql
                  ( case status of
                      "missing" -> "DELETE FROM keiro.keiro_projection_rebuild_groups WHERE group_id = 'note-identity-group'"
                      "rebuilding" -> "UPDATE keiro.keiro_projection_rebuild_groups SET status = 'rebuilding', active_run_id = 'test-run', writes_allowed = false, reads_allowed = false WHERE group_id = 'note-identity-group'"
                      _ -> "UPDATE keiro.keiro_projection_rebuild_groups SET status = 'failed', active_run_id = 'test-run', writes_allowed = false, reads_allowed = false WHERE group_id = 'note-identity-group'"
                  )
              )
          )
        result <- guarded runner "fenced" (Example.CreateNote (Example.notePayload (Example.exampleNote "fenced" "shared"))) (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Left (Example.ExistingNote "winner")))
        let expected = if status == "missing" then DomainProjectionCommandGroupUnregistered Example.identityGroup else DomainProjectionCommandFenced Example.identityGroup (either (error . show) id (Keiro.ReadModel.Rebuild.mkRebuildRunId "test-run"))
        result `shouldBe` Right (CatalogCommandOutcome expected)
        counts runner `shouldReturn` (0, 0, 0, 0)

    it "uses an inline-only set while the rich group is fenced, and rejects a broad set" \(_, runner) -> do
      Example.setup runner
      checked runner (Store.runTransaction (Tx.sql "UPDATE keiro.keiro_projection_rebuild_groups SET status = 'failed', active_run_id = 'test-run', reads_allowed = false, writes_allowed = false WHERE group_id = 'note-rich-group'"))
      let note = Example.exampleNote "winner" "shared"
          faulting :: InlineProjection Example.NoteEvent
          faulting = InlineProjection "note-identity" (\_ _ -> Tx.sql "SELECT 1 / 0")
          firstDefinition = Example.identityDefinition & #handlers .~ (InlineHandler faulting Example.site :| [])
          broadSet = Example.fullSet & #projectionDefinitions .~ (firstDefinition :| [Example.richDefinition])
      Example.ensureStateNoteExample runner note `shouldReturn` Right ("winner", True)
      Example.ensureStateNoteExample runner (note {Example.noteId = "loser"}) `shouldReturn` Right ("winner", False)
      result <- checked runner (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (Example.handler 1) (stream "broad") (Example.CreateNote (Example.notePayload (Example.exampleNote "broad" "other"))) Example.catalog broadSet (\_ -> Tx.sql "SELECT 1 / 0" >> pure (Right () :: Either Example.NoteRefusal ())))
      result `shouldBe` Right (CatalogCommandOutcome (DomainProjectionCommandFenced Example.richGroup (either (error . show) id (Keiro.ReadModel.Rebuild.mkRebuildRunId "test-run"))))
      counts runner `shouldReturn` (1, 1, 0, 0)

    it "retains the original payload through duplicate calls, archive and replay" \(_, runner) -> do
      Example.setup runner
      let winner = Example.exampleNote "winner" "shared"
          loser = winner {Example.noteId = "loser", Example.content = "replacement", Example.tags = ["replacement"], Example.provenance = "replacement"}
      Example.ensureStateNoteExample runner winner `shouldReturn` Right ("winner", True)
      archived <- guardedWithBatch 1 runner "winner" (Example.ArchiveNote "winner") (\_ -> pure (Right ()))
      archived `shouldSatisfy` accepted
      Example.ensureStateNoteExample runner loser `shouldReturn` Right ("winner", False)
      events <- checked runner (Store.readStreamForward (StreamName "winner") (StreamVersion 0) 100)
      forM_ events \event -> checked runner (Store.runTransaction (applyAsyncProjectionFromCatalog Example.catalog Example.richOwner Example.richProjection event)) >>= (`shouldBe` CatalogAsyncApplied)
      payload <- checked runner (Store.runTransaction (Tx.statement "winner" Example.richLookup))
      fmap (Aeson.eitherDecodeStrictText :: Text -> Either String Example.Note) payload `shouldBe` Just (Right winner)
      checked runner (Store.runTransaction (Tx.sql "TRUNCATE app.state_note_identity, app.state_notes"))
      forM_ events \event -> case Example.decodeNoteRecorded event of
        ReplayRelevant decoded -> checked runner (Store.runTransaction (Example.applyIdentity decoded event >> Example.applyRich decoded event))
        other -> expectationFailure (show other)
      Example.ensureStateNoteExample runner loser `shouldReturn` Right ("winner", False)
      counts runner `shouldReturn` (2, 1, 1, 0)

  forM_ [False, True] \reverseStart ->
    it ("races independent stores with a paused rich worker, reverse=" <> show reverseStart) $
      withFreshResourceStoresSameDatabase fixture \((_, first), (_, second)) -> do
        Example.setup first
        let a = Example.exampleNote "a" "shared"
            b = (Example.exampleNote "b" "shared") {Example.content = "different", Example.tags = ["different"], Example.provenance = "different"}
        start <- newEmptyMVar
        let call runner note = readMVar start >> Example.ensureStateNoteExample runner note
        results <-
          if reverseStart
            then parallel (putMVar start () >> call second b) (call first a)
            else parallel (putMVar start () >> call first a) (call second b)
        case results of
          (Right (winner, changed), Right (same, otherChanged)) -> do
            winner `shouldBe` same
            changed `shouldBe` not otherChanged
            counts first `shouldReturn` (1, 1, 0, 0)
            let original = if winner == "a" then a else b
            events <- checked first (Store.readStreamForward (StreamName winner) (StreamVersion 0) 10)
            forM_ events \event -> checked first (Store.runTransaction (applyAsyncProjectionFromCatalog Example.catalog Example.richOwner Example.richProjection event)) >>= (`shouldBe` CatalogAsyncApplied)
            counts first `shouldReturn` (1, 1, 1, 0)
            payload <- checked first (Store.runTransaction (Tx.statement winner Example.richLookup))
            fmap (Aeson.eitherDecodeStrictText :: Text -> Either String Example.Note) payload `shouldBe` Just (Right original)
          other -> expectationFailure (show other)

  forM_ [False, True] \rollbackFirst ->
    it ("observes an append lock wait then " <> if rollbackFirst then "rolls back the first writer" else "commits the first writer") $
      withFreshResourceStoresSameDatabaseWithConnection fixture \connection ((_, first), (_, second)) ->
        withController connection \controller -> do
          Example.setup first
          script controller "SELECT pg_advisory_lock(306)"
          firstDone <- newEmptyMVar
          secondDone <- newEmptyMVar
          let a = Example.exampleNote "a" "shared"
              b = Example.exampleNote "b" "shared"
              firstGuard context = do
                Tx.sql "SET LOCAL application_name = 'keiro-306-held-guard'; SELECT pg_advisory_xact_lock(306)"
                if rollbackFirst then pure (Left (Example.GuardConfigurationFault "test rollback")) else Example.noteGuard a context
          firstThread <- forkFinally (guarded first "a" (Example.CreateNote (Example.notePayload a)) firstGuard) (putMVar firstDone)
          let cleanup = script controller "SELECT pg_advisory_unlock_all()" >> killThread firstThread
          flip finally cleanup do
            waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name = 'keiro-306-held-guard' AND wait_event_type = 'Lock')"
            secondThread <- forkFinally (Example.ensureStateNoteExample second b) (putMVar secondDone)
            flip finally (killThread secondThread) do
              waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_stat_activity blocked, pg_stat_activity holder WHERE holder.application_name = 'keiro-306-held-guard' AND holder.pid = ANY(pg_blocking_pids(blocked.pid)))"
              script controller "SELECT pg_advisory_unlock(306)"
              firstResult <- awaitWorker firstDone
              secondResult <- awaitWorker secondDone
              if rollbackFirst
                then do
                  firstResult `shouldBe` Right (PreconditionRefused (Example.GuardConfigurationFault "test rollback"))
                  secondResult `shouldBe` Right ("b", True)
                  counts first `shouldReturn` (1, 1, 0, 0)
                else do
                  firstResult `shouldSatisfy` accepted
                  secondResult `shouldBe` Right ("a", False)
                  counts first `shouldReturn` (4, 1, 0, 0)

  around (withFreshResourceStore fixture) $ do
    forM_ ["40001", "40P01"] \sqlState ->
      it ("re-evaluates the callback after a one-time driver " <> sqlState <> " retry") \(_, runner) -> do
        Example.setup runner
        checked runner (Store.runTransaction (Tx.sql "CREATE SEQUENCE app.driver_attempts"))
        let note = Example.exampleNote "retry" "shared"
            retryGuard context = do
              decision <- Example.noteGuard note context
              attempt <- Tx.statement () (preparable "SELECT nextval('app.driver_attempts')" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
              if attempt == 1
                then do
                  Tx.sql (if sqlState == "40001" then "DO $$ BEGIN RAISE EXCEPTION 'test retry' USING ERRCODE = '40001'; END $$" else "DO $$ BEGIN RAISE EXCEPTION 'test retry' USING ERRCODE = '40P01'; END $$")
                  pure decision
                else pure (Left (Example.ExistingNote "fresh-result"))
        result <- guarded runner "retry" (Example.CreateNote (Example.notePayload note)) retryGuard
        result `shouldBe` Right (PreconditionRefused (Example.ExistingNote "fresh-result"))
        checked runner (Store.runTransaction (Tx.statement () (preparable "SELECT last_value FROM app.driver_attempts" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))))) `shouldReturn` 2
        counts runner `shouldReturn` (0, 0, 0, 0)

    it "waits after commit and retries the same receipt when the rich view catches up" \(_, runner) -> do
      Example.setup runner
      checked runner (Store.initializeSubscriptionCheckpoint (Store.SubscriptionName "note-rich-worker") 0 FromBeginning) >>= (`shouldSatisfy` either (const False) (const True))
      let note = Example.exampleNote "winner" "shared"
      result <- guarded runner "winner" (Example.CreateNote (Example.notePayload note)) (Example.noteGuard note)
      receipt <- case result of
        Right (CatalogCommandOutcome (DomainProjectionCommandApplied outcome)) -> pure (outcome ^. #result)
        other -> expectationFailure (show other) >> error "unreachable"
      let options = PositionWaitOptions (receipt ^. #globalPosition) 20000 1000
      checked runner (runQueryWithFreshness Nothing (WaitForPosition options) Example.richReadModel "winner") >>= (`shouldSatisfy` \case Left ReadModelWaitTimeout {} -> True; _ -> False)
      events <- checked runner (Store.readStreamForward (StreamName "winner") (StreamVersion 0) 100)
      forM_ events \event -> checked runner (Store.runTransaction (applyAsyncProjectionFromCatalog Example.catalog Example.richOwner Example.richProjection event)) >>= (`shouldBe` CatalogAsyncApplied)
      checked runner (Store.runTransaction (Store.resetSubscriptionCheckpointsTx (Store.SubscriptionName "note-rich-worker" :| []) (fromMaybe (error "accepted receipt lacks position") (receipt ^. #globalPosition))))
      ready <- checked runner (runQueryWithFreshness Nothing (WaitForPosition options) Example.richReadModel "winner")
      ready `shouldSatisfy` \case Right (Just _) -> True; _ -> False
      counts runner `shouldReturn` (4, 1, 1, 0)
      checked runner (Store.runTransaction (Tx.sql "UPDATE keiro.keiro_read_models SET status='rebuilding' WHERE name='note-rich-query'"))
      checked runner (runQueryWithFreshness Nothing (WaitForPosition options) Example.richReadModel "winner") `shouldReturn` Left (ReadModelNotLive "note-rich-query" Rebuilding)
      -- A committed receipt remains valid even when its view is unavailable.
      Example.ensureStateNoteExample runner (note {Example.noteId = "later-duplicate"}) `shouldReturn` Right ("winner", False)

  it "reads a newly committed winner after a driver retry, under the append protocol" $
    withFreshResourceStoresSameDatabaseWithConnection fixture \connection ((_, retrying), (_, other)) ->
      withController connection \controller -> do
        Example.setup retrying
        -- Test-only backend instrumentation survives rollback. A BEFORE
        -- STATEMENT trigger gates the retry before it can acquire append row
        -- locks, permitting a third transaction to commit a real winner.
        checked
          retrying
          ( Store.runTransaction
              ( Tx.sql
                  """
                  CREATE SEQUENCE app.fresh_driver_attempts;
                  CREATE FUNCTION app.gate_driver_retry() RETURNS trigger LANGUAGE plpgsql AS $$
                  BEGIN
                    IF EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory'
                               AND pid = pg_backend_pid() AND objid = 30601 AND granted) THEN
                      PERFORM pg_advisory_xact_lock(30602);
                    END IF;
                    RETURN NULL;
                  END $$;
                  CREATE TRIGGER gate_driver_retry BEFORE UPDATE ON streams
                    FOR EACH STATEMENT EXECUTE FUNCTION app.gate_driver_retry();
                  """
              )
          )
        script controller "SELECT pg_advisory_lock(30602)"
        done <- newEmptyMVar
        let attempted = Example.exampleNote "retry-candidate" "shared"
            winner = Example.exampleNote "winner" "shared"
            guard context = do
              result <- Example.noteGuard attempted context
              count <- Tx.statement () (preparable "SELECT nextval('app.fresh_driver_attempts')" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
              if count == 1
                then do
                  Tx.sql "SELECT pg_advisory_lock(30601); DO $$ BEGIN RAISE EXCEPTION 'one-time retry' USING ERRCODE = '40001'; END $$"
                  pure result
                else do
                  Tx.sql "SELECT pg_advisory_unlock(30601)"
                  pure result
        worker <- forkFinally (guardedWithBatch 1 retrying "retry-candidate" (Example.CreateNote (Example.notePayload attempted)) guard) (putMVar done)
        flip finally (script controller "SELECT pg_advisory_unlock_all()" >> killThread worker) do
          waitSql controller "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 30602 AND NOT granted)"
          Example.ensureStateNoteExample other winner `shouldReturn` Right ("winner", True)
          script controller "SELECT pg_advisory_unlock(30602)"
          awaitWorker done `shouldReturn` Right (PreconditionRefused (Example.ExistingNote "winner"))
          counts retrying `shouldReturn` (1, 1, 0, 0)

withController connection =
  bracket
    (Pool.acquire (PoolConfig.settings [PoolConfig.staticConnectionSettings (Conn.connectionString connection), PoolConfig.size 1]))
    Pool.release

script controller sql = Pool.use controller (Session.script sql) >>= either (fail . show) pure

waitSql controller sql = do
  result <- timeout (5 * 1000000) loop
  case result of Just () -> pure (); Nothing -> fail ("SQL observation timed out: " <> Text.unpack sql)
  where
    loop = do
      ready <- Pool.use controller (Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.bool))))) >>= either (fail . show) pure
      unless ready (threadDelay 10000 >> loop)

awaitWorker done =
  timeout (20 * 1000000) (takeMVar done) >>= \case
    Just (Right value) -> pure value
    Just (Left err) -> fail (show err)
    Nothing -> fail "worker completion timed out"

type Outcome = Either CommandError (GuardedCatalogOutcome Example.NoteStream Example.NoteEvent Text Text Example.NoteRefusal)

guarded :: StoreRunner -> Text -> Example.NoteCommand -> (CatalogPreconditionContext -> Tx.Transaction (Either Example.NoteRefusal ())) -> IO Outcome
guarded = guardedWithBatch 4

guardedWithBatch :: Int -> StoreRunner -> Text -> Example.NoteCommand -> (CatalogPreconditionContext -> Tx.Transaction (Either Example.NoteRefusal ())) -> IO Outcome
guardedWithBatch batch runner candidate command guard = checked runner (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (Example.handler batch) (stream candidate) command Example.catalog Example.commandSet guard)

checked :: StoreRunner -> Eff '[Store.Store, Error Store.StoreError, Store.KirokuStoreResource, IOE] a -> IO a
checked (StoreRunner run) action = run action >>= either (fail . show) pure

accepted :: Outcome -> Bool
accepted = \case Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}})) -> True; _ -> False

counts :: StoreRunner -> IO (Int64, Int64, Int64, Int64)
counts runner =
  checked
    runner
    ( Store.runTransaction
        ( Tx.statement
            ()
            ( preparable
                "SELECT (SELECT count(*) FROM stream_events WHERE stream_id = 0), (SELECT count(*) FROM app.state_note_identity), (SELECT count(*) FROM app.state_notes), (SELECT count(*) FROM app.guard_markers)"
                E.noParams
                (D.singleRow ((,,,) <$> col <*> col <*> col <*> col))
            )
        )
    )
  where
    col = D.column (D.nonNullable D.int8)

occScenario retrying winner handler budget expected = do
  Example.setup retrying
  checked retrying (Store.runTransaction (Tx.sql "CREATE SEQUENCE app.occ_guard_reads"))
  hydrated <- newEmptyMVar
  release <- newEmptyMVar
  attempts <- newIORef (0 :: Int)
  done <- newEmptyMVar
  let note = Example.exampleNote "same-stream" "shared"
      hook = do
        attempt <- atomicModifyIORef' attempts (\n -> (n + 1, n))
        when (attempt == 0) (putMVar hydrated () >> takeMVar release)
      options = defaultRunCommandOptions & #retryLimit .~ budget & #beforeAppend .~ hook
      guard context = do
        _ <- Tx.statement () (preparable "SELECT nextval('app.occ_guard_reads')" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
        Example.noteGuard note context
      run options runner callback = checked runner (runDomainCommandWithCatalogProjectionsGuarded options handler (stream "same-stream") (Example.CreateNote (Example.notePayload note)) Example.catalog Example.commandSet callback)
      label = \case
        Left RetryExhausted {} -> "exhausted"
        Right (PreconditionRefused (Example.ExistingNote "same-stream")) -> "reuse"
        Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainNoOp "already-created"})) -> "noop"
        Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}})) -> "accepted"
        other -> Text.pack (show other)
  worker <- forkFinally (label <$> run options retrying guard) (putMVar done)
  flip finally (void (tryPutMVar release ()) >> killThread worker) do
    timeout (5 * 1000000) (takeMVar hydrated) >>= (`shouldBe` Just ())
    label <$> run defaultRunCommandOptions winner (Example.noteGuard note) `shouldReturn` "accepted"
    putMVar release ()
    awaitWorker done `shouldReturn` expected
    checked retrying (Store.runTransaction (Tx.statement () (preparable "SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM app.occ_guard_reads" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
      `shouldReturn` (if expected == "reuse" then 1 else 0)
    counts retrying `shouldReturn` (1, 1, 0, 0)

data OnceState = Uncreated | Stored deriving stock (Eq, Ord, Show, Enum, Bounded)

onceHandler :: DomainCommandHandler (Keiki.HsPred '[] Example.NoteCommand) '[] OnceState Example.NoteCommand Example.NoteEvent Text Text
onceHandler = DomainCommandHandler validated (const (SilentNoOp "already-created"))
  where
    original = unvalidated (Example.validated 1)
    validated =
      either
        (error . show)
        id
        ( mkEventStream
            "note-once"
            EventStream
              { transducer =
                  Keiki.SymTransducer
                    { edgesOut = \case
                        Uncreated -> [Keiki.Edge predicate update outputs Stored mode | Keiki.Edge predicate update outputs _ mode <- take 1 (Keiki.edgesOut (original ^. #transducer) Example.Ready)]
                        Stored -> [Keiki.Edge (Keiki.matchInCtor Example.createCtor) Keiki.UKeep [] Stored Keiki.Live],
                      initial = Uncreated,
                      initialRegs = Keiki.RNil,
                      isFinal = const False
                    },
                initialState = Uncreated,
                initialRegisters = Keiki.RNil,
                eventCodec = Example.noteCodec,
                resolveStreamName = streamName,
                snapshotPolicy = Never,
                stateCodec = Nothing
              }
        )

parallel :: IO a -> IO b -> IO (a, b)
parallel first second = do
  a <- newEmptyMVar
  b <- newEmptyMVar
  threadA <- forkFinally first (putMVar a)
  threadB <- forkFinally second (putMVar b)
  result <-
    timeout (20 * 1000000) ((,) <$> takeMVar a <*> takeMVar b)
      `finally` (killThread threadA >> killThread threadB)
  case result of
    Just (Right x, Right y) -> pure (x, y)
    Just other -> fail ("worker fault: " <> showErrors other)
    Nothing -> fail "same-database workers timed out"
  where
    showErrors (a, b) = either show (const "success") a <> "/" <> either show (const "success") b
