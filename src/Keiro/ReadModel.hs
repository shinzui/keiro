{-# LANGUAGE MultilineStrings #-}

module Keiro.ReadModel
  ( ReadModel (..)
  , ConsistencyMode (..)
  , PositionWaitOptions (..)
  , ReadModelError (..)
  , runQuery
  , runQueryWith
  , waitFor
  , module Keiro.ReadModel.Schema
  )
where

import Control.Concurrent (threadDelay)
import Data.Time.Clock (diffUTCTime)
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Prelude
import Keiro.ReadModel.Schema
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import Prelude qualified

data ReadModel q r = ReadModel
  { name :: !Text
  , tableName :: !Text
  , subscriptionName :: !Text
  , version :: !Int
  , shapeHash :: !Text
  , defaultConsistency :: !ConsistencyMode
  , query :: !(q -> Tx.Transaction r)
  }
  deriving stock (Generic)

data ConsistencyMode
  = Strong
  | Eventual
  | PositionWait !PositionWaitOptions
  deriving stock (Generic, Eq, Show)

data PositionWaitOptions = PositionWaitOptions
  { target :: !(Maybe GlobalPosition)
  , timeoutMicros :: !Int
  , pollMicros :: !Int
  }
  deriving stock (Generic, Eq, Show)

data ReadModelError
  = ReadModelStaleSchema !Text !Int !Int !Text !Text
  | ReadModelWaitTimeout !Text !GlobalPosition !GlobalPosition
  | ReadModelNotLive !Text !ReadModelStatus
  deriving stock (Generic, Eq, Show)

runQuery ::
  (IOE :> es, Store :> es) =>
  ReadModel q r ->
  q ->
  Eff es (Either ReadModelError r)
runQuery readModel =
  runQueryWith (readModel ^. #defaultConsistency) readModel

runQueryWith ::
  (IOE :> es, Store :> es) =>
  ConsistencyMode ->
  ReadModel q r ->
  q ->
  Eff es (Either ReadModelError r)
runQueryWith consistency readModel input = do
  schemaCheck <- ensureReadModel readModel
  case schemaCheck of
    Left err -> pure (Left err)
    Right () -> do
      waitResult <- waitIfNeeded consistency readModel
      case waitResult of
        Left err -> pure (Left err)
        Right () -> Right <$> runTransaction ((readModel ^. #query) input)

waitFor ::
  (IOE :> es, Store :> es) =>
  PositionWaitOptions ->
  ReadModel q r ->
  GlobalPosition ->
  Eff es (Either ReadModelError ())
waitFor options readModel targetPosition = do
  started <- liftIO getCurrentTime
  poll started (GlobalPosition 0)
  where
    poll started observed = do
      current <- readSubscriptionPosition (readModel ^. #subscriptionName)
      let observed' = fromMaybe observed current
      if observed' >= targetPosition
        then pure (Right ())
        else do
          now <- liftIO getCurrentTime
          let elapsedMicros =
                Prelude.floor
                  (diffUTCTime now started Prelude.* 1000000)
          if elapsedMicros >= options ^. #timeoutMicros
            then
              pure
                (Left (ReadModelWaitTimeout (readModel ^. #name) targetPosition observed'))
            else do
              liftIO (threadDelay (options ^. #pollMicros))
              poll started observed'

ensureReadModel ::
  (Store :> es) =>
  ReadModel q r ->
  Eff es (Either ReadModelError ())
ensureReadModel readModel = do
  metadata <-
    registerReadModel
      (readModel ^. #name)
      (readModel ^. #version)
      (readModel ^. #shapeHash)
  pure (validateMetadata readModel metadata)

validateMetadata :: ReadModel q r -> ReadModelMetadata -> Either ReadModelError ()
validateMetadata readModel metadata
  | metadata ^. #version /= readModel ^. #version =
      stale
  | metadata ^. #shapeHash /= readModel ^. #shapeHash =
      stale
  | metadata ^. #status /= Live =
      Left (ReadModelNotLive (readModel ^. #name) (metadata ^. #status))
  | otherwise =
      Right ()
  where
    stale =
      Left
        ( ReadModelStaleSchema
            (readModel ^. #name)
            (readModel ^. #version)
            (metadata ^. #version)
            (readModel ^. #shapeHash)
            (metadata ^. #shapeHash)
        )

waitIfNeeded ::
  (IOE :> es, Store :> es) =>
  ConsistencyMode ->
  ReadModel q r ->
  Eff es (Either ReadModelError ())
waitIfNeeded Strong _ = pure (Right ())
waitIfNeeded Eventual _ = pure (Right ())
waitIfNeeded (PositionWait options) readModel =
  case options ^. #target of
    Nothing -> pure (Right ())
    Just targetPosition -> waitFor options readModel targetPosition

readSubscriptionPosition ::
  (Store :> es) =>
  Text ->
  Eff es (Maybe GlobalPosition)
readSubscriptionPosition subscriptionName =
  runTransaction $
    Tx.statement subscriptionName lookupSubscriptionPositionStmt

lookupSubscriptionPositionStmt :: Statement Text (Maybe GlobalPosition)
lookupSubscriptionPositionStmt =
  preparable
    """
    SELECT last_seen
    FROM subscriptions
    WHERE subscription_name = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (GlobalPosition <$> D.column (D.nonNullable D.int8)))
