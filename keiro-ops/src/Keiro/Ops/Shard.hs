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

import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
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
  = List
  | Status !Text
  | Relinquish !Text !WorkerId
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "list" (info (pure List) (progDesc "List sharded subscriptions and live ownership counts"))
        <> command "status" (info statusParser (progDesc "Show shard counts and ownership"))
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
  List -> False
  Status {} -> False
  Relinquish {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  List -> runAction env listShardedSubscriptions (Succeeded . listResult)
  Status name -> runAction env (shardOwnershipView (SubscriptionName name)) (Succeeded . statusResult)
  Relinquish name worker -> runRelinquish env name worker

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

statusResult :: ShardOwnershipView -> OpsResult
statusResult view =
  OpsResult
    { headers = ["subscription", "bucket", "owner", "lease_expires_at", "lease_state", "configured_shards"],
      rows = map rowText view.buckets,
      jsonValue =
        object
          [ "subscription" .= name,
            "observed_at" .= view.observedAt,
            "shard_counts" .= map countJson counts,
            "ownership" .= map ownershipJson view.buckets
          ]
    }
  where
    SubscriptionName name = view.subscriptionName
    counts = Map.toAscList (Map.fromListWith (+) [(row.shardCount, 1 :: Int) | row <- view.buckets])
    configured = Text.intercalate "," [showText shardCount <> " (" <> showText rowCount <> " rows)" | (shardCount, rowCount) <- counts]
    rowText row =
      [ name,
        showText row.bucket,
        maybe "unowned" workerText row.owner,
        maybe "" timeText row.leaseExpiresAt,
        leaseStateText (leaseStateAt view.observedAt row),
        configured
      ]
    ownershipJson row =
      object
        [ "bucket" .= row.bucket,
          "owner" .= fmap workerText row.owner,
          "lease_expires_at" .= row.leaseExpiresAt,
          "lease_state" .= leaseStateText (leaseStateAt view.observedAt row),
          "heartbeat_at" .= row.heartbeatAt,
          "updated_at" .= row.updatedAt,
          "lease_age_seconds" .= fmap (\age -> realToFrac age :: Double) (leaseAgeAt view.observedAt row)
        ]

countJson :: (Int, Int) -> Value
countJson (shardCount, rowCount) = object ["shard_count" .= shardCount, "rows" .= rowCount]

listResult :: ShardedSubscriptionList -> OpsResult
listResult view =
  OpsResult
    ["subscription", "buckets_total", "buckets_live", "live_owners"]
    [[nameText row.subscriptionName, showText row.bucketsTotal, showText row.bucketsLive, showText row.liveOwners] | row <- view.subscriptions]
    (object ["observed_at" .= view.observedAt, "items" .= map summaryJson view.subscriptions])
  where
    nameText (SubscriptionName name) = name
    summaryJson row =
      object
        [ "subscription" .= nameText row.subscriptionName,
          "shard_counts" .= map countJson row.shardCounts,
          "buckets_total" .= row.bucketsTotal,
          "buckets_live" .= row.bucketsLive,
          "buckets_expired" .= row.bucketsExpired,
          "buckets_unowned" .= row.bucketsUnowned,
          "live_owners" .= row.liveOwners
        ]

leaseStateText :: LeaseState -> Text
leaseStateText = \case LeaseLive -> "live"; LeaseExpired -> "expired"; LeaseUnowned -> "unowned"; LeaseInvalid -> "invalid"

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
