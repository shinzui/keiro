{-# LANGUAGE OverloadedStrings #-}

-- Preserve ordinary writer key domains when evaluating inspection indexes.
-- All intentional failures are on durable disposable clones owned by this run.
import Control.Exception (bracket)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Session qualified as Session
import Keiro.Test.Postgres
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> do
    workflows <- forM [False, True] $ \longId -> withFreshDatabase fixture $ \url -> do
      checked url "DROP INDEX keiro.keiro_workflows_created_idx; DROP INDEX keiro.keiro_workflows_inspection_class_key_idx"
      let insert n = "WITH bytes AS (SELECT string_agg(md5(n::text),'') value FROM generate_series(1,120) n) INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT " <> (if longId then "left(value," <> number n <> "),'wide'" else "'wide',left(value," <> number n <> ")") <> ",'running' FROM bytes"
          fits n = do
            checked url "DELETE FROM keiro.keiro_workflows"
            result <- attempt url (insert n)
            pure (either (const False) (const True) result)
      width <- largest fits 0 3100
      checked url "DELETE FROM keiro.keiro_workflows"
      checked url (insert width)
      creation <- attempt url "CREATE INDEX inspection_creation_probe ON keiro.keiro_workflows(created_at,workflow_name,workflow_id)"
      full <- attempt url "CREATE INDEX inspection_class_probe ON keiro.keiro_workflows(inspection_status_class,workflow_name,workflow_id)"
      partial <- attempt url "CREATE INDEX inspection_partial_probe ON keiro.keiro_workflows(workflow_name,workflow_id) WHERE inspection_status_class='running'"
      pure (object ["long_id" .= longId, "accepted_baseline_text_bytes" .= width, "creation_index" .= creation, "class_index" .= full, "partial_class_index" .= partial])
    children <- withFreshDatabase fixture $ \url -> do
      checked url "WITH bytes AS (SELECT string_agg(md5(n::text),'') value FROM generate_series(1,120) n) INSERT INTO keiro.keiro_workflow_children(child_id,child_name,parent_id,parent_name,await_step) SELECT left(value,1600),'child',right(value,1600),'owner','await' FROM bytes"
      attempt url "CREATE INDEX inspection_child_probe ON keiro.keiro_workflow_children(parent_id,parent_name,created_at,child_id,child_name)"
    awakeables <- withFreshDatabase fixture $ \url -> do
      let insert n = "WITH bytes AS (SELECT string_agg(md5(n::text),'') value FROM generate_series(1,120) n) INSERT INTO keiro.keiro_awakeables(awakeable_id,owner_workflow_name,owner_workflow_id) SELECT '00000000-0000-0000-0000-000000000001'::uuid,'owner',left(value," <> number n <> ") FROM bytes"
          fits n = do
            checked url "DELETE FROM keiro.keiro_awakeables"
            result <- attempt url (insert n)
            pure (either (const False) (const True) result)
      width <- largest fits 0 3100
      checked url "DELETE FROM keiro.keiro_awakeables"
      checked url (insert width)
      result <- attempt url "CREATE INDEX inspection_awakeable_probe ON keiro.keiro_awakeables(owner_workflow_name,owner_workflow_id,created_at,awakeable_id)"
      pure (object ["accepted_baseline_text_bytes" .= width, "candidate_index" .= result])
    Lazy.writeFile (output </> "key-domain.json") (Aeson.encode (object ["workflows" .= workflows, "children_candidate_index" .= children, "awakeables" .= awakeables]))

largest :: (Int -> IO Bool) -> Int -> Int -> IO Int
largest fits lower upper
  | upper - lower <= 1 = pure lower
  | otherwise = do
      let middle = (lower + upper) `div` 2
      good <- fits middle
      if good then largest fits middle upper else largest fits lower middle

number :: Int -> Text
number = Text.pack . show

checked :: Text -> Text -> IO ()
checked url sql = attempt url sql >>= either (fail . Text.unpack) pure

attempt :: Text -> Text -> IO (Either Text ())
attempt url sql = bracket (Connection.acquire (Settings.connectionString url) >>= either (fail . show) pure) Connection.release $ \connection ->
  either (Left . Text.pack . show) Right <$> Connection.use connection (Session.script sql)
