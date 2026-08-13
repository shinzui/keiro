-- | Operational adapters for Keiro's advisory snapshot cache.
--
-- Inspection and deletion use the public snapshot storage operations added to
-- the owning Keiro library, preserving ADR 3 and ADR 28.
module Keiro.Ops.Snapshot
  ( Command (..),
    ExpectedDiscriminators (..),
    PreflightEvidence (..),
    commandParser,
    isMutation,
    preflightFor,
    runCommand,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (nonNegativeIntReader, nonNegativeReader)
import Keiro.Ops.Render
import Keiro.Snapshot.Schema
import Keiro.Workflow.Snapshot (workflowStateCodecVersion, workflowStateShapeHash)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (getStream)
import Kiroku.Store.Types (StreamInfo (..), StreamName (..), StreamVersion (..))
import Options.Applicative hiding (action, info, value)
import Options.Applicative qualified as Opt

data ExpectedDiscriminators = ExpectedDiscriminators
  { stateCodecVersion :: !Int,
    regfileShapeHash :: !Text,
    stateShapeHash :: !Text
  }
  deriving stock (Eq, Show)

data Command
  = Show !Text
  | Delete !Text
  | TruncationPreflight !Text !StreamVersion !(Maybe ExpectedDiscriminators)
  deriving stock (Eq, Show)

data PreflightEvidence = PreflightEvidence
  { streamName :: !Text,
    truncateBefore :: !StreamVersion,
    requiredSnapshotVersion :: !StreamVersion,
    expectedDiscriminators :: !(Maybe ExpectedDiscriminators),
    snapshotRow :: !(Maybe SnapshotRow),
    versionCovered :: !Bool,
    discriminatorsMatch :: !Bool,
    passed :: !Bool,
    reason :: !Text
  }
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "show" (Opt.info (Show <$> streamOption) (progDesc "Inspect the advisory snapshot row for a stream"))
        <> command "delete" (Opt.info (Delete <$> streamOption) (progDesc "Preview or delete a stream's advisory snapshot"))
        <> command "truncation-preflight" (Opt.info preflightParser (progDesc "Check snapshot coverage before moving a Kiroku truncate marker"))
    )
  where
    preflightParser =
      TruncationPreflight
        <$> streamOption
        <*> (StreamVersion <$> option (nonNegativeReader "expected a non-negative stream version") (long "before" <> metavar "VERSION" <> help "Proposed Kiroku truncate-before version"))
        <*> optional expectedParser
    expectedParser =
      ExpectedDiscriminators
        <$> option nonNegativeIntReader (long "state-codec-version" <> metavar "N" <> help "Application's current state codec version")
        <*> textOption "regfile-shape-hash" "HASH" "Application's current register-layout hash"
        <*> textOption "state-shape-hash" "HASH" "Application's current control-state/fold hash"

streamOption :: Parser Text
streamOption = textOption "stream" "NAME" "Kiroku stream name"

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText = Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

isMutation :: Command -> Bool
isMutation = \case
  Show {} -> False
  Delete {} -> True
  TruncationPreflight {} -> False

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Show name -> runAction env (lookupByName name) (Succeeded . snapshotResult name)
  Delete name -> runDelete env name
  TruncationPreflight name before suppliedExpected ->
    runAction env (preflightFor name before suppliedExpected) (Succeeded . preflightResult)

lookupByName :: (Store :> es) => Text -> Eff es (Maybe SnapshotRow)
lookupByName name = do
  stream <- getStream (StreamName name)
  case stream of
    Nothing -> pure Nothing
    Just info -> lookupSnapshotRow info.id

runDelete :: OpsEnv -> Text -> IO OpsOutcome
runDelete env name
  | not env.force =
      runAction env (lookupByName name) $ \row ->
        PreviewRequired
          (snapshotDeleteResult True name row False)
          (forceInvocation env ["snapshot", "delete", "--stream", name])
  | otherwise =
      runAction env action $ \(row, deleted) ->
        Succeeded (snapshotDeleteResult False name row deleted)
  where
    action = do
      stream <- getStream (StreamName name)
      case stream of
        Nothing -> pure (Nothing, False)
        Just info -> do
          row <- lookupSnapshotRow info.id
          deleted <- deleteSnapshotRow info.id
          pure (row, deleted)

-- | Evaluate the database-only part of the truncation guard. Workflow journal
-- streams have public fixed discriminators and are recognized automatically.
-- Aggregate streams require the application-owned current discriminator tuple
-- to be supplied explicitly; a standalone binary cannot infer compiled codecs.
preflightFor ::
  (Store :> es) =>
  Text ->
  StreamVersion ->
  Maybe ExpectedDiscriminators ->
  Eff es PreflightEvidence
preflightFor name before suppliedExpected = do
  row <- lookupByName name
  let expected = suppliedExpected <|> workflowExpected name
      required = predecessor before
      covered = maybe False ((>= required) . (.streamVersion)) row
      matches = case (expected, row) of
        (Just wanted, Just found) -> discriminatorMatches wanted found
        _ -> False
      (ok, explanation) = case (row, expected, covered, matches) of
        (Nothing, _, _, _) -> (False, "no snapshot row exists")
        (Just _, Nothing, _, _) -> (False, "current codec discriminators are required for a non-workflow stream")
        (Just _, Just _, False, _) -> (False, "snapshot version does not cover the proposed truncation boundary")
        (Just _, Just _, True, False) -> (False, "snapshot discriminators do not match the expected current codec")
        (Just _, Just _, True, True) -> (True, "snapshot covers the boundary and matches the expected codec")
  pure
    PreflightEvidence
      { streamName = name,
        truncateBefore = before,
        requiredSnapshotVersion = required,
        expectedDiscriminators = expected,
        snapshotRow = row,
        versionCovered = covered,
        discriminatorsMatch = matches,
        passed = ok,
        reason = explanation
      }

workflowExpected :: Text -> Maybe ExpectedDiscriminators
workflowExpected name
  | "wf:" `Text.isPrefixOf` name =
      Just
        ExpectedDiscriminators
          { stateCodecVersion = workflowStateCodecVersion,
            regfileShapeHash = workflowStateShapeHash,
            stateShapeHash = workflowStateShapeHash
          }
  | otherwise = Nothing

predecessor :: StreamVersion -> StreamVersion
predecessor (StreamVersion before) = StreamVersion (max 0 (before - 1))

discriminatorMatches :: ExpectedDiscriminators -> SnapshotRow -> Bool
discriminatorMatches expected row =
  expected.stateCodecVersion == row.stateCodecVersion
    && expected.regfileShapeHash == row.regfileShapeHash
    && expected.stateShapeHash == row.stateShapeHash

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] a -> (a -> OpsOutcome) -> IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

snapshotResult :: Text -> Maybe SnapshotRow -> OpsResult
snapshotResult name row =
  OpsResult
    { headers = ["stream", "snapshot_version", "state_codec_version", "regfile_shape_hash", "state_shape_hash", "state_bytes", "updated_at"],
      rows = maybe [] (pure . snapshotRowText name) row,
      jsonValue = maybe Aeson.Null (snapshotJson name) row
    }

snapshotRowText :: Text -> SnapshotRow -> [Text]
snapshotRowText name row =
  [ name,
    versionText row.streamVersion,
    showText row.stateCodecVersion,
    row.regfileShapeHash,
    row.stateShapeHash,
    showText (LazyByteString.length (Aeson.encode row.state)),
    showText row.updatedAt
  ]

snapshotJson :: Text -> SnapshotRow -> Value
snapshotJson name row =
  object
    [ "stream" .= name,
      "stream_version" .= versionInt row.streamVersion,
      "state" .= row.state,
      "state_codec_version" .= row.stateCodecVersion,
      "regfile_shape_hash" .= row.regfileShapeHash,
      "state_shape_hash" .= row.stateShapeHash,
      "state_bytes" .= LazyByteString.length (Aeson.encode row.state),
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt
    ]

snapshotDeleteResult :: Bool -> Text -> Maybe SnapshotRow -> Bool -> OpsResult
snapshotDeleteResult preview name row deleted =
  OpsResult
    { headers = ["stream", "snapshot_version", "disposition"],
      rows = [[name, maybe "" (versionText . (.streamVersion)) row, disposition]],
      jsonValue = object ["preview" .= preview, "stream" .= name, "snapshot" .= fmap (snapshotJson name) row, "deleted" .= deleted, "disposition" .= disposition]
    }
  where
    disposition
      | preview = maybe "not_found" (const "would_delete") row
      | deleted = "deleted"
      | otherwise = "not_found"

preflightResult :: PreflightEvidence -> OpsResult
preflightResult evidence =
  OpsResult
    { headers = ["stream", "before", "required_snapshot", "snapshot_version", "version_covered", "discriminators_match", "passed", "reason"],
      rows =
        [ [ evidence.streamName,
            versionText evidence.truncateBefore,
            versionText evidence.requiredSnapshotVersion,
            maybe "none" (versionText . (.streamVersion)) evidence.snapshotRow,
            boolText evidence.versionCovered,
            boolText evidence.discriminatorsMatch,
            boolText evidence.passed,
            evidence.reason
          ]
        ],
      jsonValue =
        object
          [ "stream" .= evidence.streamName,
            "truncate_before" .= versionInt evidence.truncateBefore,
            "required_snapshot_version" .= versionInt evidence.requiredSnapshotVersion,
            "expected_discriminators" .= fmap expectedJson evidence.expectedDiscriminators,
            "snapshot" .= fmap (snapshotJson evidence.streamName) evidence.snapshotRow,
            "version_covered" .= evidence.versionCovered,
            "discriminators_match" .= evidence.discriminatorsMatch,
            "passed" .= evidence.passed,
            "reason" .= evidence.reason
          ]
    }

expectedJson :: ExpectedDiscriminators -> Value
expectedJson expected =
  object
    [ "state_codec_version" .= expected.stateCodecVersion,
      "regfile_shape_hash" .= expected.regfileShapeHash,
      "state_shape_hash" .= expected.stateShapeHash
    ]

versionInt :: StreamVersion -> Int64
versionInt (StreamVersion value) = value

versionText :: StreamVersion -> Text
versionText = showText . versionInt

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"

showText :: (Show a) => a -> Text
showText = Text.pack . show

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
