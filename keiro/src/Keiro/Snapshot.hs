{- | Snapshots: skipping replay by persisting folded aggregate state.

A snapshot stores an aggregate's @(state, registers)@ at a known stream
version so hydration can start there instead of replaying the whole event
log. 'hydrateWithSnapshot' loads the latest compatible snapshot for a
stream (returning a 'SnapshotSeed' the command runner replays /forward/
from), and 'writeSnapshot' persists one after an append when the stream's
'Keiro.EventStream.SnapshotPolicy' fires.

Compatibility is gated by the version and register-file shape hash of the
'StateCodec': a snapshot is only loaded when both match the current codec, so a
change to the snapshot encoding or to the register layout transparently
falls back to a full replay rather than decoding stale bytes. The JSON
encoding lives in "Keiro.Snapshot.Codec" and the SQL storage in
"Keiro.Snapshot.Schema", both re-exported here.
-}
module Keiro.Snapshot (
    -- * Hydration seed
    SnapshotSeed (..),
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

{- | Load the latest snapshot compatible with @codec@ for the named stream.

Returns 'Nothing' — meaning "replay from the beginning" — when the stream
has no id yet, has no snapshot at the codec's version and shape hash, or has
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
    streamId <- lookupStreamId streamName
    case streamId of
        Nothing -> pure Nothing
        Just foundStreamId -> do
            row <- lookupSnapshot foundStreamId (codec ^. #stateCodecVersion) (codec ^. #shapeHash)
            pure $ do
                snapshot <- row
                (state, registers) <- either (const Nothing) Just ((codec ^. #decode) (snapshot ^. #state))
                pure
                    SnapshotSeed
                        { state = state
                        , registers = registers
                        , streamVersion = snapshot ^. #streamVersion
                        }

{- | Strictly encode @state@ with @codec@, forcing the complete JSON value and
returning an 'ErrorCall' raised by a partial encoder or an uninitialized keiki
register. Other exception types deliberately remain visible to the caller.
-}
encodeSnapshotStrict :: StateCodec state -> state -> IO (Either ErrorCall Value)
encodeSnapshotStrict codec state =
    try @ErrorCall (evaluate (force ((codec ^. #encode) state)))

{- | Upsert a JSON value that has already been encoded and forced. Keeping this
separate from 'writeSnapshot' lets post-commit callers prove encoding is safe
before they touch the store.
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
            }

{- | Encode @state@ with @codec@ and upsert it as the snapshot for the given
stream at @streamVersion@. This compatibility helper preserves the historical
lazy encoding behavior; post-commit advisory paths should call
'encodeSnapshotStrict' first and pass the result to 'writeSnapshotEncoded'.
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
