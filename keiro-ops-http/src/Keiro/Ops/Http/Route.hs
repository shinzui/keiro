module Keiro.Ops.Http.Route
  ( RouteError (..),
    renderRouteError,
    flagNames,
    translateRequest,
    ParseOutcome (..),
    parseArguments,
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Ops (AppHooks, Command, commandParser)
import Options.Applicative qualified as Options
import Options.Applicative.Common (mapParser)
import Options.Applicative.Types qualified as Types

data RouteError
  = EmptyPathSegment
  | OptionLikePathSegment !Text
  | InvalidQueryKey !Text
  | InvalidFlagValue !Text !Text
  | ReservedQueryKey !Text
  deriving stock (Eq, Show)

renderRouteError :: RouteError -> Text
renderRouteError = Text.pack . show

data Grammar = Grammar !(Set Text) !(Map Text Grammar)

-- | Partially apply at startup: metadata is shared across requests. Sibling
-- commands may use the same long option with different arities.
flagNames :: Options.Parser a -> [Text] -> Set Text
flagNames parser = select Set.empty (grammar parser)
  where
    select inherited (Grammar flags commands) path =
      let current = inherited <> flags
       in case path of
            word : rest | Just child <- Map.lookup word commands -> select current child rest
            _ -> current

grammar :: Options.Parser a -> Grammar
grammar parser = foldr combine (Grammar Set.empty Map.empty) (mapParser optionGrammar parser)
  where
    combine (Grammar a b) (Grammar c d) = Grammar (a <> c) (b <> d)
    optionGrammar :: Types.ArgumentReachability -> Types.Option x -> Grammar
    optionGrammar _ option = case Types.optMain option of
      Types.FlagReader names _ -> Grammar (Set.fromList [Text.pack name | Types.OptLong name <- names]) Map.empty
      Types.CmdReader _ commands ->
        Grammar Set.empty (Map.fromList [(Text.pack name, grammar (Types.infoParser child)) | (name, child) <- commands])
      _ -> Grammar Set.empty Map.empty

translateRequest :: Set Text -> [Text] -> [(Text, Maybe Text)] -> Either RouteError [Text]
translateRequest flags path query = do
  traverse_ checkSegment path
  options <- concat <$> traverse translate query
  pure (path <> options)
  where
    traverse_ f = foldr ((>>) . f) (pure ())
    checkSegment segment
      | Text.null segment = Left EmptyPathSegment
      | "-" `Text.isPrefixOf` segment = Left (OptionLikePathSegment segment)
      | otherwise = Right ()
    translate (key, maybeValue)
      | key `elem` ["json", "force", "database_url", "allow_schema_drift", "help"] = Left (ReservedQueryKey key)
      | Text.null key || not (Text.all (\c -> isAsciiLower c || isDigit c || c == '_') key) = Left (InvalidQueryKey key)
      | Set.member name flags = case value of
          "true" -> Right ["--" <> name]
          "false" -> Right []
          _ -> Left (InvalidFlagValue key value)
      | otherwise = Right ["--" <> name <> "=" <> value]
      where
        name = Text.replace "_" "-" key
        value = maybe "" id maybeValue

data ParseOutcome = Parsed !Command | Rejected !Text

parseArguments :: AppHooks -> [Text] -> ParseOutcome
parseArguments hooks arguments =
  case Options.execParserPure Options.defaultPrefs (Options.info (commandParser hooks) Options.fullDesc) (map Text.unpack arguments) of
    Options.Success command -> Parsed command
    Options.Failure failure -> Rejected (Text.pack (fst (Options.renderFailure failure "keiro-ops")))
    Options.CompletionInvoked _ -> Rejected "shell completion is not available over HTTP"
