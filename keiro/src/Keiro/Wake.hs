{- | A wake signal for keiro's poll-loop workers (EP-50, LISTEN/NOTIFY push delivery).

keiro's background workers — the workflow resume worker, the durable-timer worker,
the outbox publisher — make progress by polling: run one "claim, process, commit"
pass, then sleep a fixed interval. That fixed sleep is also the worst-case latency
(the resume worker's default is a full second). This module lets a worker instead
/wait to be woken/: it blocks until either a relevant append notification arrives —
meaning "something was appended, go look" — or a bounded fallback timeout elapses.

== Where the wake comes from (no new connection)

The kiroku event store already fires a Postgres @NOTIFY@ on channel @\<schema\>.events@
(default @kiroku.events@) on every append, via a @notify_events()@ trigger on the
@streams@ table, and already runs __one dedicated long-lived listener connection per
store__ ('Kiroku.Store.Notification.Notifier', started once by
'Kiroku.Store.Connection.withStore'). That listener fans every notification out to an
in-process broadcast channel, @notifier.tickChan :: 'Control.Concurrent.STM.TChan' ()@.

A 'WakeSignal' built by 'wakeSignalFromStore' duplicates that broadcast channel
('Control.Concurrent.STM.dupTChan' — an STM operation, __not__ a database connection),
so N keiro workers over one store share the single existing listener connection and N
cheap STM cursors. Push therefore adds __zero__ new long-lived connections: the only
listener connection is kiroku's pre-existing @kiroku-listener@, amortized across all
subscribers. The query pool is sized exactly as before.

== Push is an optimization over a durable poll, never a replacement

A Postgres @NOTIFY@ is best-effort: if the listener is momentarily disconnected the
notification is dropped, and the payload is advisory. So correctness must never depend
on a notification arriving. 'waitForWake' always takes a fallback timeout: a missed
notification only delays the next pass to that fallback interval, exactly as the old
fixed-poll loop did. The channel and payload are kiroku's
(@\<schema\>.events@; @stream_name,stream_id,stream_version@); keiro treats the
notification as an opaque wake and re-queries durably, so it ignores the payload.
-}
module Keiro.Wake
  ( WakeSignal (..)
  , WakeReason (..)
  , wakeSignalFromStore
  , neverWake
  )
where

import Control.Concurrent.STM
  ( TChan
  , atomically
  , check
  , dupTChan
  , isEmptyTChan
  , orElse
  , readTChan
  , readTVar
  , registerDelay
  )
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Notification (Notifier (..))

-- | Why a 'waitForWake' returned: a notification arrived, or the fallback timeout
-- elapsed. Both mean "run another pass"; the distinction is available for telemetry.
data WakeReason = WokenByNotify | WokenByTimeout
  deriving stock (Eq, Show)

{- | A source of "something was appended, go look" wake-ups, layered over a bounded
fallback timeout so a missed notification never stalls progress.
-}
newtype WakeSignal = WakeSignal
  { waitForWake :: Int -> IO WakeReason
  -- ^ Block until a notification arrives OR the given fallback timeout
  --   (microseconds) elapses, whichever is first. Returns which happened.
  }

{- | Build a 'WakeSignal' from a running kiroku store's notifier. Duplicates the
store's broadcast tick channel ('dupTChan') __once__ here, so this consumer has its
own cursor and never steals another consumer's ticks, and so ticks arriving between
waits queue in the duplicated channel rather than being lost. Opens __no__ new
database connection: it rides the single dedicated listener connection the store
already holds.
-}
wakeSignalFromStore :: KirokuStore -> IO WakeSignal
wakeSignalFromStore store = do
  myChan <- atomically (dupTChan (tickChan (notifier store)))
  pure (WakeSignal (waitOn myChan))
 where
  waitOn :: TChan () -> Int -> IO WakeReason
  waitOn myChan timeoutMicros = do
    timer <- registerDelay timeoutMicros
    atomically $
      ( do
          -- A tick is queued: collapse any backlog so one wait returns once per
          -- "there is new work" episode (the worker re-queries durably anyway).
          _ <- readTChan myChan
          drain myChan
          pure WokenByNotify
      )
        `orElse` (readTVar timer >>= check >> pure WokenByTimeout)

  drain ch = do
    empty <- isEmptyTChan ch
    if empty then pure () else readTChan ch >> drain ch

{- | A 'WakeSignal' that never fires a notification — every wait elapses the fallback
timeout. Used to simulate "all NOTIFYs dropped" (proving push is an optimization over
the durable poll) and to give a fixed-poll worker an unchanged cadence under the same
push-aware driver.
-}
neverWake :: WakeSignal
neverWake = WakeSignal $ \timeoutMicros -> do
  timer <- registerDelay timeoutMicros
  atomically (readTVar timer >>= check)
  pure WokenByTimeout
