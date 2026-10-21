-- | Read-only adapters over the application's aggregate catalog.
module Keiro.Ops.Aggregate (Command (..), ShowOptions (..), ListOptions (..), commandParser, validateCommand, isMutation, runCommand) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Inspection.Aggregate qualified as Aggregate
import Keiro.Inspection.Cursor (InspectionCursor, decodeCursor)
import Keiro.Ops.Env (OpsEnv (..))
import Keiro.Ops.Parse (cursorReader, positiveIntReader)
import Keiro.Ops.Render
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (StreamName (..), StreamVersion (..))
import Options.Applicative hiding (action, command, info, value)
import Options.Applicative qualified as Opt

data ShowOptions = ShowOptions {name :: !Text, aggregateId :: !Text}
  deriving stock (Eq, Show)

data ListOptions = ListOptions {name :: !Text, limit :: !Int, after :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show)

data Command = Types | Show !ShowOptions | Snapshot !ShowOptions | List !ListOptions
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( Opt.command "types" (Opt.info (pure Types) (progDesc "List mounted aggregate kinds"))
        <> Opt.command "show" (Opt.info (Show <$> showOptions) (progDesc "Inspect folded aggregate state"))
        <> Opt.command "snapshot" (Opt.info (Snapshot <$> showOptions) (progDesc "Inspect aggregate snapshot health"))
        <> Opt.command "list" (Opt.info (List <$> listOptions) (progDesc "Read one aggregate page"))
    )
  where
    textOption key label = Text.pack <$> strOption (long key <> metavar label)
    nameOption = textOption "name" "NAME"
    showOptions = ShowOptions <$> nameOption <*> textOption "id" "ID"
    listOptions = ListOptions <$> nameOption <*> option positiveIntReader (long "limit" <> Opt.value 50 <> metavar "N") <*> optional (option cursorReader (long "after" <> metavar "CURSOR"))

isMutation :: Command -> Bool
isMutation = const False

-- | Reject invalid input before a transport borrows a schema-check connection.
-- The owning page read additionally checks the catalog's exact category.
validateCommand :: Command -> Either (Text, Text) ()
validateCommand = \case
  Types -> Right ()
  Show options -> validateId options
  Snapshot options -> validateId options
  List options
    | options.limit < 1 || options.limit > Aggregate.maxAggregatePageSize -> Left ("invalid_page_size", "page size must be 1..500")
    | otherwise -> case options.after of
        Nothing -> Right ()
        Just cursor -> case decodeCursor Aggregate.aggregateListCursorKind cursor of
          Right (name, category, after :: Text)
            | name == options.name && Text.isPrefixOf (category <> "-") after -> Right ()
          _ -> Left ("invalid_cursor", "invalid cursor or cursor belongs to another aggregate inspector")
  where
    validateId options
      | Text.null (Text.strip options.aggregateId) = Left ("invalid_aggregate_id", "aggregate id must not be blank")
      | otherwise = Right ()

runCommand :: OpsEnv -> Aggregate.AggregateInspectors -> Command -> IO OpsOutcome
runCommand env catalog command = case command of
  Types ->
    pure
      ( Succeeded
          ( OpsResult
              ["name", "category", "snapshots_configured", "snapshot_policy"]
              [[summary.name, summary.category, if summary.snapshotsConfigured then "true" else "false", summary.snapshotPolicy] | summary <- Aggregate.listAggregateTypes catalog]
              (object ["items" .= map Aggregate.aggregateTypeJson (Aggregate.listAggregateTypes catalog)])
          )
      )
  Show options -> case Map.lookup options.name catalog of
    Nothing -> pure (Failed ("unknown aggregate kind: " <> options.name))
    Just (Aggregate.SomeAggregateInspector inspector) ->
      runAction env (Aggregate.inspectAggregate inspector options.aggregateId) $ \view ->
        OpsResult
          ["name", "aggregate_id", "stream_version", "state"]
          [[view.name, view.aggregateId, versionText view.streamVersion, maybe "" id view.stateLabel]]
          (Aggregate.aggregateViewJson view)
  Snapshot options -> case Map.lookup options.name catalog of
    Nothing -> pure (Failed ("unknown aggregate kind: " <> options.name))
    Just (Aggregate.SomeAggregateInspector inspector) ->
      runAction env (Aggregate.snapshotStatusFor inspector options.aggregateId) $ \(StreamName streamName, StreamVersion version, status) ->
        let value = case Aggregate.snapshotStatusJson status of
              Aeson.Object fields -> Aeson.Object (fields <> KeyMap.fromList [("name", Aeson.toJSON options.name), ("aggregate_id", Aeson.toJSON options.aggregateId), ("stream_name", Aeson.toJSON streamName), ("stream_version", Aeson.toJSON version)])
              other -> other
         in OpsResult ["name", "aggregate_id"] [[options.name, options.aggregateId]] value
  List options -> case Map.lookup options.name catalog of
    Nothing -> pure (Failed ("unknown aggregate kind: " <> options.name))
    Just (Aggregate.SomeAggregateInspector inspector) ->
      runAction env (Aggregate.listAggregates inspector (Aggregate.AggregateListRequest options.limit options.after)) $ \page ->
        OpsResult
          ["aggregate_id", "stream_name", "stream_version"]
          [[item.aggregateId, nameText item.streamName, versionText item.streamVersion] | item <- page.items]
          (Aggregate.aggregateListPageJson page)

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] (Either Aggregate.AggregateInspectionError a) -> (a -> OpsResult) -> IO OpsOutcome
runAction env action render = do
  result <- runStoreIO env.store action
  pure $ case result of
    Left err -> Failed (Text.pack (show err))
    Right (Left err) -> case err of
      Aggregate.InvalidPageSize _ -> InspectionFailed "invalid_page_size" (Aggregate.inspectionErrorText err)
      Aggregate.InvalidCursor _ -> InspectionFailed "invalid_cursor" (Aggregate.inspectionErrorText err)
      Aggregate.ResultTooLarge -> InspectionFailed "inspection_result_too_large" (Aggregate.inspectionErrorText err)
      _ -> Failed (Aggregate.inspectionErrorText err)
    Right (Right value) -> Succeeded (render value)

versionText :: StreamVersion -> Text
versionText (StreamVersion version) = Text.pack (show version)

nameText :: StreamName -> Text
nameText (StreamName name) = name
