{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.History.Codd (
    frameworkCoddHistoryMappings,
    frameworkCoddSourceConfig,
    keiroCoddHistoryMappings,
    keiroCoddManifestText,
    keiroCoddSourcePayloads,
    keiroLegacyMigrationNames,
) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.PostgreSQL.Migrate (
    Confirmation,
    ConnectionProvider,
    EvidenceRequirement (Evidence),
    HistoryMapping,
    PayloadRelation (SamePayload),
    historyMapping,
    migrationId,
 )
import Database.PostgreSQL.Migrate.History.Codd (
    CoddDefinitionError,
    CoddSourceConfig,
    coddEvidenceKey,
    coddSourceConfig,
    parseCoddManifest,
 )
import Keiro.Migrations.Internal.Definition (embeddedMigrationEntries)
import Keiro.Migrations.Internal.EmbedFile (embedTextFile)
import Kiroku.Store.Migrations.History.Codd qualified as Kiroku

keiroLegacyMigrationNames :: NonEmpty FilePath
keiroLegacyMigrationNames =
    "2026-05-17-13-58-15-keiro-bootstrap.sql"
        :| [ "2026-05-19-12-55-02-keiro-outbox.sql"
           , "2026-05-19-13-05-23-keiro-inbox.sql"
           , "2026-06-03-05-14-28-keiro-timer-recovery.sql"
           , "2026-06-03-16-10-05-keiro-workflow-steps.sql"
           , "2026-06-03-18-19-41-keiro-awakeables.sql"
           , "2026-06-03-19-49-23-keiro-workflow-children.sql"
           , "2026-06-04-02-12-28-keiro-workflow-generation.sql"
           , "2026-06-04-03-53-34-keiro-subscription-shards.sql"
           , "2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql"
           , "2026-06-15-15-07-25-keiro-workflows-instances.sql"
           , "2026-06-15-17-53-48-keiro-workflow-gc-index.sql"
           , "2026-06-15-18-01-33-keiro-workflows-wake-after.sql"
           , "2026-06-15-21-49-37-keiro-projection-dedup.sql"
           , "2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql"
           , "2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql"
           ]

keiroCoddHistoryMappings :: NonEmpty HistoryMapping
keiroCoddHistoryMappings =
    zipWithNonEmpty mapping keiroLegacyMigrationNames nativeMigrationNames
  where
    mapping sourceFilename targetName =
        historyMapping
            (definitionInvariant (migrationId "keiro" targetName))
            (Evidence sourceKey)
            (SamePayload sourceKey)
      where
        sourceKey = definitionInvariant (first show (coddEvidenceKey sourceFilename))

frameworkCoddHistoryMappings :: NonEmpty HistoryMapping
frameworkCoddHistoryMappings =
    Kiroku.kirokuCoddHistoryMappings <> keiroCoddHistoryMappings

frameworkCoddSourceConfig ::
    ConnectionProvider ->
    Bool ->
    Text ->
    Confirmation ->
    Either CoddDefinitionError CoddSourceConfig
frameworkCoddSourceConfig sourceProvider strictSource reason confirmation =
    coddSourceConfig
        sourceProvider
        (Kiroku.kirokuLegacyMigrationNames <> keiroLegacyMigrationNames)
        strictSource
        (Kiroku.kirokuCoddSourcePayloads <> keiroCoddSourcePayloads)
        (Just combinedManifest)
        reason
        confirmation
  where
    combinedManifest =
        definitionInvariant
            (parseCoddManifest (Kiroku.kirokuCoddManifestText <> keiroCoddManifestText))

nativeMigrationNames :: NonEmpty Text
nativeMigrationNames =
    "0001-keiro-bootstrap"
        :| [ "0002-keiro-outbox"
           , "0003-keiro-inbox"
           , "0004-keiro-timer-recovery"
           , "0005-keiro-workflow-steps"
           , "0006-keiro-awakeables"
           , "0007-keiro-workflow-children"
           , "0008-keiro-workflow-generation"
           , "0009-keiro-subscription-shards"
           , "0010-keiro-messaging-crash-recovery"
           , "0011-keiro-workflows-instances"
           , "0012-keiro-workflow-gc-index"
           , "0013-keiro-workflows-wake-after"
           , "0014-keiro-projection-dedup"
           , "0015-keiro-outbox-claim-order-index"
           , "0016-keiro-inbox-drop-received-idx"
           ]

keiroCoddSourcePayloads :: Map.Map FilePath ByteString
keiroCoddSourcePayloads =
    Map.fromList
        (zip (toList keiroLegacyMigrationNames) (snd <$> toList embeddedMigrationEntries))

keiroCoddManifestText :: Text
keiroCoddManifestText = $(embedTextFile "migrations.lock")

zipWithNonEmpty :: (a -> b -> c) -> NonEmpty a -> NonEmpty b -> NonEmpty c
zipWithNonEmpty combine (firstA :| restA) (firstB :| restB) =
    combine firstA firstB :| zipWith combine restA restB

definitionInvariant :: (Show error) => Either error value -> value
definitionInvariant = either (error . ("invalid checked-in Keiro migration definition: " <>) . show) id
