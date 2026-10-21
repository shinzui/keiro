-- | The inspection socket dialect. Frames describe observations; clients recover
-- missed deltas by re-subscribing or reading the paired HTTP page.
module Keiro.Ops.Http.Protocol
  ( FeedName (..),
    feedNameText,
    parseFeedName,
    ClientFrame (..),
    ServerFrame (..),
    Trigger (..),
    SocketErrorCode (..),
    socketErrorText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Word (Word64)
import GHC.Generics (Generic)

-- | Exactly the three supported first-page views.
data FeedName = Workflows | Timers | ProjectionGroups deriving stock (Eq, Ord, Show, Generic)

feedNameText :: FeedName -> Text
feedNameText = \case Workflows -> "workflows"; Timers -> "timers"; ProjectionGroups -> "projection_groups"

parseFeedName :: Text -> Maybe FeedName
parseFeedName = \case "workflows" -> Just Workflows; "timers" -> Just Timers; "projection_groups" -> Just ProjectionGroups; _ -> Nothing

instance ToJSON FeedName where toJSON = String . feedNameText

instance FromJSON FeedName where parseJSON = withText "feed" (maybe (fail "unknown_feed") pure . parseFeedName)

-- Unknown names remain a typed subscription refusal, independently of malformed
-- JSON or an unknown frame type. The filter object is validated by the view.
data ClientFrame = Subscribe !FeedName !Value | UnknownSubscription !Text | Unsubscribe !FeedName | Ping
  deriving stock (Eq, Show, Generic)

instance FromJSON ClientFrame where
  parseJSON = withObject "client frame" $ \fields -> do
    kind <- fields .: "type"
    case (kind :: Text) of
      "subscribe" -> do
        name <- fields .: "feed"
        pure (maybe (UnknownSubscription name) (\feed -> Subscribe feed (Object (KeyMap.delete "type" (KeyMap.delete "feed" fields)))) (parseFeedName name))
      "unsubscribe" -> do
        name <- fields .: "feed"
        pure (maybe (UnknownSubscription name) Unsubscribe (parseFeedName name))
      "ping" -> pure Ping
      _ -> fail "unknown frame type"

instance ToJSON ClientFrame where
  toJSON = \case
    Subscribe feed filters -> object (["type" .= ("subscribe" :: Text), "feed" .= feed] <> filterFields filters)
    UnknownSubscription feed -> object ["type" .= ("subscribe" :: Text), "feed" .= feed]
    Unsubscribe feed -> object ["type" .= ("unsubscribe" :: Text), "feed" .= feed]
    Ping -> object ["type" .= ("ping" :: Text)]
    where
      filterFields (Object fields) = [(key, value) | (key, value) <- KeyMap.toList fields, key /= "type", key /= "feed"]; filterFields _ = []

data Trigger = Subscribed | Notify | Timeout deriving stock (Eq, Show, Generic)

instance ToJSON Trigger where toJSON = String . \case Subscribed -> "subscribe"; Notify -> "notify"; Timeout -> "timeout"

data SocketErrorCode = InvalidFrame | UnknownFeed | InvalidSubscription | QueueOverflow | ReadFailed | TooManyViews | InspectionBusy | InspectionResultTooLarge
  deriving stock (Eq, Show, Generic)

socketErrorText :: SocketErrorCode -> Text
socketErrorText = \case
  InvalidFrame -> "invalid_frame"
  UnknownFeed -> "unknown_feed"
  InvalidSubscription -> "invalid_subscription"
  QueueOverflow -> "queue_overflow"
  ReadFailed -> "read_failed"
  TooManyViews -> "too_many_views"
  InspectionBusy -> "inspection_busy"
  InspectionResultTooLarge -> "inspection_result_too_large"

instance ToJSON SocketErrorCode where toJSON = String . socketErrorText

data ServerFrame
  = Snapshot {feed :: !FeedName, sequence :: !Word64, trigger :: !Trigger, readAt :: !UTCTime, items :: ![Value], extra :: !(Maybe Value)}
  | Update {feed :: !FeedName, sequence :: !Word64, trigger :: !Trigger, readAt :: !UTCTime, changed :: ![Value], removed :: ![Value], extra :: !(Maybe Value)}
  | Unsubscribed !FeedName
  | Pong
  | ErrorFrame {code :: !SocketErrorCode, message :: !Text, errorFeed :: !(Maybe FeedName)}
  | Goodbye
  deriving stock (Eq, Show, Generic)

instance ToJSON ServerFrame where
  toJSON = \case
    Snapshot feed sequence trigger stamp items extra ->
      object
        (["type" .= ("snapshot" :: Text), "feed" .= feed, "sequence" .= sequence, "trigger" .= trigger, "observed_at" .= stamp, "items" .= items] <> extraFields extra)
    Update feed sequence trigger stamp changed removed extra ->
      object
        (["type" .= ("update" :: Text), "feed" .= feed, "sequence" .= sequence, "trigger" .= trigger, "observed_at" .= stamp, "changed" .= changed, "removed" .= removed] <> extraFields extra)
    Unsubscribed feed -> object ["type" .= ("unsubscribed" :: Text), "feed" .= feed]
    Pong -> object ["type" .= ("pong" :: Text)]
    ErrorFrame code message feed -> object (["type" .= ("error" :: Text), "code" .= code, "message" .= message] <> maybe [] (\value -> ["feed" .= value]) feed)
    Goodbye -> object ["type" .= ("goodbye" :: Text)]
    where
      extraFields (Just (Object fields)) = [(key, value) | (key, value) <- KeyMap.toList fields, key `notElem` ["type", "feed", "sequence", "trigger", "observed_at", "items", "changed", "removed"]]
      extraFields _ = []
