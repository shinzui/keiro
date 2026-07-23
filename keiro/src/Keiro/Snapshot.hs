{- | Snapshots: skipping replay by persisting folded aggregate state.

A snapshot stores an aggregate's @(state, registers)@ at a known stream
version so hydration can start there instead of replaying the whole event
log. 'hydrateWithSnapshot' loads the latest compatible snapshot for a
stream (returning a 'SnapshotSeed' the command runner replays /forward/
from), and 'writeSnapshot' persists one after an append when the stream's
'Keiro.EventStream.SnapshotPolicy' fires.

Compatibility is gated by the version, register-file shape hash, and
control-state shape/fold hash of the 'StateCodec': a snapshot is only loaded
when all three match the current codec, so an incompatible encoding, register
layout, or folded-state interpretation transparently falls back to a full
replay. The JSON encoding lives in "Keiro.Snapshot.Codec" and the SQL storage
in "Keiro.Snapshot.Schema", both re-exported here.

Snapshot version non-regression applies only while all three discriminators
stay the same. A writer with any discriminant changed may replace a
higher-version row, allowing codec rollback to recover. In a mixed-version
deployment incompatible writers can therefore thrash the one row per stream
and repeatedly force full replay; this affects performance, not correctness.
-}
module Keiro.Snapshot (
    -- * Hydration seed
    SnapshotSeed (..),
    SnapshotMissReason (..),
    SnapshotLookup (..),
    lookupSnapshotSeed,
    hydrateWithSnapshot,
    encodeSnapshotStrict,
    writeSnapshotEncoded,
    writeSnapshot,

    -- * State codec and storage
    module Keiro.Snapshot.Codec,
    module Keiro.Snapshot.Schema,
)
where

import Control.DeepSeq (force)
import Control.Exception (ErrorCall, evaluate, try)
import Effectful (Eff, (:>))
import Keiki.Core (RegFile)
import Keiro.EventStream (StateCodec)
import Keiro.Prelude
import Keiro.Snapshot.Codec
import Keiro.Snapshot.Schema
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (lookupStreamId)
import Kiroku.Store.Types (StreamId, StreamName, StreamVersion)

{- | A decoded snapshot the command runner replays forward from: the folded
'state' and 'registers' as of 'streamVersion'. Hydration reads only the
events after 'streamVersion' instead of the entire stream.
-}
data SnapshotSeed rs s = SnapshotSeed
    { state :: !s
    , registers :: !(RegFile rs)
    , streamVersion :: !StreamVersion
    }
    deriving stock (Generic)

-- | Why a snapshot lookup produced no usable hydration seed.
data SnapshotMissReason
    = SnapshotNoStream
    | SnapshotNotFound
    | SnapshotDecodeFailed !Text
    deriving stock (Eq, Show, Generic)

-- | The observable result of looking up and decoding an aggregate snapshot.
data SnapshotLookup rs s
    = SnapshotUnavailable !SnapshotMissReason
    | SnapshotHit !(SnapshotSeed rs s)
    deriving stock (Generic)

{- | Look up the latest compatible snapshot and retain the reason when no
usable seed exists. A matching row that fails to decode is distinguished from
a missing stream or row so callers can report the persistent fallback.
-}
lookupSnapshotSeed ::
    (Store :> es) =>
    StreamName ->
    StateCodec (s, RegFile rs) ->
    Eff es (SnapshotLookup rs s)
lookupSnapshotSeed streamName codec = do
    streamId <- lookupStreamId streamName
    case streamId of
        Nothing -> pure (SnapshotUnavailable SnapshotNoStream)
        Just foundStreamId -> do
            row <-
                lookupSnapshot
                    foundStreamId
                    (codec ^. #stateCodecVersion)
                    (codec ^. #shapeHash)
                    (codec ^. #stateShapeHash)
            pure $ case row of
                Nothing -> SnapshotUnavailable SnapshotNotFound
                Just snapshot ->
                    case (codec ^. #decode) (snapshot ^. #state) of
                        Left message -> SnapshotUnavailable (SnapshotDecodeFailed message)
                        Right (state, registers) ->
                            SnapshotHit
                                SnapshotSeed
                                    { state = state
                                    , registers = registers
                                    , streamVersion = snapshot ^. #streamVersion
                                    }

{- | Load the latest snapshot compatible with @codec@ for the named stream.

Returns 'Nothing' — meaning "replay from the beginning" — when the stream
has no id yet, has no snapshot matching all three codec discriminators, or has
a snapshot whose bytes fail to decode. Decode failure is treated as a benign
miss rather than an error, so a corrupt or stale snapshot never blocks
hydration.
-}
hydrateWithSnapshot ::
    (Store :> es) =>
    StreamName ->
    StateCodec (s, RegFile rs) ->
    Eff es (Maybe (SnapshotSeed rs s))
hydrateWithSnapshot streamName codec = do
    lookupSnapshotSeed streamName codec <&> \case
        SnapshotUnavailable _ -> Nothing
        SnapshotHit seed -> Just seed

{- | Strictly encode @state@ with @codec@, forcing the complete JSON value and
returning an 'ErrorCall' raised by a partial encoder or an uninitialized keiki
register. Other exception types deliberately remain visible to the caller.
-}
encodeSnapshotStrict :: StateCodec state -> state -> IO (Either ErrorCall Value)
encodeSnapshotStrict codec state =
    try @ErrorCall (evaluate (force ((codec ^. #encode) state)))

{- | Upsert a JSON value that has already been encoded and forced. Keeping this
separate from 'writeSnapshot' lets post-commit callers prove encoding is safe
before they touch the store. For fixed codec discriminators, stale versions
are ignored. Any changed discriminator may replace a higher-version row to
permit codec rollback; see the module header.
-}
writeSnapshotEncoded ::
    (Store :> es) =>
    StreamId ->
    StreamVersion ->
    StateCodec state ->
    Value ->
    Eff es ()
writeSnapshotEncoded streamId streamVersion codec encoded =
    writeSnapshotRow
        SnapshotWrite
            { streamId = streamId
            , streamVersion = streamVersion
            , state = encoded
            , stateCodecVersion = codec ^. #stateCodecVersion
            , regfileShapeHash = codec ^. #shapeHash
            , stateShapeHash = codec ^. #stateShapeHash
            }

{- | Encode @state@ with @codec@ and upsert it as the snapshot for the given
stream at @streamVersion@. This compatibility helper preserves the historical
lazy encoding behavior; post-commit advisory paths should call
'encodeSnapshotStrict' first and pass the result to 'writeSnapshotEncoded'. For
fixed codec discriminators stale writes are ignored, while an incompatible
codec may replace a newer row to permit rollback.
-}
writeSnapshot ::
    (Store :> es) =>
    StreamId ->
    StreamVersion ->
    StateCodec state ->
    state ->
    Eff es ()
writeSnapshot streamId streamVersion codec state =
    writeSnapshotEncoded streamId streamVersion codec ((codec ^. #encode) state)
