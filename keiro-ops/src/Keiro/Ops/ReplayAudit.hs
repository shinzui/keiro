{-# LANGUAGE GADTs #-}

module Keiro.Ops.ReplayAudit
  ( Command (..),
    OpsAuditConfig (..),
    commandParser,
    runCommand,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Ops.Env (OpsEnv (..))
import Keiro.Ops.Render
import Keiro.ReplayAudit qualified as Audit
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Types
  ( EventType (..),
    GlobalPosition (..),
    StreamName (..),
    StreamVersion (..),
  )
import Options.Applicative hiding (value)
import Options.Applicative qualified as Optparse
import System.Exit (ExitCode (..))

newtype OpsAuditConfig = OpsAuditConfig
  { targets :: [Audit.SomeAuditTarget]
  }

newtype Command = Audit AuditOptions
  deriving stock (Eq, Show)

data AuditOptions = AuditOptions
  { mode :: !Audit.AuditMode,
    category :: !(Maybe Text),
    maxStreams :: !(Maybe Int),
    parallelism :: !Int,
    resumeFrom :: !(Maybe GlobalPosition)
  }
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  Audit
    <$> ( AuditOptions
            <$> auditModeParser
            <*> optional (Text.pack <$> strOption (long "category" <> metavar "CATEGORY" <> help "Run only the configured audit target for this category"))
            <*> optional (option positiveIntReader (long "budget" <> metavar "STREAMS" <> help "Maximum streams to inspect in this invocation"))
            <*> option positiveIntReader (long "parallelism" <> metavar "N" <> Optparse.value 4 <> showDefault <> help "Maximum concurrent stream audits")
            <*> optional (GlobalPosition <$> option auto (long "resume-from" <> metavar "POSITION" <> help "Resume after this global-position checkpoint"))
        )

auditModeParser :: Parser Audit.AuditMode
auditModeParser =
  flag' Audit.AuditFull (long "full" <> help "Audit every stream in each configured category")
    <|> ( Audit.AuditTargeted
            <$> ( Audit.AffectedSet
                    <$> (Set.fromList . map EventType <$> some (Text.pack <$> strOption (long "target" <> metavar "EVENT_TYPE" <> help "Affected event type from replay-impact analysis; repeat as needed")))
                    <*> switch (long "include-snapshots" <> help "Include streams selected through snapshot event types")
                )
        )

positiveIntReader :: ReadM Int
positiveIntReader = eitherReader $ \raw ->
  case reads raw of
    [(value, "")] | value > 0 -> Right value
    _ -> Left "expected a positive integer"

runCommand :: OpsEnv -> OpsAuditConfig -> Command -> IO OpsOutcome
runCommand env config (Audit options) =
  case selectedTargets of
    [] -> pure (Failed (missingTargetMessage options.category))
    targets -> do
      result <- runStoreIO env.store (Audit.auditTargets options.mode budget targets)
      pure $ case result of
        Left storeError -> Failed (Text.pack (show storeError))
        Right reports -> auditOutcome reports
  where
    selectedTargets =
      case options.category of
        Nothing -> config.targets
        Just wanted -> filter ((== wanted) . configuredCategory) config.targets
    budget =
      Audit.AuditBudget
        { maxStreams = options.maxStreams,
          parallelism = options.parallelism,
          resumeFrom = options.resumeFrom
        }

configuredCategory :: Audit.SomeAuditTarget -> Text
configuredCategory (Audit.SomeAuditTarget target) = target.category

missingTargetMessage :: Maybe Text -> Text
missingTargetMessage = \case
  Nothing -> "replay audit hook has no configured targets"
  Just category -> "replay audit hook has no target for category " <> category

auditOutcome :: [Audit.AuditReport] -> OpsOutcome
auditOutcome reports =
  let result = auditResult reports
   in case Audit.auditExitCode reports of
        0 -> Succeeded result
        code -> SucceededWithExit result (ExitFailure code)

auditResult :: [Audit.AuditReport] -> OpsResult
auditResult reports =
  OpsResult
    { headers = ["category", "mode", "selected", "skipped", "failures", "divergences", "checkpoint"],
      rows = map reportRow reports,
      jsonValue = toJson reports
    }

reportRow :: Audit.AuditReport -> [Text]
reportRow report =
  [ report.targetCategory,
    report.mode,
    showText report.streamsSelected,
    showText report.streamsSkipped,
    showText report.failures,
    showText report.divergences,
    maybe "-" globalPositionText report.checkpoint
  ]

toJson :: [Audit.AuditReport] -> Value
toJson reports =
  object
    [ "schema" .= ("keiro/replay-audit/v1" :: Text),
      "exit_code" .= Audit.auditExitCode reports,
      "reports" .= map reportJson reports
    ]

reportJson :: Audit.AuditReport -> Value
reportJson report =
  object
    [ "category" .= report.targetCategory,
      "mode" .= report.mode,
      "streams_selected" .= report.streamsSelected,
      "streams_skipped" .= report.streamsSkipped,
      "failures" .= report.failures,
      "divergences" .= report.divergences,
      "checkpoint" .= fmap globalPositionValue report.checkpoint,
      "rejected_streams" .= map streamNameText report.rejectedStreams,
      "results" .= map streamResultJson report.results
    ]

streamResultJson :: Audit.StreamAuditResult -> Value
streamResultJson result =
  object
    [ "stream" .= streamNameText result.streamName,
      "outcome" .= outcomeJson result.outcome
    ]

outcomeJson :: Audit.AuditOutcome -> Value
outcomeJson = \case
  Audit.ReplayOk streamVersion digest ->
    object
      [ "kind" .= ("ok" :: Text),
        "stream_version" .= streamVersionValue streamVersion,
        "digest" .= digest
      ]
  Audit.ReplayFailed commandError ->
    object
      [ "kind" .= ("failed" :: Text),
        "error" .= Text.pack (show commandError)
      ]
  Audit.SeedDivergence seedVersion seededDigest fullDigest ->
    object
      [ "kind" .= ("seed-divergence" :: Text),
        "seed_version" .= streamVersionValue seedVersion,
        "seeded_digest" .= seededDigest,
        "full_digest" .= fullDigest
      ]

streamNameText :: StreamName -> Text
streamNameText (StreamName value) = value

streamVersionValue :: StreamVersion -> Int
streamVersionValue (StreamVersion value) = fromIntegral value

globalPositionValue :: GlobalPosition -> Integer
globalPositionValue (GlobalPosition value) = fromIntegral value

globalPositionText :: GlobalPosition -> Text
globalPositionText = showText . globalPositionValue

showText :: (Show a) => a -> Text
showText = Text.pack . show
