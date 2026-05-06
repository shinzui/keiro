-- | The spike's @runCommand@: the load -> fold -> decide -> append
-- cycle on top of kiroku-store and keiki. The hydration phase is
-- expressed as a Streamly @Stream@ of 'RecordedEvent's consumed by a
-- @Fold@ that decodes the JSON payload and applies it through keiki's
-- 'applyEvent', so replay is constant-memory regardless of stream
-- length. This shape is the empirical demonstration of the
-- "Streamly substrate" Integration Point recorded in the parent
-- MasterPlan.
module Spike.Command
  ( CommandError (..)
  , runCommand
  , hydrate
  ) where

import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)

import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types
  ( EventData (..)
  , EventType (..)
  , ExpectedVersion (..)
  , RecordedEvent (..)
  , StreamName (..)
  , StreamVersion (..)
  )

import qualified Streamly.Data.Fold as Fold
import qualified Streamly.Data.Stream as Stream
import Streamly.Data.Stream (Stream)

import Keiki.Core
  ( BoolAlg
  , RegFile
  , SymTransducer (..)
  , applyEvent
  , step
  )

import Spike.Aggregate (Aggregate (..))


-- | Outcomes the spike's command cycle can refuse with. Distinct from
-- 'StoreError' so the driver can attribute concurrent-writer
-- contention (kiroku's 'WrongExpectedVersion') to the retry layer
-- and decide-time refusals to this layer.
data CommandError
  = -- | The stored event payload could not be decoded against the
    -- aggregate's codec.
    DecodeError !StreamName !EventType !String
  | -- | A decoded event did not match any active outgoing edge under
    -- replay (malformed log; constructor renamed without an
    -- upcaster; or two streams' events crossed wires).
    ReplayError !StreamName !EventType
  | -- | The transducer's 'step' returned 'Nothing' for the supplied
    -- command at the hydrated state — no edge fires. Whether this is
    -- a domain rejection ("invalid in this state") or a no-op
    -- ("nothing to do yet") is the caller's interpretation.
    CommandRejected !StreamName !Text
  deriving stock (Eq, Show)


-- | Page size for the hydration stream. Each call to
-- 'readStreamForward' returns up to this many events; pages are
-- chained together by 'Stream.unfoldrM' until kiroku returns an
-- empty page.
hydrationPageSize :: Int32
hydrationPageSize = 256


-- | Run the command cycle once: hydrate, decide, append. Concurrent
-- writers are not retried here; that is 'Spike.Retry.runCommandRetry'
-- 's job.
--
-- The 'Maybe co' result encodes:
--
--   * @'Just' ev@ — an event was emitted and appended to kiroku.
--   * @'Nothing'@ — 'step' returned @'Just' (s', regs', 'Nothing')@,
--     a silent (ε-edge-style) advance with no observable event. The
--     spike's Counter aggregate does not exercise this path
--     (CooldownEnded is emitted, not silent), so 'Nothing' here
--     would surprise the driver; it is left expressible because
--     the contract permits it.
--
-- Refusals raise 'CommandRejected' via 'throwError'.
runCommand
  :: forall phi rs s ci co es.
     ( Store :> es
     , Error StoreError :> es
     , Error CommandError :> es
     , BoolAlg phi (RegFile rs, ci)
     , Show ci
     )
  => Aggregate phi rs s ci co
  -> StreamName
  -> ci
  -> Eff es (Maybe co)
runCommand agg sn cmd = do
  (s, regs, version) <- hydrate agg sn
  case step (aggTransducer agg) (s, regs) cmd of
    Nothing -> throwError (CommandRejected sn (T.pack (show cmd)))
    Just (_s', _regs', Nothing) -> pure Nothing
    Just (_s', _regs', Just ev) -> do
      let evData = EventData
            { eventId       = Nothing
            , eventType     = EventType (aggEventTag agg ev)
            , payload       = aggEncode agg ev
            , metadata      = Nothing
            , causationId   = Nothing
            , correlationId = Nothing
            }
          expected = case version of
            StreamVersion 0 -> NoStream
            v               -> ExactVersion v
      _result <- appendToStream sn expected [evData]
      pure (Just ev)


-- | Load the aggregate's stream from kiroku, fold each event through
-- 'applyEvent', and return the resulting @(state, registers,
-- currentVersion)@. The fold is over a Streamly @Stream@; the
-- accumulator threads the highest @streamVersion@ seen so the
-- caller can choose 'NoStream' vs 'ExactVersion' on append without
-- a second round-trip to kiroku.
hydrate
  :: forall phi rs s ci co es.
     ( Store :> es
     , Error StoreError :> es
     , Error CommandError :> es
     , BoolAlg phi (RegFile rs, ci)
     )
  => Aggregate phi rs s ci co
  -> StreamName
  -> Eff es (s, RegFile rs, StreamVersion)
hydrate agg sn = do
  let trans   = aggTransducer agg
      acc0    = (initial trans, initialRegs trans, StreamVersion 0)
      stream  = hydrationStream sn hydrationPageSize
  Stream.fold (Fold.foldlM' replayStep (pure acc0)) stream
  where
    replayStep
      :: (s, RegFile rs, StreamVersion)
      -> RecordedEvent
      -> Eff es (s, RegFile rs, StreamVersion)
    replayStep (s, regs, _v) recorded = do
      ev <- case aggDecode agg recorded.payload of
        Right ev -> pure ev
        Left  e  -> throwError (DecodeError sn recorded.eventType e)
      case applyEvent (aggTransducer agg) s regs ev of
        Just (s', regs') -> pure (s', regs', recorded.streamVersion)
        Nothing          -> throwError (ReplayError sn recorded.eventType)


-- | Build the hydration stream by paging 'readStreamForward'. The
-- @unfoldrM@ state is the cursor; each page is materialized into a
-- 'Stream' via 'Stream.fromList' and the pages are concatenated
-- with 'Stream.concatMap'.
hydrationStream
  :: forall es. (Store :> es, Error StoreError :> es)
  => StreamName
  -> Int32
  -> Stream (Eff es) RecordedEvent
hydrationStream sn pageSize =
  Stream.concatMap (Stream.fromList . V.toList) pages
  where
    pages :: Stream (Eff es) (V.Vector RecordedEvent)
    pages = Stream.unfoldrM nextPage (StreamVersion 0)

    nextPage :: StreamVersion -> Eff es (Maybe (V.Vector RecordedEvent, StreamVersion))
    nextPage cursor = do
      events <- readStreamForward sn cursor pageSize
      if V.null events
        then pure Nothing
        else
          let lastEv = V.last events
              lastV  = lastEv.streamVersion
          in pure (Just (events, lastV))
