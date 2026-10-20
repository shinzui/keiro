-- | Bounded reuse of pure header presentation. Every lookup still reads the
-- complete current header in PostgreSQL; callers must verify live schema first.
module Keiro.Ops.WorkflowHeaderCache
  ( WorkflowHeaderCache,
    newWorkflowHeaderCache,
    workflowHeaderCacheUsage,
    runHeaderCached,
  )
where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hasql.Pool qualified as Pool
import Keiro.Ops.Env (OpsEnv (..))
import Keiro.Ops.Render
import Keiro.Ops.Workflow (WorkflowRef (..), headerOutcome)
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Error (mapGenericUsageError)

type View = (Text, Text)

data Entry = Entry !Instance.WorkflowHeaderKey !OpsResult !ByteString !Integer

data Entries = Entries !(Map.Map View Entry) !(Seq.Seq View) !Integer

data WorkflowHeaderCache = WorkflowHeaderCache
  { entries :: !(IORef Entries),
    imageLimit :: !Int,
    encode :: Value -> IO (Maybe ByteString)
  }

-- | At most 32 presentations, charged at most 1 MiB in total. Charge includes
-- input keys, exact row images, JSON values, rendered cells and encoded bodies.
-- A larger valid response can still be served without retaining its rendering.
-- The encoder must enforce the host's response cap and return exact JSON bytes.
newWorkflowHeaderCache :: Int -> (Value -> IO (Maybe ByteString)) -> IO WorkflowHeaderCache
newWorkflowHeaderCache responseLimit encode
  | responseLimit <= 0 = ioError (userError "header response limit must be positive")
  | otherwise = do
      entries <- newIORef (Entries Map.empty Seq.empty 0)
      -- PostgreSQL's image has field names and date arrays independent of the
      -- public wire format. Allow its fixed overhead without an Int overflow.
      let imageLimit = fromInteger (min (toInteger (maxBound :: Int)) (2 * toInteger responseLimit + 4096))
      pure WorkflowHeaderCache {entries, imageLimit, encode}

-- | Charged retained bytes and entry count, for host diagnostics.
workflowHeaderCacheUsage :: WorkflowHeaderCache -> IO (Int, Integer)
workflowHeaderCacheUsage cache = do
  Entries known _ bytes <- readIORef cache.entries
  pure (Map.size known, bytes)

runHeaderCached :: WorkflowHeaderCache -> OpsEnv -> WorkflowRef -> IO (OpsOutcome, Maybe ByteString)
runHeaderCached cache env ref = do
  Entries known _ _ <- readIORef cache.entries
  let view = (ref.workflowName, ref.workflowId)
      previous = Map.lookup view known
      key = case previous of Just (Entry image _ _ _) -> Just image; Nothing -> Nothing
      forget = atomicModifyIORef' cache.entries (\entries -> (remove view entries, ()))
      failure code message = forget >> pure (InspectionFailed code message, Nothing)
  observed <- Pool.use env.store.pool (Instance.lookupInstanceConditionalSession cache.imageLimit key (WorkflowName ref.workflowName) (WorkflowId ref.workflowId))
  case observed of
    Left err -> forget >> pure (Failed (Text.pack (show (mapGenericUsageError err))), Nothing)
    Right Nothing -> forget >> pure (headerOutcome ref Nothing, Nothing)
    Right (Just Instance.HeaderImageTooLarge) -> failure "inspection_result_too_large" "workflow header image exceeds the host limit"
    Right (Just Instance.HeaderUnchanged) -> case previous of
      Just (Entry _ result body _) -> pure (Succeeded result, Just body)
      Nothing -> failure "inspection_header_inconsistent" "header comparison returned no initial image"
    Right (Just (Instance.HeaderChanged image row)) -> case headerOutcome ref (Just row) of
      Succeeded result -> do
        encoded <- cache.encode result.jsonValue
        case encoded of
          Nothing -> failure "inspection_result_too_large" "encoded result exceeds the host limit; narrow the read"
          Just body -> do
            let charge = 4096 + toInteger (ByteString.length (Text.encodeUtf8 ref.workflowName)) + toInteger (ByteString.length (Text.encodeUtf8 ref.workflowId)) + 3 * toInteger (Instance.workflowHeaderKeyBytes image) + 6 * toInteger (ByteString.length body)
                entry = Entry image result body charge
            atomicModifyIORef' cache.entries (\entries -> (insert view entry entries, ()))
            pure (Succeeded result, Just body)
      outcome -> forget >> pure (outcome, Nothing)

remove :: View -> Entries -> Entries
remove view (Entries known order bytes) = case Map.lookup view known of
  Nothing -> Entries known order bytes
  Just (Entry _ _ _ charge) -> Entries (Map.delete view known) (Seq.filter (/= view) order) (bytes - charge)

insert :: View -> Entry -> Entries -> Entries
insert view entry@(Entry _ _ _ charge) entries =
  let without = remove view entries
   in if charge > 1024 * 1024 then without else fit without
  where
    fit (Entries known order bytes)
      | Map.size known < 32 && bytes + charge <= 1024 * 1024 = Entries (Map.insert view entry known) (order Seq.|> view) (bytes + charge)
      | otherwise = case Seq.viewl order of
          oldest Seq.:< _ -> fit (remove oldest (Entries known order bytes))
          Seq.EmptyL -> Entries Map.empty Seq.empty 0
