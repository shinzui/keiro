{- | Umbrella entry point for the Keiro event-sourcing framework.

Importing @Keiro@ brings the everyday command-side surface into scope in
one go: the command runner ("Keiro.Command"), event 'Codec's
("Keiro.Codec"), the 'EventStream' definition and its snapshot policy
("Keiro.EventStream"), the content-based 'Router' ("Keiro.Router"),
snapshot helpers ("Keiro.Snapshot"), and typed 'Stream' handles
("Keiro.Stream").

The more specialized subsystems are not re-exported here and are imported
directly when needed: read models ("Keiro.ReadModel"), projections
("Keiro.Projection"), process managers ("Keiro.ProcessManager"), the
integration in/outbox ("Keiro.Inbox", "Keiro.Outbox"), timers
("Keiro.Timer"), and telemetry ("Keiro.Telemetry").

Known limit: Keiro currently uses kiroku's PostgreSQL event store, whose append
path serializes all writers through the @$all@ stream row while assigning the
global event order. That makes the global position simple and deterministic,
but it is a throughput ceiling for very high write rates across many unrelated
streams. This production-readiness hardening pass documents the limit rather
than redesigning it; applications that outgrow the single-row global append
lock need a future event-store migration plan.
-}
module Keiro (
    -- * Library version
    version,

    -- * Command side
    module Keiro.Command,
    module Keiro.Codec,

    -- * Stream definitions
    EventStream (..),
    Terminality (..),
    SnapshotPolicy (..),
    StateCodec (..),
    module Keiro.EventStream.Validate,
    module Keiro.Stream,

    -- * Routing and snapshots
    module Keiro.Router,
    module Keiro.Snapshot,
)
where

import Keiro.Codec
import Keiro.Command
import Keiro.EventStream
import Keiro.EventStream.Validate
import Keiro.Prelude
import Keiro.Router
import Keiro.Snapshot
import Keiro.Stream

-- | The Keiro library version, as a 'Text' for display and telemetry.
version :: Text
version = "0.1.0.0"
