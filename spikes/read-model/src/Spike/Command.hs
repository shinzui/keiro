-- | The spike's command primitives. Two flavours:
--
-- * 'runCommand' — the standard load -> fold -> decide -> append cycle
--   inherited verbatim from spikes/command-cycle. Used by scenarios
--   that don't need an inline projection.
--
-- * 'runCommandInline' — same cycle but the append plus a caller-
--   supplied @Hasql.Transaction.Transaction ()@ continuation run as
--   one ACID transaction via kiroku-store's @runTransactionAppending@.
--   This is the v1 inline-projection primitive: read-model rows are
--   updated in the same Postgres transaction as the event append.
module Spike.Command
  ( CommandError (..)
  , runCommand
  , runCommandInline
  , hydrate
  ) where

import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, throwError)

import qualified Hasql.Transaction as Tx

import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction (runTransactionAppending)
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

import Spike.EventStream (EventStream (..))


-- | Outcomes the spike's command cycle can refuse with.
data CommandError
  = DecodeError !StreamName !EventType !String
  | ReplayError !StreamName !EventType
  | CommandRejected !StreamName !Text
  deriving stock (Eq, Show)


hydrationPageSize :: Int32
hydrationPageSize = 256


runCommand
  :: forall phi rs s ci co es.
     ( Store :> es
     , Error StoreError :> es
     , Error CommandError :> es
     , BoolAlg phi (RegFile rs, ci)
     , Show ci
     )
  => EventStream phi rs s ci co
  -> StreamName
  -> ci
  -> Eff es (Maybe co)
runCommand evstream sn cmd = do
  (s, regs, version) <- hydrate evstream sn
  case step (esTransducer evstream) (s, regs) cmd of
    Nothing -> throwError (CommandRejected sn (T.pack (show cmd)))
    Just (_s', _regs', Nothing) -> pure Nothing
    Just (_s', _regs', Just ev) -> do
      let evData = EventData
            { eventId       = Nothing
            , eventType     = EventType (esEventTag evstream ev)
            , payload       = esEncode evstream ev
            , metadata      = Nothing
            , causationId   = Nothing
            , correlationId = Nothing
            }
          expected = case version of
            StreamVersion 0 -> NoStream
            v               -> ExactVersion v
      _ <- appendToStream sn expected [evData]
      pure (Just ev)


-- | The inline-projection variant. Runs the same load -> fold ->
-- decide cycle, then atomically appends the event AND runs the
-- caller's @Tx.Transaction ()@ continuation. The continuation is
-- the projection write — typically a single
-- @INSERT ... ON CONFLICT ... DO UPDATE@ against the read-model
-- table.
--
-- A 'CommandRejected' on the decide side prevents both the append
-- and the projection write (the kiroku call never happens).
-- A failure inside the continuation rolls back the append (kiroku-
-- store's @runTransactionAppending@ semantics: the body and the
-- append are one tx).
runCommandInline
  :: forall phi rs s ci co es.
     ( IOE :> es
     , Store :> es
     , Error StoreError :> es
     , Error CommandError :> es
     , BoolAlg phi (RegFile rs, ci)
     , Show ci
     )
  => EventStream phi rs s ci co
  -> StreamName
  -> ci
  -> (co -> Tx.Transaction ())
     -- ^ The projection write. Receives the emitted event (decoded
     -- domain value), runs SQL against the same connection that just
     -- appended.
  -> Eff es (Maybe co)
runCommandInline evstream sn cmd projection = do
  (s, regs, version) <- hydrate evstream sn
  case step (esTransducer evstream) (s, regs) cmd of
    Nothing -> throwError (CommandRejected sn (T.pack (show cmd)))
    Just (_s', _regs', Nothing) -> pure Nothing
    Just (_s', _regs', Just ev) -> do
      let evData = EventData
            { eventId       = Nothing
            , eventType     = EventType (esEventTag evstream ev)
            , payload       = esEncode evstream ev
            , metadata      = Nothing
            , causationId   = Nothing
            , correlationId = Nothing
            }
          expected = case version of
            StreamVersion 0 -> NoStream
            v               -> ExactVersion v
      result <- runTransactionAppending sn expected [evData] $ \_appendResult -> do
        projection ev
        pure ev
      case result of
        Left storeErr -> throwError storeErr
        Right ev'     -> pure (Just ev')


hydrate
  :: forall phi rs s ci co es.
     ( Store :> es
     , Error StoreError :> es
     , Error CommandError :> es
     , BoolAlg phi (RegFile rs, ci)
     )
  => EventStream phi rs s ci co
  -> StreamName
  -> Eff es (s, RegFile rs, StreamVersion)
hydrate evstream sn = do
  let trans   = esTransducer evstream
      acc0    = (initial trans, initialRegs trans, StreamVersion 0)
      stream  = hydrationStream sn hydrationPageSize
  Stream.fold (Fold.foldlM' replayStep (pure acc0)) stream
  where
    replayStep
      :: (s, RegFile rs, StreamVersion)
      -> RecordedEvent
      -> Eff es (s, RegFile rs, StreamVersion)
    replayStep (s, regs, _v) recorded = do
      ev <- case esDecode evstream recorded.payload of
        Right ev -> pure ev
        Left  e  -> throwError (DecodeError sn recorded.eventType e)
      case applyEvent (esTransducer evstream) s regs ev of
        Just (s', regs') -> pure (s', regs', recorded.streamVersion)
        Nothing          -> throwError (ReplayError sn recorded.eventType)


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
