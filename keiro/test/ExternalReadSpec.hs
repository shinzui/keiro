{-# LANGUAGE MultilineStrings #-}

module ExternalReadSpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (isEmptyMVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.ReadModel.External
import Keiro.ReadModel.Rebuild (registerProjectionCatalog)
import Keiro.Test.Postgres (Fixture, withFreshDatabase)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Test.Hspec
import Prelude (any, (-), (=<<))

spec :: Fixture -> Spec
spec fixture =
  describe "managed external read contracts"
    $ around (withFreshDatabase fixture)
    $ do
      it "fences lifecycle transitions, holds cutover behind readers, and enforces execute-only grants" $ \connectionString ->
        withPool connectionString $ \pool ->
          Store.withStore (Store.defaultConnectionSettings connectionString) $ \store -> do
            runScript pool allRowsFixtureSql
            catalog <- expectValid Catalog.bridgeCatalog
            register store catalog
            runScript pool activateV1Sql
            expectStore store (reconcileExternalReadContracts catalog) >>= shouldBeRight

            runStatement pool () allRowsStmt `shouldReturn` [(1, 10), (2, 20)]
            runScript pool grantReaderSql
            readerResult <- runReaderTransaction pool (Tx.statement () allRowsStmt)
            expectUsage readerResult `shouldReturn` [(1, 10), (2, 20)]
            deniedTarget <- runReaderTransaction pool (Tx.statement () rawTargetStmt)
            deniedTarget `shouldSatisfy` isSqlFailure
            deniedBinding <- runReaderTransaction pool (Tx.statement () rawBindingStmt)
            deniedBinding `shouldSatisfy` isSqlFailure
            runStatement pool () securityFactsStmt `shouldReturn` (True, True, True, True, True, True, True, True)

            runScript pool beginOfflineSql
            offline <- Pool.use pool (Session.statement () allRowsStmt)
            offline `shouldSatisfy` hasSqlState "KR001"
            runScript pool restoreV1Sql

            unknown <- Pool.use pool (Session.statement () unknownGuardStmt)
            unknown `shouldSatisfy` hasSqlState "KR002"

            runScript pool beginOnlineCandidateSql
            runStatement pool () allRowsStmt `shouldReturn` [(1, 10), (2, 20)]

            readerDone <- newEmptyMVar
            _ <-
              forkIO
                $ Pool.use
                  pool
                  ( TxSessions.transactionNoRetry
                      TxSessions.ReadCommitted
                      TxSessions.Write
                      ( do
                          Tx.sql "SET LOCAL application_name = 'keiro-external-lock-reader'"
                          rows <- Tx.statement () allRowsStmt
                          Tx.sql "SELECT pg_sleep(1)"
                          pure rows
                      )
                  )
                >>= putMVar readerDone
            waitForReader pool 100

            writerDone <- newEmptyMVar
            _ <-
              forkIO
                $ Pool.use
                  pool
                  ( TxSessions.transactionNoRetry
                      TxSessions.ReadCommitted
                      TxSessions.Write
                      ( do
                          Tx.sql compatibleCutoverSql
                          reconciled <- reconcileExternalReadContractsTx catalog
                          case reconciled of
                            Left err -> error (show err)
                            Right () -> pure ()
                      )
                  )
                >>= putMVar writerDone
            threadDelay 150_000
            isEmptyMVar writerDone `shouldReturn` True
            lockedReaderResult <- takeMVar readerDone
            expectUsage lockedReaderResult `shouldReturn` [(1, 10), (2, 20)]
            writerResult <- takeMVar writerDone
            expectUsage writerResult
            runStatement pool () allRowsStmt `shouldReturn` [(1, 30), (2, 40)]

            runScript pool corruptServingShapeSql
            incompatible <- Pool.use pool (Session.statement () allRowsStmt)
            incompatible `shouldSatisfy` hasSqlState "KR003"
            expectStore store (reconcileExternalReadContracts catalog) >>= shouldBeRight

            contract <- onlyContract catalog
            retirementPreview <-
              expectStore
                store
                ( previewExternalReadContractRetirement
                    (contract ^. #readContractId)
                    (contract ^. #contractVersion)
                )
                >>= shouldBeRight
            retirementPreview ^. #executeGrants
              `shouldSatisfy` any (Text.isPrefixOf "external_reader:EXECUTE")
            retired <-
              expectStore
                store
                ( retireExternalReadContract
                    (contract ^. #readContractId)
                    (contract ^. #contractVersion)
                )
            retired `shouldSatisfy` \case Right value -> value ^. #currentState == "retired"; Left _ -> False
            retiredRead <- Pool.use pool (Session.statement () allRowsStmt)
            retiredRead `shouldSatisfy` hasSqlState "KR002"

      it "refuses rolling downgrades and preserves consumer-owned dependents" $ \connectionString ->
        withPool connectionString $ \pool ->
          Store.withStore (Store.defaultConnectionSettings connectionString) $ \store -> do
            runScript pool allRowsFixtureSql
            generation1 <- expectValid Catalog.bridgeCatalog
            register store generation1
            runScript pool activateV1Sql
            expectStore store (reconcileExternalReadContracts generation1) >>= shouldBeRight
            runScript pool consumerDependentSql

            generation2 <- expectValid (catalogAtGeneration 2)
            expectStore store (reconcileExternalReadContracts generation2) >>= shouldBeRight
            downgrade <- expectStore store (reconcileExternalReadContracts generation1)
            downgrade
              `shouldSatisfy` \case
                Left ExternalReadSurfaceDowngrade {} -> True
                _ -> False
            runStatement pool () consumerDependentExistsStmt `shouldReturn` True
            runStatement pool () consumerDependentRowsStmt `shouldReturn` [(1, 10), (2, 20)]

            let unsafe = unsafeIdentifierCatalog
            case validateProjectionCatalog unsafe of
              Failure _ -> pure ()
              Success _ -> expectationFailure "injection-shaped external read identity was accepted"
            runStatement pool ("app.counter" :: Text) relationExistsStmt `shouldReturn` True

      it "wraps a selective keyed implementation without granting the implementation itself" $ \connectionString ->
        withPool connectionString $ \pool ->
          Store.withStore (Store.defaultConnectionSettings connectionString) $ \store -> do
            runScript pool keyedFixtureSql
            catalog <- expectValid keyedCatalog
            register store catalog
            runScript pool activateV1Sql
            expectStore store (reconcileExternalReadContracts catalog) >>= shouldBeRight
            runScript pool grantKeyedReaderSql

            keyedRows <- runReaderTransaction pool (Tx.statement 2 keyedRowsStmt)
            expectUsage keyedRows `shouldReturn` [(2, 20)]
            privateRows <- runReaderTransaction pool (Tx.statement 2 privateRowsStmt)
            privateRows `shouldSatisfy` isSqlFailure

            plan <-
              runTransaction pool $ do
                Tx.sql "SET LOCAL enable_seqscan = off"
                Tx.statement () keyedPlanStmt
            Text.unlines plan `shouldSatisfy` Text.isInfixOf "Index Scan"

register :: Store.KirokuStore -> ValidatedProjectionCatalog -> IO ()
register store catalog = do
  result <- expectStore store (registerProjectionCatalog catalog)
  result `shouldSatisfy` \case Right _ -> True; Left _ -> False

onlyContract :: ValidatedProjectionCatalog -> IO ExternalReadContract
onlyContract catalog =
  case catalogExternalReadContracts catalog of
    [contract] -> pure contract
    contracts -> expectationFailure ("expected one contract, got " <> show contracts) >> error "unreachable"

catalogAtGeneration :: Int -> ProjectionCatalog
catalogAtGeneration generation =
  Catalog.bridgeCatalog
    { externalReadContracts =
        [ contract & #surfaceGeneration .~ generation
        | contract <- Catalog.bridgeCatalog ^. #externalReadContracts
        ]
    }

unsafeIdentifierCatalog :: ProjectionCatalog
unsafeIdentifierCatalog =
  Catalog.bridgeCatalog
    { externalReadContracts =
        [ contract
            & #readContractId
            .~ either (error . show) (\contractId -> contractId) (mkExternalReadContractId "reader;drop_schema_app")
        | contract <- Catalog.bridgeCatalog ^. #externalReadContracts
        ]
    }

keyedCatalog :: ProjectionCatalog
keyedCatalog =
  Catalog.bridgeCatalog
    { externalReadContracts = [keyedContract]
    }
  where
    keyedContract =
      case Catalog.bridgeCatalog ^. #externalReadContracts of
        [contract] ->
          KeyedExternalRead
            { readContractId = contract ^. #readContractId,
              contractVersion = contract ^. #contractVersion,
              queryModelId = contract ^. #queryModelId,
              arguments = [SqlFunctionArgument "counter_id" (QualifiedSqlType "pg_catalog" "int8")],
              resultContractType = contract ^. #resultContractType,
              privateImplementation = QualifiedFunction "app_private" "lookup_counter",
              privateImplementationVersion = 1,
              resultShapeHash = contract ^. #resultShapeHash,
              compatibleRevisions = contract ^. #compatibleRevisions,
              surfaceGeneration = contract ^. #surfaceGeneration,
              claimSite = contract ^. #claimSite
            }
        _ -> error "bridge catalog contract fixture drifted"

expectValid :: ProjectionCatalog -> IO ValidatedProjectionCatalog
expectValid catalog =
  case validateProjectionCatalog catalog of
    Failure diagnostics -> expectationFailure (show diagnostics) >> error "unreachable"
    Success validated -> pure validated

withPool :: Text -> (Pool.Pool -> IO a) -> IO a
withPool connectionString =
  bracket
    ( Pool.acquire
        $ PoolConfig.settings
          [ PoolConfig.staticConnectionSettings (ConnectionSettings.connectionString connectionString),
            PoolConfig.size 6
          ]
    )
    Pool.release

runScript :: Pool.Pool -> ByteString -> IO ()
runScript pool sql = expectUsage =<< Pool.use pool (Session.script (Text.Encoding.decodeUtf8 sql))

runTransaction :: Pool.Pool -> Tx.Transaction a -> IO a
runTransaction pool transaction =
  expectUsage
    =<< Pool.use
      pool
      (TxSessions.transactionNoRetry TxSessions.ReadCommitted TxSessions.Write transaction)

runReaderTransaction :: Pool.Pool -> Tx.Transaction a -> IO (Either Pool.UsageError a)
runReaderTransaction pool transaction =
  Pool.use
    pool
    ( TxSessions.transactionNoRetry
        TxSessions.ReadCommitted
        TxSessions.Write
        (Tx.sql "SET LOCAL ROLE external_reader" >> transaction)
    )

runStatement :: Pool.Pool -> params -> Statement params result -> IO result
runStatement pool params statement = expectUsage =<< Pool.use pool (Session.statement params statement)

expectUsage :: (Show error) => Either error value -> IO value
expectUsage = \case
  Left err -> expectationFailure ("database action failed: " <> show err) >> error "unreachable"
  Right value -> pure value

expectStore ::
  Store.KirokuStore ->
  Eff '[Store, Error StoreError, IOE] value ->
  IO value
expectStore store action =
  Store.runStoreIO store action >>= \case
    Left err -> expectationFailure (show err) >> error "unreachable"
    Right value -> pure value

shouldBeRight :: (Show error) => Either error value -> IO value
shouldBeRight = \case
  Left err -> expectationFailure (show err) >> error "unreachable"
  Right value -> pure value

hasSqlState :: (Show error) => String -> Either error value -> Bool
hasSqlState wanted = \case
  Left err -> wanted `isInfixOf` show err
  Right _ -> False

isSqlFailure :: Either error value -> Bool
isSqlFailure = \case Left _ -> True; Right _ -> False

waitForReader :: Pool.Pool -> Int -> IO ()
waitForReader _ 0 = expectationFailure "external reader did not enter its lock-holding transaction"
waitForReader pool remaining = do
  active <- runStatement pool () readerActiveStmt
  if active
    then pure ()
    else threadDelay 10_000 >> waitForReader pool (remaining - 1)

allRowsFixtureSql :: ByteString
allRowsFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE SCHEMA app_contract;
  CREATE TYPE app_contract.counter_row_v1 AS (id bigint, total bigint);
  CREATE TABLE app.counter (
    id bigint PRIMARY KEY,
    total bigint NOT NULL
  );
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    detail text NOT NULL
  );
  INSERT INTO app.counter (id, total) VALUES (1, 10), (2, 20);
  """

keyedFixtureSql :: ByteString
keyedFixtureSql =
  allRowsFixtureSql
    <> """
       CREATE SCHEMA app_private;
       CREATE FUNCTION app_private.lookup_counter(counter_id bigint)
       RETURNS SETOF app_contract.counter_row_v1
       LANGUAGE sql
       STABLE
       AS $lookup$
         SELECT ROW(counter.id, counter.total)::app_contract.counter_row_v1
         FROM app.counter AS counter
         WHERE counter.id = counter_id
       $lookup$;
       """

activateV1Sql :: ByteString
activateV1Sql =
  """
  UPDATE keiro.keiro_projection_rebuild_groups
  SET status = 'serving-versioned', serving_revision_id = 'counter-v1',
      serving_epoch = 0, reads_allowed = TRUE, writes_allowed = TRUE,
      active_run_id = NULL, updated_at = now()
  WHERE group_id = 'counter-group';
  """

beginOfflineSql :: ByteString
beginOfflineSql =
  """
  INSERT INTO keiro.keiro_projection_rebuild_runs
    (run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
     contract_fingerprint, runner_format, captured_head, page_size)
  SELECT 'external-offline', group_id, 'catalog-external', slice_fingerprint,
         'contract-external', 'keiro/projection-replay/v2', 0, 100
  FROM keiro.keiro_projection_rebuild_groups
  WHERE group_id = 'counter-group';

  UPDATE keiro.keiro_projection_rebuild_groups
  SET status = 'rebuilding', active_run_id = 'external-offline',
      serving_revision_id = NULL, serving_epoch = 0,
      reads_allowed = FALSE, writes_allowed = FALSE, updated_at = now()
  WHERE group_id = 'counter-group';
  """

restoreV1Sql :: ByteString
restoreV1Sql =
  activateV1Sql
    <> """
       DELETE FROM keiro.keiro_projection_rebuild_runs
       WHERE run_id = 'external-offline';
       """

beginOnlineCandidateSql :: ByteString
beginOnlineCandidateSql =
  """
  INSERT INTO keiro.keiro_projection_rebuild_runs
    (run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
     contract_fingerprint, runner_format, captured_head, page_size,
     rebuild_mode, candidate_revision_id, cutover_threshold,
     cutover_lock_timeout_ms, history_retention_lease_id,
     history_retention_lease_owner, history_retention_protected_through,
     history_retention_expires_at, history_retention_renewed_at)
  SELECT 'external-online', group_id, 'catalog-external', slice_fingerprint,
         'contract-external', 'keiro/versioned-rebuild/v2', 0, 100,
         'versioned', 'counter-v2', 10, 2000,
         '00000000-0000-0000-0000-000000000027'::uuid,
         'external-read-spec', 0, now() + interval '10 minutes', now()
  FROM keiro.keiro_projection_rebuild_groups
  WHERE group_id = 'counter-group';

  UPDATE keiro.keiro_projection_rebuild_groups
  SET status = 'rebuilding-versioned', active_run_id = 'external-online',
      serving_revision_id = 'counter-v1', reads_allowed = TRUE,
      writes_allowed = TRUE, updated_at = now()
  WHERE group_id = 'counter-group';
  """

compatibleCutoverSql :: ByteString
compatibleCutoverSql =
  """
  UPDATE app.counter SET total = total + 20;
  UPDATE keiro.keiro_projection_rebuild_runs
  SET status = 'promoted', history_retention_released_at = now(), updated_at = now()
  WHERE run_id = 'external-online';
  UPDATE keiro.keiro_projection_rebuild_groups
  SET status = 'serving-versioned', active_run_id = NULL,
      serving_revision_id = 'counter-v2', serving_epoch = serving_epoch + 1,
      reads_allowed = TRUE, writes_allowed = TRUE, completed_at = now(),
      updated_at = now()
  WHERE group_id = 'counter-group';
  """

corruptServingShapeSql :: ByteString
corruptServingShapeSql =
  """
  UPDATE keiro.keiro_external_read_contracts
  SET serving_shape_hash = 'wrong-shape'
  WHERE contract_id = 'counter_reader' AND contract_version = 1;
  """

grantReaderSql :: ByteString
grantReaderSql =
  """
  DO $role$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'external_reader') THEN
      CREATE ROLE external_reader NOLOGIN;
    END IF;
  END
  $role$;
  GRANT USAGE ON SCHEMA keiro_read TO external_reader;
  GRANT EXECUTE ON FUNCTION keiro_read.counter_reader_v1() TO external_reader;
  """

grantKeyedReaderSql :: ByteString
grantKeyedReaderSql =
  """
  DO $role$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'external_reader') THEN
      CREATE ROLE external_reader NOLOGIN;
    END IF;
  END
  $role$;
  GRANT USAGE ON SCHEMA keiro_read TO external_reader;
  GRANT EXECUTE ON FUNCTION keiro_read.counter_reader_v1(bigint) TO external_reader;
  """

consumerDependentSql :: ByteString
consumerDependentSql =
  """
  CREATE FUNCTION app.consumer_counter()
  RETURNS SETOF app_contract.counter_row_v1
  LANGUAGE sql
  AS $consumer$
    SELECT * FROM keiro_read.counter_reader_v1()
  $consumer$;
  """

allRowsStmt :: Statement () [(Int64, Int64)]
allRowsStmt =
  preparable
    "SELECT id, total FROM keiro_read.counter_reader_v1() ORDER BY id"
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

rawTargetStmt :: Statement () Int64
rawTargetStmt =
  preparable
    "SELECT count(*) FROM app.counter"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

rawBindingStmt :: Statement () Int64
rawBindingStmt =
  preparable
    "SELECT count(*) FROM keiro.external_read_counter_reader_v1_binding"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

unknownGuardStmt :: Statement () ()
unknownGuardStmt =
  preparable
    "SELECT keiro_read.guard_external_read_v1('unknown', 1)"
    E.noParams
    D.noResult

securityFactsStmt :: Statement () (Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool)
securityFactsStmt =
  preparable
    """
    SELECT wrapper.prosecdef,
           wrapper.proconfig @> ARRAY['search_path=pg_catalog']::text[],
           NOT has_function_privilege('public', wrapper.oid, 'EXECUTE'),
           pg_get_userbyid(wrapper.proowner) = current_user,
           guard.prosecdef,
           guard.proconfig @> ARRAY['search_path=pg_catalog']::text[],
           NOT has_function_privilege('public', guard.oid, 'EXECUTE'),
           pg_get_userbyid(guard.proowner) = current_user
    FROM pg_catalog.pg_proc AS wrapper
    JOIN pg_catalog.pg_namespace AS wrapper_ns ON wrapper_ns.oid = wrapper.pronamespace
    CROSS JOIN pg_catalog.pg_proc AS guard
    JOIN pg_catalog.pg_namespace AS guard_ns ON guard_ns.oid = guard.pronamespace
    WHERE wrapper_ns.nspname = 'keiro_read'
      AND wrapper.proname = 'counter_reader_v1'
      AND guard_ns.nspname = 'keiro_read'
      AND guard.proname = 'guard_external_read_v1'
    """
    E.noParams
    ( D.singleRow
        ( (,,,,,,,)
            <$> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
            <*> D.column (D.nonNullable D.bool)
        )
    )

readerActiveStmt :: Statement () Bool
readerActiveStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1 FROM pg_catalog.pg_stat_activity
      WHERE application_name = 'keiro-external-lock-reader'
        AND state = 'active'
    )
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

consumerDependentExistsStmt :: Statement () Bool
consumerDependentExistsStmt =
  preparable
    "SELECT pg_catalog.to_regprocedure('app.consumer_counter()') IS NOT NULL"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

consumerDependentRowsStmt :: Statement () [(Int64, Int64)]
consumerDependentRowsStmt =
  preparable
    "SELECT id, total FROM app.consumer_counter() ORDER BY id"
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

relationExistsStmt :: Statement Text Bool
relationExistsStmt =
  preparable
    "SELECT pg_catalog.to_regclass($1) IS NOT NULL"
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

keyedRowsStmt :: Statement Int64 [(Int64, Int64)]
keyedRowsStmt =
  preparable
    "SELECT id, total FROM keiro_read.counter_reader_v1($1)"
    (E.param (E.nonNullable E.int8))
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

privateRowsStmt :: Statement Int64 [(Int64, Int64)]
privateRowsStmt =
  preparable
    "SELECT id, total FROM app_private.lookup_counter($1)"
    (E.param (E.nonNullable E.int8))
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

keyedPlanStmt :: Statement () [Text]
keyedPlanStmt =
  preparable
    "EXPLAIN (COSTS OFF) SELECT ROW(counter.id, counter.total)::app_contract.counter_row_v1 FROM app.counter AS counter WHERE counter.id = 2"
    E.noParams
    (D.rowList (D.column (D.nonNullable D.text)))
