{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.SchemaCheck
  ( SchemaDrift (..),
    compareSchemaSnapshot,
    compareSchemaSnapshotWithManaged,
    managedObjectSnapshotKeys,
    expectedSchemaSnapshot,
    renderSchemaDrift,
    snapshotSchema,
    verifyExpectedSchema,
    verifyExpectedSchemaSession,
  )
where

import Control.Exception (finally)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate (MigrationError (..))
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Keiro.Migrations.Internal.EmbedFile (embedTextFile)

-- | One named difference between the expected and live schema snapshots.
data SchemaDrift
  = MissingObject Text
  | UnexpectedObject Text
  | ChangedObject
      { driftKey :: Text,
        expectedDefinition :: Text,
        actualDefinition :: Text
      }
  deriving stock (Eq, Show)

-- | Compare canonical snapshots by their @kind<TAB>name@ object identity. A live
-- object whose key is in the managed set is Keiro's own runtime object and is
-- never reported as unexpected; it is still compared when the expected snapshot
-- also lists it.
compareSchemaSnapshotWithManaged :: Set Text -> Text -> Text -> [SchemaDrift]
compareSchemaSnapshotWithManaged managed expected actual =
  mapMaybe driftFor allKeys
  where
    expectedObjects = snapshotObjects expected
    actualObjects = snapshotObjects actual
    allKeys =
      Set.toAscList
        (Map.keysSet expectedObjects `Set.union` Map.keysSet actualObjects)

    driftFor key =
      case (Map.lookup key expectedObjects, Map.lookup key actualObjects) of
        (Just (expectedLine, _), Nothing) ->
          Just (MissingObject expectedLine)
        (Nothing, Just (actualLine, _))
          | Set.member key managed -> Nothing
          | otherwise -> Just (UnexpectedObject actualLine)
        (Just (_, expectedValue), Just (_, actualValue))
          | expectedValue /= actualValue ->
              Just
                ChangedObject
                  { driftKey = key,
                    expectedDefinition = expectedValue,
                    actualDefinition = actualValue
                  }
        _ -> Nothing

-- | Compare snapshots without allowing any runtime-managed additions.
compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]
compareSchemaSnapshot = compareSchemaSnapshotWithManaged Set.empty

-- | Render a drift as one operator-facing line with the affected object name.
renderSchemaDrift :: SchemaDrift -> Text
renderSchemaDrift drift =
  case drift of
    MissingObject line ->
      let (kind, name, definition) = splitSnapshotLine line
       in "schema drift: missing "
            <> kind
            <> " "
            <> name
            <> " (expected: "
            <> definition
            <> ")"
    UnexpectedObject line ->
      let (kind, name, definition) = splitSnapshotLine line
       in "schema drift: unexpected "
            <> kind
            <> " "
            <> name
            <> " (actual: "
            <> definition
            <> ")"
    ChangedObject {driftKey, expectedDefinition, actualDefinition} ->
      let (kind, name) = splitSnapshotKey driftKey
       in "schema drift: changed "
            <> kind
            <> " "
            <> name
            <> " (expected: "
            <> expectedDefinition
            <> "; actual: "
            <> actualDefinition
            <> ")"

-- | Read a sorted canonical snapshot of tables, columns, constraints, indexes,
-- and ordered view column signatures in one schema.
snapshotSchema :: Text -> Session Text
snapshotSchema schema =
  Text.unlines <$> Session.statement schema schemaSnapshotStatement

-- | PostgreSQL 18 snapshot regenerated through migration 0034.
expectedSchemaSnapshot :: Text
expectedSchemaSnapshot =
  $(embedTextFile "expected-schema/native/keiro-v18.txt")

-- | Compare the live @keiro@ and @keiro_read@ schemas with the embedded
-- PostgreSQL 18 snapshot. Runtime binding views recorded as Keiro-managed are
-- allowed additions when the role has registry table SELECT and schema USAGE;
-- otherwise verification keeps its catalog-only comparison. Missing or changed
-- migration objects remain drift. Registry identity does not validate a
-- runtime-only view's definition or definition_hash.
verifyExpectedSchema ::
  Settings.Settings ->
  IO (Either MigrationError [SchemaDrift])
verifyExpectedSchema settings = do
  acquired <- Connection.acquire settings
  case acquired of
    Left connectionError ->
      pure (Left (ConnectionAcquisitionFailed connectionError))
    Right connection -> do
      result <-
        Connection.use connection verifyExpectedSchemaSession
          `finally` Connection.release connection
      pure $ case result of
        Left sessionError -> Left (DatabaseSessionFailed sessionError)
        Right result -> result

-- | Verify the live schema on an existing connection or pool. This retains the
-- CLI's PostgreSQL version check and runtime-managed object handling.
verifyExpectedSchemaSession :: Session (Either MigrationError [SchemaDrift])
verifyExpectedSchemaSession = do
  serverVersionNumber <- Session.statement () serverVersionStatement
  let majorVersion = fromIntegral serverVersionNumber `div` 10000
  if majorVersion == (18 :: Int)
    then do
      readable <- Session.statement () registryReadableStatement
      -- Compare every live catalog observation in PostgreSQL. Returning only
      -- differences avoids rebuilding two complete Text/Map snapshots per poll.
      -- No live result is cached, and registry visibility stays role-dependent.
      Right <$> Session.statement () (if readable then managedSchemaDriftStatement else unmanagedSchemaDriftStatement)
    else pure (Left (UnsupportedPostgresVersion majorVersion))

-- | Snapshot keys of the objects Keiro's runtime created and recorded in
-- @keiro.keiro_managed_read_objects@ with @managed_by = 'keiro'@. Every state
-- counts: retirement marks a managed object retired without dropping it. Rows
-- whose kind has no snapshot line (functions and types) map to nothing. When
-- the registry table does not exist, or the connected role lacks table @SELECT@
-- or schema @USAGE@, the set is empty and verification reports every live object
-- as before.
managedObjectSnapshotKeys :: Session (Set Text)
managedObjectSnapshotKeys = do
  readable <- Session.statement () registryReadableStatement
  if readable
    then Set.fromList . mapMaybe snapshotKey <$> Session.statement () managedObjectsStatement
    else pure Set.empty
  where
    snapshotKey (schema, name, kind)
      | kind == "binding-view" = Just ("view\t" <> schema <> "." <> name)
      | otherwise = Nothing

-- | True only when @keiro.keiro_managed_read_objects@ is a table the connected
-- role may read. Resolving the relation through @pg_class@ avoids the error
-- that the text form of @has_table_privilege@ raises for a missing relation.
registryReadableStatement :: Statement () Bool
registryReadableStatement =
  Statement.preparable
    """
    SELECT coalesce(
      ( SELECT pg_catalog.has_table_privilege(c.oid, 'SELECT')
                 AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'keiro'
          AND c.relname = 'keiro_managed_read_objects'
          AND c.relkind = 'r' ),
      false)
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

managedObjectsStatement :: Statement () [(Text, Text, Text)]
managedObjectsStatement =
  Statement.preparable
    """
    SELECT object_schema, object_name, object_kind
    FROM keiro.keiro_managed_read_objects
    WHERE managed_by = 'keiro'
    """
    Encoders.noParams
    ( Decoders.rowList
        ( (,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

snapshotObjects :: Text -> Map Text (Text, Text)
snapshotObjects =
  Map.fromList . mapMaybe parseSnapshotLine . Text.lines
  where
    parseSnapshotLine line =
      case Text.splitOn "\t" line of
        kind : name : definitionParts ->
          Just
            ( kind <> "\t" <> name,
              (line, Text.intercalate "\t" definitionParts)
            )
        _ -> Nothing

splitSnapshotLine :: Text -> (Text, Text, Text)
splitSnapshotLine line =
  case Text.splitOn "\t" line of
    kind : name : definitionParts ->
      (kind, name, Text.intercalate "\t" definitionParts)
    _ -> ("object", line, line)

splitSnapshotKey :: Text -> (Text, Text)
splitSnapshotKey key =
  case Text.splitOn "\t" key of
    [kind, name] -> (kind, name)
    _ -> ("object", key)

schemaSnapshotStatement :: Statement Text [Text]
schemaSnapshotStatement =
  Statement.preparable
    schemaSnapshotSql
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

schemaSnapshotSql :: Text
schemaSnapshotSql =
  """
  WITH configured AS MATERIALIZED (
    SELECT set_config('search_path', 'pg_catalog', true) AS search_path
  )
  SELECT line
  FROM configured
  CROSS JOIN LATERAL (
    SELECT 'table' || E'\t' || c.relname || E'\t' || 'kind=r' AS line
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1
        AND c.relkind = 'r'
        AND configured.search_path = 'pg_catalog'
    UNION ALL
    SELECT 'column' || E'\t' || c.relname || '.' || a.attname || E'\t'
           || format_type(a.atttypid, a.atttypmod)
           || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END
           -- JSON quoting keeps a multiline generated expression on one snapshot line.
           || CASE a.attgenerated
                WHEN 's' THEN ' generated always as ' || to_json(pg_get_expr(d.adbin, d.adrelid))::text || ' stored'
                WHEN 'v' THEN ' generated always as ' || to_json(pg_get_expr(d.adbin, d.adrelid))::text || ' virtual'
                ELSE coalesce(' default ' || replace(replace(replace(pg_get_expr(d.adbin, d.adrelid),
                       chr(92), chr(92) || chr(92)), chr(10), chr(92) || 'n'), chr(13), chr(92) || 'r'), '')
              END
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_attrdef d
        ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE n.nspname = $1
        AND c.relkind = 'r'
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND configured.search_path = 'pg_catalog'
    UNION ALL
    SELECT 'constraint' || E'\t' || rel.relname || '.' || con.conname || E'\t'
           || pg_get_constraintdef(con.oid)
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = rel.relnamespace
      WHERE n.nspname = $1
        AND configured.search_path = 'pg_catalog'
    UNION ALL
    SELECT 'index' || E'\t' || ci.relname || E'\t'
           || pg_get_indexdef(i.indexrelid)
      FROM pg_index i
      JOIN pg_class ci ON ci.oid = i.indexrelid
      JOIN pg_class ct ON ct.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = ct.relnamespace
      WHERE n.nspname = $1
        AND configured.search_path = 'pg_catalog'
    UNION ALL
    SELECT 'view' || E'\t' || n.nspname || '.' || c.relname || E'\t'
           || 'columns='
           || string_agg(
                a.attnum::text || ':' || a.attname || ' '
                  || format_type(a.atttypid, a.atttypmod),
                ',' ORDER BY a.attnum
              ) AS line
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
      WHERE n.nspname = $1
        AND c.relkind = 'v'
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND configured.search_path = 'pg_catalog'
      GROUP BY n.nspname, c.relname
  ) snapshot
  ORDER BY line COLLATE "C"
  """

-- These two prepared statements embed only the immutable expected snapshot.
-- Their SQL is constructed once, not serialized as a large parameter per poll.
managedSchemaDriftStatement :: Statement () [SchemaDrift]
{-# NOINLINE managedSchemaDriftStatement #-}
managedSchemaDriftStatement = schemaDriftStatement managedKeysSql
  where
    managedKeysSql =
      "SELECT ('view' || E'\\t' || object_schema || '.' || object_name) COLLATE \"C\" AS key "
        <> "FROM keiro.keiro_managed_read_objects WHERE managed_by = 'keiro' AND object_kind = 'binding-view'"

unmanagedSchemaDriftStatement :: Statement () [SchemaDrift]
{-# NOINLINE unmanagedSchemaDriftStatement #-}
unmanagedSchemaDriftStatement = schemaDriftStatement "SELECT NULL::text COLLATE \"C\" AS key WHERE false"

schemaDriftStatement :: Text -> Statement () [SchemaDrift]
schemaDriftStatement managedSql = Statement.preparable sql Encoders.noParams decoder
  where
    -- E literals preserve quotes, backslashes and embedded control characters
    -- independently of standard_conforming_strings. No runtime input enters SQL.
    literal value = "E'" <> Text.replace "'" "''" (Text.replace "\\" "\\\\" value) <> "'"
    expectedRows =
      Text.intercalate "," ["(" <> Text.intercalate "," (map literal [key, line, definition]) <> ")" | (key, (line, definition)) <- Map.toAscList (snapshotObjects expectedSchemaSnapshot)]
    sql =
      "WITH live_lines AS MATERIALIZED (SELECT schemas.priority, observed.line FROM "
        <> "(VALUES ('keiro'::text,1),('keiro_read'::text,2)) AS schemas(name,priority) CROSS JOIN LATERAL ("
        <> Text.replace "$1" "schemas.name" schemaSnapshotSql
        <> ") AS observed), actual_keys AS (SELECT priority,line COLLATE \"C\" AS line, "
        <> "(split_part(line,E'\\t',1)||E'\\t'||split_part(line,E'\\t',2)) COLLATE \"C\" AS key FROM live_lines), "
        -- Match Map.fromList over the two sorted snapshots: the public schema
        -- wins duplicate keys, then the final C-sorted line within that schema.
        <> "actual AS (SELECT DISTINCT ON (key) key,line,substring(line FROM length(key)+2) COLLATE \"C\" AS definition "
        <> "FROM actual_keys ORDER BY key,priority DESC,line DESC), "
        <> "expected AS (SELECT key COLLATE \"C\" AS key,line,definition COLLATE \"C\" AS definition FROM (VALUES "
        <> expectedRows
        <> ") AS embedded(key,line,definition)), managed AS ("
        <> managedSql
        <> ") SELECT coalesce(e.key,a.key),e.line,a.line,e.definition,a.definition FROM expected e FULL JOIN actual a USING(key) "
        <> "WHERE a.key IS NULL OR (e.key IS NULL AND NOT EXISTS (SELECT 1 FROM managed m WHERE m.key=a.key)) "
        <> "OR (e.key IS NOT NULL AND a.key IS NOT NULL AND e.definition IS DISTINCT FROM a.definition) ORDER BY coalesce(e.key,a.key) COLLATE \"C\""
    decoder = Decoders.rowList (toDrift <$> required <*> optional <*> optional <*> optional <*> optional)
    required = Decoders.column (Decoders.nonNullable Decoders.text)
    optional = Decoders.column (Decoders.nullable Decoders.text)
    toDrift _ (Just line) Nothing _ _ = MissingObject line
    toDrift _ Nothing (Just line) _ _ = UnexpectedObject line
    toDrift key (Just _) (Just _) (Just expected) (Just actual) = ChangedObject key expected actual
    toDrift _ _ _ _ _ = error "schema comparison returned an impossible null combination"

serverVersionStatement :: Statement () Int32
serverVersionStatement =
  Statement.preparable
    "SELECT current_setting('server_version_num')::integer"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
