-- | One bounded outbound queue per socket, including the writer's in-flight
-- frame. Broadcast bytes are shared; overflow is signalled before later deltas.
module Keiro.Ops.Http.Feed.Queue
  ( OutboundQueue,
    Outgoing (..),
    newOutboundQueue,
    prepareOutgoing,
    enqueueOutgoing,
    nextOutgoing,
    finishOutgoing,
    nextFrame,
    purgeFeed,
    closeQueue,
  )
where

import Control.Concurrent.STM
import Data.Aeson (toJSON)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, ViewL (..), (|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Keiro.Ops.Http.Budget (encodeBounded)
import Keiro.Ops.Http.Protocol

-- | Keep the frame for typed consumers and its single shared wire encoding.
data Outgoing = Outgoing {frame :: !ServerFrame, bytes :: !Bytes.ByteString, owner :: !(Maybe FeedName)}

data QueueState = QueueState
  { pending :: !(Seq Outgoing),
    usedBytes :: !Int,
    usedFrames :: !Int,
    overflow :: !(Set.Set (Maybe FeedName)),
    closed :: !Bool
  }

data OutboundQueue = OutboundQueue !Int !Int !(Map.Map (Maybe FeedName) Outgoing) !(TVar QueueState)

newOutboundQueue :: Int -> Int -> Int -> IO OutboundQueue
newOutboundQueue capacity byteLimit frameLimit
  | capacity <= 0 || byteLimit < 256 || frameLimit < 256 = ioError (userError "feed queues must hold a control frame (256 bytes) and at least one frame")
  | otherwise = do
      errors <- mapM makeError [Nothing, Just Workflows, Just Timers, Just ProjectionGroups]
      OutboundQueue capacity byteLimit (Map.fromList errors) <$> newTVarIO (QueueState Seq.empty 0 0 Set.empty False)
  where
    makeError feed = do
      let value = ErrorFrame QueueOverflow "frames were dropped for this feed; re-subscribe or re-read" feed
      prepared <- prepareOutgoing (min frameLimit byteLimit) value
      maybe (ioError (userError "feed byte limits cannot hold an overflow frame")) (pure . (feed,)) prepared

prepareOutgoing :: Int -> ServerFrame -> IO (Maybe Outgoing)
prepareOutgoing limit value = do
  encoded <- encodeBounded limit (toJSON value)
  pure (fmap (\bytes -> Outgoing value (Lazy.toStrict bytes) (frameOwner value)) encoded)

frameOwner :: ServerFrame -> Maybe FeedName
frameOwner = \case
  Snapshot feed _ _ _ _ _ -> Just feed
  Update feed _ _ _ _ _ _ -> Just feed
  Unsubscribed feed -> Just feed
  ErrorFrame _ _ feed -> feed
  _ -> Nothing

size :: Outgoing -> Int
size value = Bytes.length value.bytes

-- Drop oldest queued frames until both limits fit. An in-flight frame cannot
-- be retracted; if it occupies the budget, discard the incoming frame instead.
roomFor :: Int -> Int -> Outgoing -> QueueState -> QueueState
roomFor capacity byteLimit incoming state
  | state.usedFrames < capacity && toInteger state.usedBytes + toInteger (size incoming) <= toInteger byteLimit = state
  | otherwise = case Seq.viewl state.pending of
      EmptyL -> state
      dropped :< rest ->
        roomFor
          capacity
          byteLimit
          incoming
          state
            { pending = rest,
              usedFrames = state.usedFrames - 1,
              usedBytes = state.usedBytes - size dropped,
              overflow = Set.insert dropped.owner state.overflow
            }

enqueueOutgoing :: OutboundQueue -> Outgoing -> STM Bool
enqueueOutgoing (OutboundQueue capacity byteLimit _ variable) value = do
  initial <- readTVar variable
  if initial.closed
    then pure False
    else do
      let state = roomFor capacity byteLimit value initial
          fits = state.usedFrames < capacity && toInteger state.usedBytes + toInteger (size value) <= toInteger byteLimit
          result =
            if fits
              then state {pending = state.pending |> value, usedFrames = state.usedFrames + 1, usedBytes = state.usedBytes + size value}
              else state {overflow = Set.insert value.owner state.overflow}
      writeTVar variable result
      pure fits

-- | The caller must finish this frame in a masked/bracketed writer before
-- dequeuing again. Its bytes/count stay charged while network delivery blocks.
nextOutgoing :: OutboundQueue -> STM (Maybe Outgoing)
nextOutgoing (OutboundQueue capacity byteLimit errors variable) = do
  state <- readTVar variable
  if state.closed
    then pure Nothing
    else case Set.lookupMin state.overflow of
      Just feed -> do
        let value = errors Map.! feed
            withRoom = roomFor capacity byteLimit value state
        check (withRoom.usedFrames < capacity && toInteger withRoom.usedBytes + toInteger (size value) <= toInteger byteLimit)
        writeTVar
          variable
          withRoom
            { overflow = Set.delete feed withRoom.overflow,
              usedFrames = withRoom.usedFrames + 1,
              usedBytes = withRoom.usedBytes + size value
            }
        pure (Just value)
      Nothing -> case Seq.viewl state.pending of
        EmptyL -> retry
        value :< rest -> do
          writeTVar variable state {pending = rest}
          pure (Just value)

finishOutgoing :: OutboundQueue -> Outgoing -> STM ()
finishOutgoing (OutboundQueue _ _ _ variable) value = modifyTVar' variable $ \state ->
  state {usedFrames = state.usedFrames - 1, usedBytes = state.usedBytes - size value}

-- | Typed in-process consumption releases the queue's reference immediately.
nextFrame :: OutboundQueue -> STM ServerFrame
nextFrame queue =
  nextOutgoing queue >>= \case
    Nothing -> pure Goodbye
    Just value -> finishOutgoing queue value >> pure value.frame

purgeFeed :: OutboundQueue -> FeedName -> STM ()
purgeFeed (OutboundQueue _ _ _ variable) feed = modifyTVar' variable $ \state ->
  let removed = Seq.filter ((== Just feed) . (.owner)) state.pending
   in state
        { pending = Seq.filter ((/= Just feed) . (.owner)) state.pending,
          usedFrames = state.usedFrames - Seq.length removed,
          usedBytes = state.usedBytes - sum (fmap size removed),
          overflow = Set.delete (Just feed) state.overflow
        }

closeQueue :: OutboundQueue -> STM ()
closeQueue (OutboundQueue _ _ _ variable) = modifyTVar' variable $ \state ->
  state
    { pending = Seq.empty,
      usedFrames = state.usedFrames - Seq.length state.pending,
      usedBytes = state.usedBytes - sum (fmap size state.pending),
      overflow = Set.empty,
      closed = True
    }
