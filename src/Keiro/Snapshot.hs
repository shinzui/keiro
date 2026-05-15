module Keiro.Snapshot
  ( SnapshotSeed (..)
  , hydrateWithSnapshot
  , writeSnapshot
  , module Keiro.Snapshot.Codec
  , module Keiro.Snapshot.Schema
  )
where

import Effectful (Eff, (:>))
import Keiki.Core (RegFile)
import Keiro.EventStream (StateCodec)
import Keiro.Prelude
import Keiro.Snapshot.Codec
import Keiro.Snapshot.Schema
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (lookupStreamId)
import Kiroku.Store.Types (StreamId, StreamName, StreamVersion)

data SnapshotSeed rs s = SnapshotSeed
  { state :: !s
  , registers :: !(RegFile rs)
  , streamVersion :: !StreamVersion
  }
  deriving stock (Generic)

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
      row <- lookupSnapshot foundStreamId (codec ^. #schemaVersion) (codec ^. #shapeHash)
      pure $ do
        snapshot <- row
        (state, registers) <- either (const Nothing) Just ((codec ^. #decode) (snapshot ^. #state))
        pure SnapshotSeed
          { state = state
          , registers = registers
          , streamVersion = snapshot ^. #streamVersion
          }

writeSnapshot ::
  (Store :> es) =>
  StreamId ->
  StreamVersion ->
  StateCodec state ->
  state ->
  Eff es ()
writeSnapshot streamId streamVersion codec state =
  writeSnapshotRow SnapshotWrite
    { streamId = streamId
    , streamVersion = streamVersion
    , state = (codec ^. #encode) state
    , stateCodecVersion = codec ^. #schemaVersion
    , regfileShapeHash = codec ^. #shapeHash
    }
