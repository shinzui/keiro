module ReadModelFenceSpec (spec, withLatch, withTask, backend, awaitBlocked, latch) where

import CatalogSpec qualified as Catalog
import Contravariant.Extras (contrazip2)
import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, throwIO)
import Data.Int (Int32)
import Data.List.NonEmpty qualified as NonEmpty
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro.Prelude
import Keiro.Projection.Catalog (Validation (..), validateProjectionCatalog)
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))
import System.Timeout (timeout)
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> expectationFailure (show err) >> error "unreachable") pure

run :: Store.KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO a
run store action = expectRight =<< Store.runStoreIO store action

-- Scoped threads are joined through a bounded result wait and cancelled on any
-- assertion failure. The 60-second SQL sleep is only an interruptible latch.
withTask :: IO a -> (IO a -> IO b) -> IO b
withTask action use = bracket acquire (killThread . fst) $ \(_, result) -> use $ do
  observed <- timeout 10000000 (takeMVar result)
  case observed of
    Nothing -> expectationFailure "task did not finish" >> error "unreachable"
    Just outcome -> either throwIO pure outcome
  where
    acquire = do
      result <- newEmptyMVar
      tid <- forkFinally action (putMVar result)
      pure (tid, result)

awaitState :: IO (Maybe a) -> IO a
awaitState action = do
  observed <- timeout 5000000 loop
  maybe (expectationFailure "database lock state was not observed" >> error "unreachable") pure observed
  where
    loop = action >>= maybe (threadDelay 10000 >> loop) pure

backend :: Store.KirokuStore -> Text -> Text -> IO Int32
backend store marker event =
  awaitState $
    run store $
      Store.runTransaction $
        Tx.statement (marker, event) $
          preparable
            "SELECT pid FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND query LIKE '%' || $1 || '%' AND wait_event = $2"
            (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
            (D.rowMaybe (D.column (D.nonNullable D.int4)))

awaitBlocked :: Store.KirokuStore -> Int32 -> IO ()
awaitBlocked store blocker = awaitState $ do
  blocked <-
    run store $
      Store.runTransaction $
        Tx.statement blocker $
          preparable
            "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND $1 = ANY(pg_blocking_pids(pid)))"
            (E.param (E.nonNullable E.int4))
            (D.singleRow (D.column (D.nonNullable D.bool)))
  pure (if blocked then Just () else Nothing)

cancelBackend :: Store.KirokuStore -> Int32 -> IO ()
cancelBackend store pid = do
  result <-
    run store $
      Store.runTransaction $
        Tx.statement pid $
          preparable
            "SELECT pg_cancel_backend($1)"
            (E.param (E.nonNullable E.int4))
            (D.singleRow (D.column (D.nonNullable D.bool)))
  result `shouldBe` True

latch :: Tx.Transaction ()
latch = Tx.sql "SELECT pg_advisory_xact_lock(691803) /* native-query-reader */"

withLatch :: Store.KirokuStore -> (IO () -> IO a) -> IO a
withLatch store use = withTask (Store.runStoreIO store (Store.runTransaction (Tx.sql "SELECT pg_advisory_xact_lock(691803); SELECT pg_sleep(60) /* native-query-holder */"))) $ \joinHolder -> do
  pid <- backend store "native-query-holder" "PgSleep"
  use $ do
    cancelBackend store pid
    joinHolder >>= \case
      Left _ -> pure ()
      Right _ -> expectationFailure "holder should have been cancelled"

model :: Text -> ReadModel () Int64
model name =
  immediateReadModel
    ReadModelBlueprint
      { name = name,
        tableName = name,
        schema = "public",
        version = 1,
        shapeHash = "count-v1",
        cursorAuthority = NoQueryCursor,
        query = \() -> countRows ("public." <> name)
      }

countRows :: Text -> Tx.Transaction Int64
countRows table = Tx.statement () $ preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))

register :: Store.KirokuStore -> ReadModel q r -> IO ()
register store value = void $ run store $ registerReadModel (value ^. #name) (value ^. #version) (value ^. #shapeHash)

spec :: Fixture -> Spec
spec fixture = describe "native read-model query fence" $ around (withFreshStore fixture) $ do
  it "validates every compound model before executing SQL" $ \store -> do
    let a = model "query_a"
        b = model "query_b"
        query models = run store (runReadModelTransaction models (Tx.sql "SELECT 1/0"))
    register store a
    query (readModelRequirement a NonEmpty.:| [readModelRequirement b]) `shouldReturn` Left (ReadModelUnregistered "query_b")
    register store b
    query (readModelRequirement a NonEmpty.:| [readModelRequirement (b & #shapeHash .~ "bad")])
      `shouldReturn` Left (ReadModelStaleSchema "query_b" 1 1 "bad" "count-v1")
    _ <- run store (markRebuilding "query_b" 1 "count-v1")
    query (readModelRequirement b NonEmpty.:| [readModelRequirement a])
      `shouldReturn` Left (ReadModelGroupUnavailable "$legacy-read-model:query_b" "rebuilding")

  it "holds a catalog group through native runQuery SQL until the reader completes" $ \store -> do
    validated <- case validateProjectionCatalog Catalog.validCatalog of
      Failure diagnostics -> expectationFailure (show diagnostics) >> error "unreachable"
      Success value -> pure value
    run store $ Store.runTransaction $ Tx.sql "CREATE SCHEMA app; CREATE TABLE app.counter (id bigint PRIMARY KEY); CREATE TABLE app.counter_audit (id bigint PRIMARY KEY, counter_id bigint); INSERT INTO app.counter VALUES (1); INSERT INTO app.counter_audit VALUES (1,1); INSERT INTO subscriptions (subscription_name,last_seen) VALUES ('catalog-async-subscription',0)"
    _ <- expectRight =<< run store (Rebuild.registerProjectionCatalog validated)
    let counted = ((Catalog.counterBinding ^. #readModel) :: ReadModel Text ()) {query = \_ -> latch >> countRows "app.counter"}
        request =
          Rebuild.RebuildRequest
            { rebuildRunId = either (error . show) id (Rebuild.mkRebuildRunId "native-query-race"),
              requestedBy = "native-query-spec",
              requestReason = "atomic query proof",
              replayFrom = GlobalPosition 0
            }
    withLatch store $ \release ->
      withTask (run store (runQuery Nothing counted "")) $ \joinReader -> do
        reader <- backend store "native-query-reader" "advisory"
        withTask (run store (Rebuild.beginGroupRebuild validated Catalog.mainGroupId request)) $ \joinWriter -> do
          awaitBlocked store reader
          release
          joinReader `shouldReturn` Right 1
          _ <- expectRight =<< joinWriter
          run store (Store.runTransaction (countRows "app.counter")) `shouldReturn` 0

  it "protects every group in a compound query, regardless of requirement order" $ \store -> do
    let a = model "query_a"
        b = model "query_b"
    run store $ Store.runTransaction $ Tx.sql "CREATE TABLE public.query_a (id int); CREATE TABLE public.query_b (id int); INSERT INTO public.query_a VALUES (1); INSERT INTO public.query_b VALUES (1)"
    register store a
    register store b
    withLatch store $ \release ->
      withTask (run store (runReadModelTransaction (readModelRequirement b NonEmpty.:| [readModelRequirement a]) (latch >> ((+) <$> countRows "public.query_a" <*> countRows "public.query_b")))) $ \joinReader -> do
        reader <- backend store "native-query-reader" "advisory"
        withTask (run store (Rebuild.startRebuild b [] (GlobalPosition 0))) $ \joinWriter -> do
          awaitBlocked store reader
          release
          joinReader `shouldReturn` Right 2
          _ <- joinWriter
          run store (Store.runTransaction (countRows "public.query_a")) `shouldReturn` 1
          run store (Store.runTransaction (countRows "public.query_b")) `shouldReturn` 0

  it "refuses a rebuild committed while query lock acquisition was waiting" $ \store -> do
    let a = model "query_a"
    run store $ Store.runTransaction $ Tx.sql "CREATE TABLE public.query_a (id int); INSERT INTO public.query_a VALUES (1)"
    register store a
    withLatch store $ \release ->
      withTask (run store (Store.runTransaction (transitionReadModelTx "query_a" 1 "count-v1" Rebuilding >> latch >> Tx.sql "TRUNCATE public.query_a"))) $ \joinWriter -> do
        writer <- backend store "native-query-reader" "advisory"
        withTask (run store (runQuery Nothing a ())) $ \joinReader -> do
          awaitBlocked store writer
          release
          _ <- joinWriter
          joinReader `shouldReturn` Left (ReadModelGroupUnavailable "$legacy-read-model:query_a" "rebuilding")

  it "checks group read availability even when the model registry remains live" $ \store -> do
    let a = model "query_a"
    register store a
    run store $ Store.runTransaction $ Tx.sql "UPDATE keiro.keiro_projection_rebuild_groups SET status = 'failed', active_run_id = 'failed-test', reads_allowed = false, writes_allowed = false WHERE group_id = '$legacy-read-model:query_a'"
    run store (runQuery Nothing a ()) `shouldReturn` Left (ReadModelGroupUnavailable "$legacy-read-model:query_a" "failed")

  it "rejects a model moved to another group while its old group lock was waiting" $ \store -> do
    let a = model "query_a"
        b = model "query_b"
    register store a
    register store b
    withLatch store $ \release ->
      withTask (run store (Store.runTransaction (Tx.sql "SELECT group_id FROM keiro.keiro_projection_rebuild_groups WHERE group_id = '$legacy-read-model:query_a' FOR UPDATE" >> latch >> Tx.sql "UPDATE keiro.keiro_read_models SET rebuild_group_id = '$legacy-read-model:query_b' WHERE name = 'query_a'"))) $ \joinMover -> do
        mover <- backend store "native-query-reader" "advisory"
        withTask (run store (runQuery Nothing a ())) $ \joinReader -> do
          awaitBlocked store mover
          release
          _ <- joinMover
          joinReader `shouldReturn` Left (ReadModelRegistrationChanged "query_a")

  it "revalidates schema changed while query lock acquisition was waiting" $ \store -> do
    let a = model "query_a"
    register store a
    withLatch store $ \release ->
      withTask (run store (Store.runTransaction (transitionReadModelTx "query_a" 1 "count-v1" Live >> latch >> transitionReadModelTx "query_a" 2 "count-v2" Live))) $ \joinChanger -> do
        changer <- backend store "native-query-reader" "advisory"
        withTask (run store (runQuery Nothing a ())) $ \joinReader -> do
          awaitBlocked store changer
          release
          _ <- joinChanger
          joinReader `shouldReturn` Left (ReadModelStaleSchema "query_a" 1 2 "count-v1" "count-v2")
