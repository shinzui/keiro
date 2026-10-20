{-# LANGUAGE OverloadedRecordDot #-}

module WorkflowInspectionSpec (spec) where

import Control.Monad (forM, forM_)
import Data.Aeson (Value (..))
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Inspection.Cursor
import Keiro.Test.Postgres
import Keiro.Workflow (appendJournalEntry, continueAsNew, runWorkflow)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Inspection
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Schema qualified as Schema
import Keiro.Workflow.Types
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventData (..), EventType (..), ExpectedVersion (..))
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = describe "Keiro.Workflow.Inspection" $ do
  describe "opaque cursors" $ do
    it "round-trips Unicode and exact timestamps, rejects foreign kinds and oversized tokens" $ do
      let payload = ("承認" :: Text, "workflow/1" :: Text, read "2026-10-20 01:02:03.123456 UTC" :: UTCTime)
          token = encodeCursor "wf-key" payload
      decodeCursor "wf-key" token `shouldBe` Right payload
      (decodeCursor "wf-created" token :: Either CursorError Value) `shouldBe` Left (CursorKindMismatch "wf-created" "wf-key")
      forM_ ["not-a-cursor", "", Text.replicate 4097 "a", "===="] $ \bad ->
        (decodeCursor "wf-key" (InspectionCursor bad) :: Either CursorError Value) `shouldSatisfy` (\case Left (MalformedCursor _) -> True; _ -> False)
  around (withFreshStore fixture) $ do
    it "classifies every stored row identically in Haskell and SQL without modifying rows" $ \store -> do
      sql store "INSERT INTO keiro.keiro_workflows(workflow_id, workflow_name, status, attempts, wake_after) VALUES ('running','test','running',0,NULL),('retrying','test','running',2,NULL),('sleeping','test','suspended',0,now()+interval '1 hour'),('awaiting','test','suspended',0,NULL),('completed','test','completed',0,NULL),('cancelled','test','cancelled',0,NULL),('failed','test','failed',0,NULL)"
      sql store "UPDATE keiro.keiro_workflows SET status='running' WHERE workflow_id='failed'"
      _ <- expectStore store (Instance.claimInstance "stuck-worker" 30 (WorkflowName "test") (WorkflowId "failed"))
      expectStore store (runTransaction (Instance.upsertInstanceTx "failed" "test" 0 Instance.WfFailed (Just "exhausted")))
      original <- expectStore store (Instance.listWorkflowInstances Instance.defaultWorkflowInstanceFilter)
      pages <- forM [minBound .. maxBound] $ \status -> do
        page <- inspect store defaultWorkflowListQuery {classes = Just (status :| [])}
        map statusClassOf page.items `shouldBe` [status]
        if status == ClassFailed then map (.leasedBy) page.items `shouldBe` [Just "stuck-worker"] else pure ()
        pure page.items
      sort (map (.workflowId) (concat pages)) `shouldBe` sort (map (.workflowId) original)
      afterRows <- expectStore store (Instance.listWorkflowInstances Instance.defaultWorkflowInstanceFilter)
      afterRows `shouldBe` original
    it "pages key order completely, and omits continuation on a full final page" $ \store -> do
      seed store 23
      pages <- drain store defaultWorkflowListQuery {pageSize = 5}
      map (length . (.items)) pages `shouldBe` [5, 5, 5, 5, 3]
      let keys = map (\row -> (row.workflowName, row.workflowId)) (concatMap (.items) pages)
      length (nub keys) `shouldBe` 23
      keys `shouldBe` sort keys
      sql store "DELETE FROM keiro.keiro_workflows WHERE workflow_id > 'w-020'"
      full <- drain store defaultWorkflowListQuery {pageSize = 5}
      map (length . (.items)) full `shouldBe` [5, 5, 5, 5]
      map (.nextCursor) full `shouldSatisfy` (\tokens -> case reverse tokens of Nothing : _ -> True; _ -> False)
    it "pages newest creation first including tied timestamps and observes an empty page clock" $ \store -> do
      seed store 12
      pages <- drain store defaultWorkflowListQuery {pageSize = 5, ordering = ByCreatedDesc}
      map (length . (.items)) pages `shouldBe` [5, 5, 2]
      let keys = map (\row -> (row.createdAt, row.workflowName, row.workflowId)) (concatMap (.items) pages)
      keys `shouldBe` reverse (sort keys)
      empty <- inspect store defaultWorkflowListQuery {workflowName = Just "absent"}
      empty.items `shouldBe` []
      empty.nextCursor `shouldBe` Nothing
      empty.observedAt `shouldSatisfy` (> read "2026-01-01 00:00:00 UTC")
    it "rejects sizes and malformed or cross-order cursors before reading" $ \store -> do
      forM_ [0, 501, maxBound] $ \size ->
        expectStore store (listWorkflowInstancesPage defaultWorkflowListQuery {pageSize = size}) `shouldReturn` Left (InvalidPageSize size)
      malformed <- expectStore store (listWorkflowInstancesPage defaultWorkflowListQuery {cursor = Just (InspectionCursor "not-a-cursor")})
      malformed `shouldSatisfy` (\case Left (InvalidCursor (MalformedCursor _)) -> True; _ -> False)
      seed store 2
      first <- inspect store defaultWorkflowListQuery {pageSize = 1}
      crossOrder <- expectStore store (listWorkflowInstancesPage defaultWorkflowListQuery {ordering = ByCreatedDesc, cursor = first.nextCursor})
      crossOrder `shouldSatisfy` (\case Left (InvalidCursor (CursorKindMismatch "wf-created" "wf-key")) -> True; _ -> False)
    it "applies half-open creation and update windows" $ \store -> do
      sql store "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status,created_at,updated_at) SELECT 'window-'||n,'window','running','2026-10-01 00:00:00+00'::timestamptz+n*interval '1 hour','2026-10-01 00:00:00+00'::timestamptz+n*interval '1 hour' FROM generate_series(0,2) n"
      let boundary = read "2026-10-01 01:00:00 UTC" :: UTCTime
      forM_ [defaultWorkflowListQuery {createdSince = Just boundary}, defaultWorkflowListQuery {updatedSince = Just boundary}] $ \query -> do
        page <- inspect store query
        length page.items `shouldBe` 2
      forM_ [defaultWorkflowListQuery {createdBefore = Just boundary}, defaultWorkflowListQuery {updatedBefore = Just boundary}] $ \query -> do
        page <- inspect store query
        length page.items `shouldBe` 1
    it "observes then-current inserts strictly beyond the cursor" $ \store -> do
      seed store 3
      first <- inspect store defaultWorkflowListQuery {pageSize = 1}
      sql store "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) VALUES ('a','a','running'),('z','z','running')"
      second <- inspect store defaultWorkflowListQuery {cursor = first.nextCursor}
      map (.workflowId) second.items `shouldSatisfy` elem "z"
      map (.workflowId) second.items `shouldSatisfy` not . elem "a"
    it "independently pages journal and steps and rejects cross-owner and rotated generation cursors" $ \store -> do
      clock <- expectStore store Schema.inspectionObservedAt
      forM_ ["a", "b", "c"] $ \step -> expectStore store (appendJournalEntry (WorkflowName "test") (WorkflowId "owner") (StepRecorded step Null clock))
      first <- expectStore store (readWorkflowJournalPage (WorkflowName "test") (WorkflowId "owner") (DetailPageQuery Nothing 2 Nothing)) >>= right
      length first.items `shouldBe` 2
      second <- expectStore store (readWorkflowJournalPage (WorkflowName "test") (WorkflowId "owner") (DetailPageQuery Nothing 2 first.nextCursor)) >>= right
      length second.items `shouldBe` 1
      second.nextCursor `shouldBe` Nothing
      steps <- expectStore store (loadStepIndexPage (WorkflowName "test") (WorkflowId "owner") (DetailPageQuery Nothing 2 Nothing)) >>= right
      length steps.items `shouldBe` 2
      other <- expectStore store (loadStepIndexPage (WorkflowName "test") (WorkflowId "different") (DetailPageQuery Nothing 2 steps.nextCursor))
      other `shouldSatisfy` (\case Left (InvalidCursor _) -> True; _ -> False)
      _ <- expectStore store (runWorkflow (WorkflowName "test") (WorkflowId "owner") (continueAsNew () >> pure ()))
      rotated <- expectStore store (loadStepIndexPage (WorkflowName "test") (WorkflowId "owner") (DetailPageQuery Nothing 2 steps.nextCursor))
      rotated `shouldBe` Left (CursorGenerationMismatch 1 0)
    it "pages children and directly allocated awakeables through their owning tables" $ \store -> do
      expectStore store $ runTransaction $ do
        Child.registerChildTx "child-a" "child" "owner" "test" "await-a"
        Child.registerChildTx "child-b" "child" "owner" "test" "await-b"
        Awakeable.registerAwakeableTx UUID.nil "test" "owner"
        Awakeable.registerAwakeableTx (maybe (error "UUID fixture") (\x -> x) (UUID.fromString "00000000-0000-0000-0000-000000000001")) "test" "owner"
      first <- expectStore store (listWorkflowChildrenPage (WorkflowName "test") (WorkflowId "owner") (OwnerPageQuery 1 Nothing)) >>= right
      second <- expectStore store (listWorkflowChildrenPage (WorkflowName "test") (WorkflowId "owner") (OwnerPageQuery 1 first.nextCursor)) >>= right
      map (.childId) (first.items <> second.items) `shouldBe` ["child-a", "child-b"]
      second.nextCursor `shouldBe` Nothing
      awake <- expectStore store (listWorkflowAwakeablesPage (WorkflowName "test") (WorkflowId "owner") (OwnerPageQuery 1 Nothing)) >>= right
      following <- expectStore store (listWorkflowAwakeablesPage (WorkflowName "test") (WorkflowId "owner") (OwnerPageQuery 1 awake.nextCursor)) >>= right
      length (awake.items <> following.items) `shouldBe` 2
      following.nextCursor `shouldBe` Nothing
      foreignPage <- expectStore store (listWorkflowAwakeablesPage (WorkflowName "test") (WorkflowId "different") (OwnerPageQuery 1 awake.nextCursor))
      foreignPage `shouldSatisfy` (\case Left (InvalidCursor _) -> True; _ -> False)
    it "raises the runtime's decode error instead of returning a partial corrupt journal" $ \store -> do
      _ <- expectStore store (appendToStream (workflowGenerationStreamName (WorkflowName "corrupt") (WorkflowId "owner") 0) AnyVersion [EventData Nothing (EventType "StepRecorded") (String "invalid") Nothing Nothing Nothing])
      expectStore store (readWorkflowJournalPage (WorkflowName "corrupt") (WorkflowId "owner") (DetailPageQuery Nothing 2 Nothing))
        `shouldThrow` (\case WorkflowJournalDecodeError _ -> True; _ -> False)

seed :: KirokuStore -> Int -> IO ()
seed store count = sql store ("INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status,created_at,updated_at) SELECT 'w-'||lpad(n::text,3,'0'),'name-'||(n%3),'running','2026-10-01 00:00:00+00'::timestamptz+(n/2)*interval '1 minute','2026-10-01 00:00:00+00'::timestamptz FROM generate_series(1," <> Text.pack (show count) <> ") n")

sql :: KirokuStore -> Text -> IO ()
sql store text = expectStore store (runTransaction (Tx.sql (encodeUtf8 text)))

expectStore :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO a
expectStore store action = runStoreIO store action >>= either (fail . show) pure

right :: (Show err) => Either err a -> IO a
right = either (fail . show) pure

inspect :: KirokuStore -> WorkflowListQuery -> IO WorkflowListPage
inspect store query = expectStore store (listWorkflowInstancesPage query) >>= right

drain :: KirokuStore -> WorkflowListQuery -> IO [WorkflowListPage]
drain store query = do
  page <- inspect store query
  rest <- maybe (pure []) (\token -> drain store query {cursor = Just token}) page.nextCursor
  pure (page : rest)
