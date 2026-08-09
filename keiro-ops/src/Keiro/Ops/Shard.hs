-- | Operational adapters for sharded-subscription ownership.
--
-- Ownership reads and releases use 'Keiro.Subscription.Shard' exclusively, as
-- required by ADR 28.
module Keiro.Ops.Shard
  ( Command (..),
    commandParser,
    isMutation,
    runCommand,
  )
where

import Data.Aeson (object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Render
import Keiro.Subscription.Shard
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Options.Applicative hiding (action, value)

data Command
  = Status !Text
  | Relinquish !Text !WorkerId
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "status" (info statusParser (progDesc "Show shard counts and ownership"))
        <> command "relinquish" (info relinquishParser (progDesc "Preview or release every bucket owned by one worker"))
    )
  where
    statusParser = Status <$> subscriptionOption
    relinquishParser = Relinquish <$> subscriptionOption <*> (WorkerId <$> option uuidReader (long "worker" <> metavar "UUID" <> help "Worker id to release"))

subscriptionOption :: Parser Text
subscriptionOption = Text.pack <$> strOption (long "subscription" <> metavar "NAME" <> help "Sharded subscription name")

uuidReader :: ReadM UUID
uuidReader = eitherReader $ \raw -> maybe (Left "expected a UUID worker id") Right (UUID.fromString raw)

isMutation :: Command -> Bool
isMutation = \case
  Status {} -> False
  Relinquish {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Status name -> do
    now <- getCurrentTime
    runAction env (statusAction name) (Succeeded . uncurry (statusResult now name))
  Relinquish name worker -> runRelinquish env name worker

statusAction :: (Store :> es) => Text -> Eff es ([(Int, Maybe WorkerId, Maybe UTCTime)], [(Int, Int)])
statusAction name = do
  ownership <- ownershipSnapshotFor (SubscriptionName name)
  counts <- shardCountSnapshot (SubscriptionName name)
  pure (ownership, counts)

runRelinquish :: OpsEnv -> Text -> WorkerId -> IO OpsOutcome
runRelinquish env name worker
  | not env.force =
      runAction env (ownershipSnapshotFor subscription) $ \ownership ->
        let buckets = ownedBuckets worker ownership
         in PreviewRequired
              (relinquishResult True name worker buckets)
              (forceInvocation env ["shard", "relinquish", "--subscription", name, "--worker", workerText worker])
  | otherwise =
      runAction env action $ \buckets ->
        Succeeded (relinquishResult False name worker buckets)
  where
    subscription = SubscriptionName name
    lease = ShardLease subscription worker 0 0
    action = do
      ownership <- ownershipSnapshotFor subscription
      let buckets = ownedBuckets worker ownership
      relinquish lease (Set.fromList buckets)
      pure buckets

ownedBuckets :: WorkerId -> [(Int, Maybe WorkerId, Maybe UTCTime)] -> [Int]
ownedBuckets worker rows = [bucket | (bucket, Just owner, _) <- rows, owner == worker]

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] a -> (a -> OpsOutcome) -> IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

statusResult :: UTCTime -> Text -> [(Int, Maybe WorkerId, Maybe UTCTime)] -> [(Int, Int)] -> OpsResult
statusResult now name ownership counts =
  OpsResult
    { headers = ["subscription", "bucket", "owner", "lease_expires_at", "lease_state", "configured_shards"],
      rows = map rowText ownership,
      jsonValue = object ["subscription" .= name, "shard_counts" .= map countJson counts, "ownership" .= map ownershipJson ownership]
    }
  where
    configured = Text.intercalate "," [showText shardCount <> " (" <> showText rowCount <> " rows)" | (shardCount, rowCount) <- counts]
    rowText (bucket, owner, expiresAt) =
      [ name,
        showText bucket,
        maybe "unowned" workerText owner,
        maybe "" timeText expiresAt,
        leaseState now owner expiresAt,
        configured
      ]
    countJson (shardCount, rowCount) = object ["shard_count" .= shardCount, "rows" .= rowCount]
    ownershipJson (bucket, owner, expiresAt) =
      object
        [ "bucket" .= bucket,
          "owner" .= fmap workerText owner,
          "lease_expires_at" .= expiresAt,
          "lease_state" .= leaseState now owner expiresAt
        ]

leaseState :: UTCTime -> Maybe WorkerId -> Maybe UTCTime -> Text
leaseState _ Nothing _ = "unowned"
leaseState now (Just _) (Just expiry)
  | expiry < now = "expired"
  | otherwise = "live"
leaseState _ (Just _) Nothing = "invalid"

relinquishResult :: Bool -> Text -> WorkerId -> [Int] -> OpsResult
relinquishResult preview name worker buckets =
  OpsResult
    { headers = ["subscription", "worker", "bucket", "disposition"],
      rows = [[name, workerText worker, showText bucket, disposition] | bucket <- buckets],
      jsonValue = object ["preview" .= preview, "subscription" .= name, "worker" .= workerText worker, "buckets" .= buckets, "affected" .= length buckets]
    }
  where
    disposition = if preview then "would_relinquish" else "relinquished"

workerText :: WorkerId -> Text
workerText (WorkerId value) = UUID.toText value

timeText :: UTCTime -> Text
timeText = Text.pack . show

showText :: (Show a) => a -> Text
showText = Text.pack . show

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
