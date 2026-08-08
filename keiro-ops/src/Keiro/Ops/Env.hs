module Keiro.Ops.Env
  ( GlobalOptions (..),
    OpsEnv (..),
    OutputMode (..),
    globalOptionsParser,
    resolveConnectionString,
    selectConnectionString,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kiroku.Store.Connection (KirokuStore)
import Options.Applicative
import System.Environment (lookupEnv)

data OutputMode
  = HumanTable
  | Json
  deriving stock (Eq, Show)

data GlobalOptions = GlobalOptions
  { databaseUrl :: !(Maybe Text),
    outputMode :: !OutputMode,
    force :: !Bool,
    allowSchemaDrift :: !Bool
  }
  deriving stock (Eq, Show)

data OpsEnv = OpsEnv
  { store :: !KirokuStore,
    outputMode :: !OutputMode,
    force :: !Bool,
    schemaDrift :: ![Text],
    allowSchemaDrift :: !Bool
  }

globalOptionsParser :: Parser GlobalOptions
globalOptionsParser =
  GlobalOptions
    <$> optional
      ( Text.pack
          <$> strOption
            ( long "database-url"
                <> metavar "URL"
                <> help
                  "PostgreSQL URI or keyword/value string; defaults to KEIRO_OPS_DATABASE_URL, DATABASE_URL, then libpq PG* variables"
            )
      )
    <*> flag HumanTable Json (long "json" <> help "Emit machine-readable JSON")
    <*> switch (long "force" <> help "Apply a mutating command after its preview")
    <*> switch
      ( long "allow-schema-drift"
          <> help "Allow a mutating command despite a failed schema agreement check"
      )

resolveConnectionString :: Maybe Text -> IO Text
resolveConnectionString explicit = do
  keiroOpsDatabaseUrl <- fmap Text.pack <$> lookupEnv "KEIRO_OPS_DATABASE_URL"
  databaseUrl <- fmap Text.pack <$> lookupEnv "DATABASE_URL"
  pure (selectConnectionString explicit keiroOpsDatabaseUrl databaseUrl)

selectConnectionString :: Maybe Text -> Maybe Text -> Maybe Text -> Text
selectConnectionString explicit keiroOpsDatabaseUrl databaseUrl =
  maybe "" id (explicit <|> keiroOpsDatabaseUrl <|> databaseUrl)
