{-# LANGUAGE MultilineStrings #-}

module VersionedTargetPostgresSpec
  ( spec,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Keiro.Test.Postgres (Fixture, withFreshDatabase)
import Test.Hspec

spec :: Fixture -> Spec
spec fixture =
  describe "versioned target PostgreSQL mechanics" $
    around (withFreshDatabase fixture) $ do
      it "provisions an incompatible candidate transactionally and rolls failed provisioning back" $ \connectionString ->
        withPool connectionString $ \pool -> do
          runScript pool servingV1Sql

          candidateWasValid <-
            runTransaction pool $ do
              Tx.sql candidateV2Sql
              valid <- Tx.statement () candidateShapeStmt
              Tx.condemn
              pure valid
          candidateWasValid `shouldBe` True
          runStatement pool ("app.counter_g2" :: Text) relationExistsStmt `shouldReturn` False
          runStatement pool () servingValueStmt `shouldReturn` (1, 42)

          runTransaction pool (Tx.sql candidateV2Sql)
          runStatement pool ("app.counter_g2" :: Text) relationExistsStmt `shouldReturn` True
          runStatement pool () candidateShapeStmt `shouldReturn` True

      it "keeps OID identity explicit and demonstrates that dependent views follow the retired relation" $ \connectionString ->
        withPool connectionString $ \pool -> do
          runScript pool identitySwapFixtureSql
          (servingBefore, candidateBefore) <- runStatement pool () preSwapOidsStmt

          runTransaction pool (Tx.sql promoteIdentityTargetsSql)

          facts <- runStatement pool () promotedIdentityFactsStmt
          facts
            `shouldBe` ( candidateBefore,
                         servingBefore,
                         10,
                         12,
                         "app.counter_id_seq",
                         True,
                         True
                       )

      it "detects every deliberately unsupported clone feature without mutating the serving table" $ \connectionString ->
        withPool connectionString $ \pool -> do
          runScript pool cloneEligibilityFixtureSql
          runStatement pool () cloneRefusalsStmt
            `shouldReturn` "dependent-view,external-nextval,foreign-keys,inheritance,non-default-owner-or-acl,non-default-replica-identity,partitioning,publication,row-level-security,rules,triggers"
          runStatement pool () identitySequenceIsOwnedStmt `shouldReturn` True
          runStatement pool () servingValueStmt `shouldReturn` (1, 42)

      it "uses deterministic all-target order and one deadline that rolls a blocked cutover back" $ \connectionString ->
        withPool connectionString $ \pool -> do
          runScript pool lockFixtureSql
          sort unorderedLockNames
            `shouldBe` [ "app.serving_a",
                         "app.serving_b",
                         "app.staging_a",
                         "app.staging_b"
                       ]

          holderDone <- newEmptyMVar
          _ <-
            forkIO $
              Pool.use
                pool
                ( TxSessions.transactionNoRetry
                    TxSessions.ReadCommitted
                    TxSessions.Write
                    (Tx.sql holdServingReadLockSql)
                )
                >>= putMVar holderDone
          waitForOtherAccessShare pool 50

          timedOut <-
            Pool.use
              pool
              ( TxSessions.transactionNoRetry
                  TxSessions.ReadCommitted
                  TxSessions.Write
                  (Tx.sql blockedPromotionSql)
              )
          timedOut `shouldSatisfy` isLeft
          takeMVar holderDone `shouldReturn` Right ()
          runStatement pool () lockFixtureFactsStmt
            `shouldReturn` (1, 2, 11, 22, False, False)

      it "detects when a paused generation name is rebound to a different relation" $ \connectionString ->
        withPool connectionString $ \pool -> do
          runScript pool reboundFixtureSql
          originalOid <- runStatement pool ("app.counter_g2" :: Text) relationOidStmt
          runScript pool reboundReplacementSql
          replacementOid <- runStatement pool ("app.counter_g2" :: Text) relationOidStmt
          replacementOid `shouldNotBe` originalOid
          runStatement pool () servingValueStmt `shouldReturn` (1, 42)

withPool :: Text -> (Pool.Pool -> IO a) -> IO a
withPool connectionString =
  bracket
    ( Pool.acquire $
        PoolConfig.settings
          [ PoolConfig.staticConnectionSettings (ConnectionSettings.connectionString connectionString),
            PoolConfig.size 4
          ]
    )
    Pool.release

runScript :: Pool.Pool -> ByteString -> IO ()
runScript pool sql = expectUsage =<< Pool.use pool (Session.script (Text.decodeUtf8 sql))

runTransaction :: Pool.Pool -> Tx.Transaction a -> IO a
runTransaction pool transaction =
  expectUsage
    =<< Pool.use
      pool
      (TxSessions.transactionNoRetry TxSessions.ReadCommitted TxSessions.Write transaction)

runStatement :: Pool.Pool -> params -> Statement params result -> IO result
runStatement pool params statement =
  expectUsage =<< Pool.use pool (Session.statement params statement)

expectUsage :: (Show error) => Either error value -> IO value
expectUsage = \case
  Left err -> expectationFailure ("database action failed: " <> show err) >> error "unreachable"
  Right value -> pure value

waitForOtherAccessShare :: Pool.Pool -> Int -> IO ()
waitForOtherAccessShare _ 0 = expectationFailure "reader did not acquire ACCESS SHARE in time"
waitForOtherAccessShare pool remaining = do
  locked <- runStatement pool () otherAccessShareStmt
  if locked
    then pure ()
    else threadDelay 20_000 >> waitForOtherAccessShare pool (remaining - 1)

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

unorderedLockNames :: [Text]
unorderedLockNames =
  [ "app.staging_b",
    "app.serving_b",
    "app.staging_a",
    "app.serving_a"
  ]

servingV1Sql :: ByteString
servingV1Sql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (
    id bigint PRIMARY KEY,
    total bigint NOT NULL
  );
  INSERT INTO app.counter VALUES (1, 42);
  """

candidateV2Sql :: ByteString
candidateV2Sql =
  """
  CREATE TABLE app.counter_g2 (
    id bigint PRIMARY KEY,
    subtotal bigint NOT NULL,
    tax bigint NOT NULL CHECK (tax >= 0),
    total bigint GENERATED ALWAYS AS (subtotal + tax) STORED
  );
  INSERT INTO app.counter_g2 (id, subtotal, tax) VALUES (1, 40, 2);
  """

identitySwapFixtureSql :: ByteString
identitySwapFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (
    id bigint GENERATED BY DEFAULT AS IDENTITY,
    total bigint NOT NULL,
    CONSTRAINT counter_pkey PRIMARY KEY (id)
  );
  CREATE VIEW app.counter_v1_reader AS SELECT id, total FROM app.counter;
  INSERT INTO app.counter (total) VALUES (12);

  CREATE TABLE app.counter_g2 (
    id bigint GENERATED BY DEFAULT AS IDENTITY,
    subtotal bigint NOT NULL,
    tax bigint NOT NULL,
    total bigint GENERATED ALWAYS AS (subtotal + tax) STORED,
    CONSTRAINT counter_g2_pkey PRIMARY KEY (id),
    CONSTRAINT counter_g2_tax_nonnegative CHECK (tax >= 0)
  );
  CREATE INDEX counter_g2_subtotal_idx ON app.counter_g2 (subtotal);
  INSERT INTO app.counter_g2 (subtotal, tax) VALUES (7, 3);
  """

promoteIdentityTargetsSql :: ByteString
promoteIdentityTargetsSql =
  """
  LOCK TABLE app.counter, app.counter_g2 IN ACCESS EXCLUSIVE MODE;

  ALTER TABLE app.counter RENAME CONSTRAINT counter_pkey TO counter_g1_pkey;
  ALTER SEQUENCE app.counter_id_seq RENAME TO counter_g1_id_seq;
  ALTER TABLE app.counter RENAME TO counter_g1;

  ALTER TABLE app.counter_g2 RENAME CONSTRAINT counter_g2_pkey TO counter_pkey;
  ALTER TABLE app.counter_g2 RENAME CONSTRAINT counter_g2_tax_nonnegative TO counter_tax_nonnegative;
  ALTER INDEX app.counter_g2_subtotal_idx RENAME TO counter_subtotal_idx;
  ALTER SEQUENCE app.counter_g2_id_seq RENAME TO counter_id_seq;
  ALTER TABLE app.counter_g2 RENAME TO counter;
  """

cloneEligibilityFixtureSql :: ByteString
cloneEligibilityFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE ROLE clone_reader;
  CREATE ROLE clone_owner;

  CREATE TABLE app.counter (id bigint PRIMARY KEY, total bigint NOT NULL);
  INSERT INTO app.counter VALUES (1, 42);

  CREATE TABLE app.identity_target (id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY);
  CREATE TABLE app.serial_target (id bigserial PRIMARY KEY);

  CREATE TABLE app.fk_parent (id bigint PRIMARY KEY);
  CREATE TABLE app.fk_out (id bigint PRIMARY KEY, parent_id bigint REFERENCES app.fk_parent(id));
  CREATE TABLE app.fk_in (id bigint PRIMARY KEY);
  CREATE TABLE app.fk_ref (id bigint PRIMARY KEY, target_id bigint REFERENCES app.fk_in(id));

  CREATE TABLE app.trigger_target (id bigint PRIMARY KEY);
  CREATE FUNCTION app.clone_trigger_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
  CREATE TRIGGER clone_trigger BEFORE INSERT ON app.trigger_target FOR EACH ROW EXECUTE FUNCTION app.clone_trigger_fn();

  CREATE TABLE app.rule_target (id bigint PRIMARY KEY);
  CREATE RULE clone_rule AS ON INSERT TO app.rule_target DO ALSO NOTHING;

  CREATE TABLE app.rls_target (id bigint PRIMARY KEY);
  ALTER TABLE app.rls_target ENABLE ROW LEVEL SECURITY;
  CREATE POLICY clone_policy ON app.rls_target USING (true);

  CREATE TABLE app.partition_target (id bigint) PARTITION BY RANGE (id);
  CREATE TABLE app.partition_target_p0 PARTITION OF app.partition_target FOR VALUES FROM (0) TO (10);

  CREATE TABLE app.publication_target (id bigint PRIMARY KEY);
  CREATE PUBLICATION clone_publication FOR TABLE app.publication_target;

  CREATE TABLE app.acl_target (id bigint PRIMARY KEY);
  GRANT SELECT ON app.acl_target TO clone_reader;
  CREATE TABLE app.owner_target (id bigint PRIMARY KEY);
  ALTER TABLE app.owner_target OWNER TO clone_owner;

  CREATE TABLE app.replica_target (id bigint PRIMARY KEY);
  ALTER TABLE app.replica_target REPLICA IDENTITY FULL;

  CREATE TABLE app.inherit_parent (id bigint PRIMARY KEY);
  CREATE TABLE app.inherit_child () INHERITS (app.inherit_parent);

  CREATE TABLE app.dependent_target (id bigint PRIMARY KEY);
  CREATE VIEW app.dependent_reader AS SELECT id FROM app.dependent_target;
  """

lockFixtureSql :: ByteString
lockFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.serving_a (value bigint NOT NULL);
  CREATE TABLE app.serving_b (value bigint NOT NULL);
  CREATE TABLE app.staging_a (value bigint NOT NULL);
  CREATE TABLE app.staging_b (value bigint NOT NULL);
  INSERT INTO app.serving_a VALUES (1);
  INSERT INTO app.serving_b VALUES (2);
  INSERT INTO app.staging_a VALUES (11);
  INSERT INTO app.staging_b VALUES (22);
  """

holdServingReadLockSql :: ByteString
holdServingReadLockSql =
  """
  LOCK TABLE app.serving_a IN ACCESS SHARE MODE;
  SELECT pg_sleep(1);
  """

blockedPromotionSql :: ByteString
blockedPromotionSql =
  """
  SET LOCAL statement_timeout = '200ms';
  LOCK TABLE app.serving_a IN ACCESS EXCLUSIVE MODE;
  LOCK TABLE app.serving_b IN ACCESS EXCLUSIVE MODE;
  LOCK TABLE app.staging_a IN ACCESS EXCLUSIVE MODE;
  LOCK TABLE app.staging_b IN ACCESS EXCLUSIVE MODE;
  ALTER TABLE app.serving_a RENAME TO retired_a;
  ALTER TABLE app.staging_a RENAME TO serving_a;
  ALTER TABLE app.serving_b RENAME TO retired_b;
  ALTER TABLE app.staging_b RENAME TO serving_b;
  """

reboundFixtureSql :: ByteString
reboundFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (id bigint PRIMARY KEY, total bigint NOT NULL);
  INSERT INTO app.counter VALUES (1, 42);
  CREATE TABLE app.counter_g2 (id bigint PRIMARY KEY, subtotal bigint NOT NULL, tax bigint NOT NULL);
  """

reboundReplacementSql :: ByteString
reboundReplacementSql =
  """
  DROP TABLE app.counter_g2;
  CREATE TABLE app.counter_g2 (id bigint PRIMARY KEY, replacement_marker text NOT NULL);
  """

relationExistsStmt :: Statement Text Bool
relationExistsStmt =
  preparable
    "SELECT to_regclass($1) IS NOT NULL"
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

relationOidStmt :: Statement Text Int64
relationOidStmt =
  preparable
    "SELECT to_regclass($1)::oid::bigint"
    (E.param (E.nonNullable E.text))
    (D.singleRow int8Column)

servingValueStmt :: Statement () (Int64, Int64)
servingValueStmt =
  preparable
    "SELECT count(*)::bigint, sum(total)::bigint FROM app.counter"
    E.noParams
    (D.singleRow ((,) <$> int8Column <*> int8Column))

candidateShapeStmt :: Statement () Bool
candidateShapeStmt =
  preparable
    """
    SELECT
      count(*) = 4
      AND bool_or(attname = 'subtotal')
      AND bool_or(attname = 'tax')
      AND bool_or(attname = 'total' AND attgenerated = 's')
    FROM pg_attribute
    WHERE attrelid = 'app.counter_g2'::regclass
      AND attnum > 0
      AND NOT attisdropped
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

preSwapOidsStmt :: Statement () (Int64, Int64)
preSwapOidsStmt =
  preparable
    "SELECT 'app.counter'::regclass::oid::bigint, 'app.counter_g2'::regclass::oid::bigint"
    E.noParams
    (D.singleRow ((,) <$> int8Column <*> int8Column))

promotedIdentityFactsStmt :: Statement () (Int64, Int64, Int64, Int64, Text, Bool, Bool)
promotedIdentityFactsStmt =
  preparable
    """
    SELECT
      'app.counter'::regclass::oid::bigint,
      'app.counter_g1'::regclass::oid::bigint,
      (SELECT total FROM app.counter),
      (SELECT total FROM app.counter_v1_reader),
      pg_get_serial_sequence('app.counter', 'id'),
      to_regclass('app.counter_subtotal_idx') IS NOT NULL,
      EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'app.counter'::regclass
          AND conname = 'counter_tax_nonnegative'
      )
    """
    E.noParams
    ( D.singleRow
        ( (,,,,,,)
            <$> int8Column
            <*> int8Column
            <*> int8Column
            <*> int8Column
            <*> textColumn
            <*> boolColumn
            <*> boolColumn
        )
    )

cloneRefusalsStmt :: Statement () Text
cloneRefusalsStmt =
  preparable
    """
    WITH findings(feature) AS (
      SELECT 'external-nextval' WHERE EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = 'app.serial_target'::regclass
          AND pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%'
      )
      UNION ALL
      SELECT 'foreign-keys' WHERE
        EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE contype = 'f'
            AND conrelid = 'app.fk_out'::regclass
            AND confrelid = 'app.fk_parent'::regclass
        )
        AND EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE contype = 'f'
            AND conrelid = 'app.fk_ref'::regclass
            AND confrelid = 'app.fk_in'::regclass
        )
      UNION ALL
      SELECT 'triggers' WHERE EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'app.trigger_target'::regclass AND NOT tgisinternal
      )
      UNION ALL
      SELECT 'rules' WHERE EXISTS (
        SELECT 1 FROM pg_rewrite
        WHERE ev_class = 'app.rule_target'::regclass AND rulename <> '_RETURN'
      )
      UNION ALL
      SELECT 'row-level-security' WHERE EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'app.rls_target'::regclass AND relrowsecurity
      ) AND EXISTS (
        SELECT 1 FROM pg_policy WHERE polrelid = 'app.rls_target'::regclass
      )
      UNION ALL
      SELECT 'partitioning' WHERE EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'app.partition_target'::regclass AND relkind = 'p'
      )
      UNION ALL
      SELECT 'publication' WHERE EXISTS (
        SELECT 1 FROM pg_publication_rel
        WHERE prrelid = 'app.publication_target'::regclass
      )
      UNION ALL
      SELECT 'non-default-owner-or-acl' WHERE
        EXISTS (
          SELECT 1 FROM pg_class
          WHERE oid = 'app.acl_target'::regclass AND relacl IS NOT NULL
        )
        AND EXISTS (
          SELECT 1
          FROM pg_class c
          JOIN pg_roles r ON r.oid = c.relowner
          WHERE c.oid = 'app.owner_target'::regclass AND r.rolname = 'clone_owner'
        )
      UNION ALL
      SELECT 'non-default-replica-identity' WHERE EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'app.replica_target'::regclass AND relreplident = 'f'
      )
      UNION ALL
      SELECT 'inheritance' WHERE EXISTS (
        SELECT 1 FROM pg_inherits
        WHERE inhrelid = 'app.inherit_child'::regclass
          AND inhparent = 'app.inherit_parent'::regclass
      )
      UNION ALL
      SELECT 'dependent-view' WHERE EXISTS (
        SELECT 1
        FROM information_schema.view_table_usage
        WHERE view_schema = 'app'
          AND view_name = 'dependent_reader'
          AND table_schema = 'app'
          AND table_name = 'dependent_target'
      )
    )
    SELECT string_agg(feature, ',' ORDER BY feature) FROM findings
    """
    E.noParams
    (D.singleRow textColumn)

identitySequenceIsOwnedStmt :: Statement () Bool
identitySequenceIsOwnedStmt =
  preparable
    """
    SELECT
      pg_get_serial_sequence('app.identity_target', 'id') IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM pg_depend d
        WHERE d.objid = pg_get_serial_sequence('app.identity_target', 'id')::regclass
          AND d.refobjid = 'app.identity_target'::regclass
          AND d.deptype = 'i'
      )
    """
    E.noParams
    (D.singleRow boolColumn)

otherAccessShareStmt :: Statement () Bool
otherAccessShareStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM pg_locks
      WHERE relation = 'app.serving_a'::regclass
        AND mode = 'AccessShareLock'
        AND granted
        AND pid <> pg_backend_pid()
    )
    """
    E.noParams
    (D.singleRow boolColumn)

lockFixtureFactsStmt :: Statement () (Int64, Int64, Int64, Int64, Bool, Bool)
lockFixtureFactsStmt =
  preparable
    """
    SELECT
      (SELECT value FROM app.serving_a),
      (SELECT value FROM app.serving_b),
      (SELECT value FROM app.staging_a),
      (SELECT value FROM app.staging_b),
      to_regclass('app.retired_a') IS NOT NULL,
      to_regclass('app.retired_b') IS NOT NULL
    """
    E.noParams
    ( D.singleRow
        ( (,,,,,)
            <$> int8Column
            <*> int8Column
            <*> int8Column
            <*> int8Column
            <*> boolColumn
            <*> boolColumn
        )
    )

int8Column :: D.Row Int64
int8Column = D.column (D.nonNullable D.int8)

textColumn :: D.Row Text
textColumn = D.column (D.nonNullable D.text)

boolColumn :: D.Row Bool
boolColumn = D.column (D.nonNullable D.bool)
