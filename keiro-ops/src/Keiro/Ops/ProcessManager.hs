-- | Thin read-only adapters over application-owned manager inspectors.
module Keiro.Ops.ProcessManager (Command (..), ShowOptions (..), ListOptions (..), commandParser, validateCommand, isMutation, runCommand) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Inspection.Cursor (InspectionCursor, decodeCursor)
import Keiro.Ops.Env (OpsEnv (..))
import Keiro.Ops.Parse (cursorReader, positiveIntReader)
import Keiro.Ops.Render
import Keiro.ProcessManager.Inspect qualified as PM
import Kiroku.Store.Effect (runStoreIO)
import Options.Applicative hiding (command, info, value)
import Options.Applicative qualified as Opt

data ShowOptions = ShowOptions {name :: !Text, correlationId :: !Text, timerLimit :: !Int}
  deriving stock (Eq, Show)

data ListOptions = ListOptions {name :: !Text, after :: !(Maybe InspectionCursor), limit :: !Int}
  deriving stock (Eq, Show)

data Command = Show !ShowOptions | List !ListOptions deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( Opt.command
        "show"
        ( Opt.info
            ( Show
                <$> ( ShowOptions
                        <$> name
                        <*> textOption "correlation" "ID"
                        <*> option positiveIntReader (long "timer-limit" <> Opt.value 20 <> metavar "N")
                    )
            )
            (progDesc "Observe persisted manager state and intended dispatch witnesses")
        )
        <> Opt.command
          "list"
          ( Opt.info
              ( List
                  <$> ( ListOptions
                          <$> name
                          <*> optional (option cursorReader (long "after" <> metavar "CURSOR"))
                          <*> option positiveIntReader (long "limit" <> Opt.value 50 <> metavar "N")
                      )
              )
              (progDesc "Read one page of manager journal streams")
          )
    )
  where
    name = textOption "name" "NAME"
    textOption key label = Text.pack <$> strOption (long key <> metavar label)

isMutation :: Command -> Bool
isMutation = const False

validateCommand :: Command -> Either (Text, Text) ()
validateCommand (Show options)
  | Text.null (Text.strip options.correlationId) = Left ("invalid_correlation_id", "correlation id must not be blank")
  | options.timerLimit < 1 || options.timerLimit > 500 = Left ("invalid_page_size", "timer page size must be 1..500")
  | otherwise = Right ()
validateCommand (List options)
  | options.limit < 1 || options.limit > 500 = Left ("invalid_page_size", "page size must be 1..500")
  | otherwise = case options.after of
      Nothing -> Right ()
      Just cursor -> case decodeCursor PM.instanceListCursorKind cursor of
        Right (owner, category, after :: Text) | owner == options.name && Text.isPrefixOf (category <> "-") after -> Right ()
        _ -> Left ("invalid_cursor", "cursor belongs to another manager inspector or is malformed")

runCommand :: PM.ProcessManagerInspectors -> OpsEnv -> Command -> IO OpsOutcome
runCommand catalog env command = case validateCommand command of
  Left (code, detail) -> pure (InspectionFailed code detail)
  Right () -> case Map.lookup owner catalog of
    Nothing -> pure (Failed ("unknown process manager: " <> owner))
    Just (PM.SomeProcessManagerInspector inspector) -> case command of
      Show options -> do
        result <- runStoreIO env.store (PM.inspectProcessManagerInstance inspector (PM.InstanceViewRequest options.timerLimit) options.correlationId)
        pure $ case result of
          Left err -> Failed (Text.pack (show err))
          Right (Left err) -> Failed (Text.pack (show err))
          Right (Right value) ->
            Succeeded
              ( OpsResult
                  ["name", "correlation_id", "state"]
                  (maybe [] (\view -> [[view.name, view.correlationId, maybe "" id view.stateLabel]]) value)
                  (maybe Aeson.Null PM.processManagerViewJson value)
              )
      List options -> do
        result <- runStoreIO env.store (PM.listProcessManagerInstances inspector (PM.InstanceListRequest options.limit options.after))
        pure $ case result of
          Left err -> Failed (Text.pack (show err))
          Right (Left err) -> uncurry InspectionFailed (listError err)
          Right (Right page) ->
            Succeeded
              ( OpsResult
                  ["correlation_id", "stream_version"]
                  [[item.correlationId, Text.pack (show item.streamVersion)] | item <- page.items]
                  (PM.instancePageJson page)
              )
  where
    owner = case command of Show options -> options.name; List options -> options.name
    listError err =
      ( case err of
          PM.InvalidInstancePageSize _ -> "invalid_page_size"
          PM.InvalidInstanceCursor _ -> "invalid_cursor"
          PM.InstanceResultTooLarge -> "inspection_result_too_large",
        Text.pack (show err)
      )
