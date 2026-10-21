-- | Canonical first-page views over the same reads and encoders as the CLI.
module Keiro.Ops.Http.Views
  ( Item (..),
    View (..),
    workflowsView,
    timersView,
    projectionGroupsView,
    stableItemBody,
  )
where

import Control.Monad (unless)
import Data.Aeson (Value (..), encode, object, withObject, (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as Lazy
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Effectful.Exception (throwIO)
import Keiro.Ops.Http.Protocol (FeedName (..), feedNameText)
import Keiro.Ops.Projection (projectionGroupStatusJson)
import Keiro.Projection.Catalog (rebuildGroupIdText)
import Keiro.ReadModel (storeHeadPosition)
import Keiro.ReadModel.Rebuild
import Keiro.Timer
import Keiro.Workflow.Inspection qualified as Workflow
import Keiro.Workflow.Instance (WorkflowInstanceRow (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))

-- | keyJson is the removal identity; body is the shared poll representation.
data Item = Item {key :: !Text, keyJson :: !Value, body :: !Value}
  deriving stock (Eq, Show)

data View = View
  { viewId :: !Text,
    feedName :: !FeedName,
    readItems :: Eff '[Store, Error StoreError, IOE] (UTCTime, [Item], Maybe Value)
  }

canonical :: FeedName -> Value -> Text
canonical feed filters = feedNameText feed <> ":" <> Text.decodeUtf8 (Lazy.toStrict (encode filters))

parseFilters :: [Text] -> (KeyMap.KeyMap Value -> Parser a) -> Value -> Either Text a
parseFilters known parser =
  either (Left . Text.pack) Right
    . parseEither
      ( withObject
          "subscription"
          ( \fields -> do
              case filter (`notElem` known) (map Key.toText (KeyMap.keys fields)) of
                field : _ -> fail ("unknown subscription field: " <> Text.unpack field)
                [] -> pure ()
              parser fields
          )
      )

pageLimit :: Int -> KeyMap.KeyMap Value -> Parser Int
pageLimit bound fields = do
  supplied <- fields .:? "limit"
  let maximumItems = min 500 bound
      count = maybe (min 100 maximumItems) id supplied
  unless (maximumItems > 0 && count > 0 && count <= maximumItems) (fail "limit must be between 1 and the host maximum (at most 500)")
  pure count

workflowsView :: Int -> Value -> Either Text View
workflowsView bound filters = do
  (statuses, name, limit) <- parseFilters ["status_class", "workflow_name", "limit"] parse filters
  let query = Workflow.defaultWorkflowListQuery {Workflow.classes = NonEmpty.nonEmpty statuses, Workflow.workflowName = name, Workflow.pageSize = limit}
      identity = object ["status_class" .= map Workflow.statusClassToText statuses, "workflow_name" .= name, "limit" .= limit]
  pure
    ( View (canonical Workflows identity) Workflows $ do
        page <- Workflow.listWorkflowInstancesPage query >>= require
        pure (page.observedAt, map workflowItem page.items, Nothing)
    )
  where
    parse fields = do
      raw <- fields .:? "status_class"
      statuses <- case raw of
        Nothing -> pure []
        Just names -> do
          unless (not (null (names :: [Text]))) (fail "status_class must not be empty")
          parsed <- traverse (maybe (fail "unknown status_class") pure . Workflow.statusClassFromText) names
          let selected = Set.fromList parsed
          pure (if selected == Set.fromList [minBound .. maxBound] then [] else Set.toAscList selected)
      (statuses,,) <$> fields .:? "workflow_name" <*> pageLimit bound fields

workflowItem :: WorkflowInstanceRow -> Item
workflowItem row =
  Item
    (row.workflowName <> "\NUL" <> row.workflowId)
    (object ["workflow_name" .= row.workflowName, "workflow_id" .= row.workflowId])
    (Workflow.instanceToJson row)

timersView :: Int -> Value -> Either Text View
timersView bound filters = do
  (manager, correlation, limit) <-
    parseFilters
      ["manager", "correlation_id", "limit"]
      (\fields -> (,,) <$> fields .:? "manager" <*> fields .:? "correlation_id" <*> pageLimit bound fields)
      filters
  let identity = object ["manager" .= manager, "correlation_id" .= correlation, "limit" .= limit]
  pure
    ( View (canonical Timers identity) Timers $ do
        page <- findPendingTimers (PendingTimerFilter manager correlation) (PendingTimerPageRequest limit Nothing) >>= require
        pure
          ( page.observedAt,
            [ let TimerId uuid = inspection.timer.timerId
                  timerId = UUID.toText uuid
               in Item timerId (object ["timer_id" .= timerId]) (pendingTimerItemJson page.observedAt inspection)
            | inspection <- page.timers
            ],
            Nothing
          )
    )

projectionGroupsView :: Int -> Value -> Either Text View
projectionGroupsView bound filters = do
  limit <- parseFilters ["limit"] (pageLimit bound) filters
  pure
    ( View (canonical ProjectionGroups (object ["limit" .= limit])) ProjectionGroups $ do
        page <- listProjectionGroupStatusesPage (ProjectionStatusPageRequest limit Nothing) >>= require
        GlobalPosition visibleHead <- storeHeadPosition
        pure
          ( page.observedAt,
            [let groupId = rebuildGroupIdText row.groupId in Item groupId (object ["group_id" .= groupId]) (projectionGroupStatusJson row) | row <- page.items],
            Just (object ["visible_store_head" .= visibleHead])
          )
    )

require :: (Show err) => Either err value -> Eff '[Store, Error StoreError, IOE] value
require = either (throwIO . userError . show) pure

-- Database time changes the presentation countdown, not the timer's state.
-- Drivers retain each fresh body/read time even when this comparison is equal.
stableItemBody :: FeedName -> Item -> Value
stableItemBody Timers item = case item.body of Object fields -> Object (KeyMap.delete "due_in_seconds" fields); value -> value
stableItemBody _ item = item.body
