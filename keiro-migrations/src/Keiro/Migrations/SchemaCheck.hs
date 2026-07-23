{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.SchemaCheck (
    SchemaDrift (..),
    compareSchemaSnapshot,
    expectedSchemaSnapshot,
    renderSchemaDrift,
    snapshotSchema,
    verifyExpectedSchema,
) where

import Control.Exception (finally)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
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
        { driftKey :: Text
        , expectedDefinition :: Text
        , actualDefinition :: Text
        }
    deriving stock (Eq, Show)

-- | Compare canonical snapshots by their @kind<TAB>name@ object identity.
compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]
compareSchemaSnapshot expected actual =
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
            (Nothing, Just (actualLine, _)) ->
                Just (UnexpectedObject actualLine)
            (Just (_, expectedValue), Just (_, actualValue))
                | expectedValue /= actualValue ->
                    Just
                        ChangedObject
                            { driftKey = key
                            , expectedDefinition = expectedValue
                            , actualDefinition = actualValue
                            }
            _ -> Nothing

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
        ChangedObject{driftKey, expectedDefinition, actualDefinition} ->
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

-- | Read a sorted canonical snapshot of tables, columns, constraints, and indexes.
snapshotSchema :: Text -> Session Text
snapshotSchema schema =
    Text.unlines <$> Session.statement schema schemaSnapshotStatement

-- | PostgreSQL 18 snapshot generated from the complete embedded migration plan.
expectedSchemaSnapshot :: Text
expectedSchemaSnapshot =
    $(embedTextFile "expected-schema/native/keiro-v18.txt")

-- | Compare the live @keiro@ schema with the embedded PostgreSQL 18 snapshot.
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
                Connection.use connection liveSnapshotSession
                    `finally` Connection.release connection
            pure $ case result of
                Left sessionError -> Left (DatabaseSessionFailed sessionError)
                Right (Left migrationError) -> Left migrationError
                Right (Right actual) ->
                    Right (compareSchemaSnapshot expectedSchemaSnapshot actual)
  where
    liveSnapshotSession :: Session (Either MigrationError Text)
    liveSnapshotSession = do
        serverVersionNumber <- Session.statement () serverVersionStatement
        let majorVersion = fromIntegral serverVersionNumber `div` 10000
        if majorVersion == (18 :: Int)
            then Right <$> snapshotSchema "keiro"
            else pure (Left (UnsupportedPostgresVersion majorVersion))

snapshotObjects :: Text -> Map Text (Text, Text)
snapshotObjects =
    Map.fromList . mapMaybe parseSnapshotLine . Text.lines
  where
    parseSnapshotLine line =
        case Text.splitOn "\t" line of
            kind : name : definitionParts ->
                Just
                    ( kind <> "\t" <> name
                    , (line, Text.intercalate "\t" definitionParts)
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
        """
        SELECT line FROM (
          SELECT 'table' || E'\t' || c.relname || E'\t' || 'kind=r' AS line
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind = 'r'
          UNION ALL
          SELECT 'column' || E'\t' || c.relname || '.' || a.attname || E'\t'
                 || format_type(a.atttypid, a.atttypmod)
                 || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END
                 || coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '')
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d
              ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE n.nspname = $1
              AND c.relkind = 'r'
              AND a.attnum > 0
              AND NOT a.attisdropped
          UNION ALL
          SELECT 'constraint' || E'\t' || rel.relname || '.' || con.conname || E'\t'
                 || pg_get_constraintdef(con.oid)
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            WHERE n.nspname = $1
          UNION ALL
          SELECT 'index' || E'\t' || ci.relname || E'\t'
                 || pg_get_indexdef(i.indexrelid)
            FROM pg_index i
            JOIN pg_class ci ON ci.oid = i.indexrelid
            JOIN pg_class ct ON ct.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = ct.relnamespace
            WHERE n.nspname = $1
        ) snapshot
        ORDER BY line COLLATE "C"
        """
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

serverVersionStatement :: Statement () Int32
serverVersionStatement =
    Statement.preparable
        "SELECT current_setting('server_version_num')::integer"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
