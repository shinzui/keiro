{- | The @keiro_snapshots@ table: persistence for aggregate snapshots.

One row per stream holds the latest snapshot of its folded state as JSONB,
tagged with the 'stateCodecVersion' and 'regfileShapeHash' that produced it.
'lookupSnapshot' fetches the newest row matching a given version and shape
hash (so incompatible snapshots are simply not found); 'writeSnapshotRow'
upserts, keeping only the highest stream version per stream so a late or
out-of-order write cannot regress the snapshot.

This module is the storage layer beneath "Keiro.Snapshot"; callers normally
go through 'Keiro.Snapshot.hydrateWithSnapshot' and
'Keiro.Snapshot.writeSnapshot' rather than these statements directly.
-}
module Keiro.Snapshot.Schema (
    -- * Rows
    SnapshotRow (..),
    SnapshotWrite (..),

    -- * Storage
    lookupSnapshot,
    writeSnapshotRow,
)
where

import Contravariant.Extras (contrazip3, contrazip5)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (StreamId (..), StreamVersion (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

{- | A snapshot row as read back from @keiro_snapshots@: the stored 'state'
JSON, the 'streamVersion' it captures, the 'stateCodecVersion' and
'regfileShapeHash' that gate compatibility, and the create/update
timestamps.
-}
data SnapshotRow = SnapshotRow
    { streamId :: !StreamId
    , streamVersion :: !StreamVersion
    , state :: !Value
    , stateCodecVersion :: !Int
    , regfileShapeHash :: !Text
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)

{- | The fields needed to write a snapshot — 'SnapshotRow' minus the
database-managed timestamps.
-}
data SnapshotWrite = SnapshotWrite
    { streamId :: !StreamId
    , streamVersion :: !StreamVersion
    , state :: !Value
    , stateCodecVersion :: !Int
    , regfileShapeHash :: !Text
    }
    deriving stock (Generic, Eq, Show)

{- | Fetch the latest snapshot for a stream that matches the given codec
version and register-file shape hash. Returns 'Nothing' when no compatible
snapshot exists, so an incompatible one is treated as absent.
-}
lookupSnapshot ::
    (Store :> es) =>
    StreamId ->
    Int ->
    Text ->
    Eff es (Maybe SnapshotRow)
lookupSnapshot streamId version shapeHash =
    runTransaction
        $ Tx.statement
            (streamIdToInt streamId, Prelude.fromIntegral version, shapeHash)
            lookupSnapshotStmt

{- | Upsert a snapshot row for its stream. The write only takes effect when
its 'streamVersion' is at least the stored one, so concurrent or replayed
writes never regress the snapshot to an older version.
-}
writeSnapshotRow ::
    (Store :> es) =>
    SnapshotWrite ->
    Eff es ()
writeSnapshotRow snapshot =
    runTransaction
        $ Tx.statement (snapshotWriteParams snapshot) writeSnapshotStmt

lookupSnapshotStmt :: Statement (Int64, Int64, Text) (Maybe SnapshotRow)
lookupSnapshotStmt =
    preparable
        """
        SELECT stream_id, stream_version, state, state_codec_version, regfile_shape_hash, created_at, updated_at
        FROM keiro_snapshots
        WHERE stream_id = $1
          AND state_codec_version = $2
          AND regfile_shape_hash = $3
        ORDER BY stream_version DESC
        LIMIT 1
        """
        ( contrazip3
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.text))
        )
        (D.rowMaybe snapshotRowDecoder)

writeSnapshotStmt :: Statement (Int64, Int64, Value, Int64, Text) ()
writeSnapshotStmt =
    preparable
        """
        INSERT INTO keiro_snapshots
          (stream_id, stream_version, state, state_codec_version, regfile_shape_hash)
        VALUES
          ($1, $2, $3, $4, $5)
        ON CONFLICT (stream_id) DO UPDATE
          SET stream_version = EXCLUDED.stream_version,
              state = EXCLUDED.state,
              state_codec_version = EXCLUDED.state_codec_version,
              regfile_shape_hash = EXCLUDED.regfile_shape_hash,
              updated_at = now()
          WHERE keiro_snapshots.stream_version <= EXCLUDED.stream_version
             OR keiro_snapshots.state_codec_version <> EXCLUDED.state_codec_version
             OR keiro_snapshots.regfile_shape_hash <> EXCLUDED.regfile_shape_hash
        """
        ( contrazip5
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.jsonb))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

snapshotRowDecoder :: D.Row SnapshotRow
snapshotRowDecoder =
    SnapshotRow
        <$> (StreamId <$> D.column (D.nonNullable D.int8))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.jsonb)
        <*> (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

streamIdToInt :: StreamId -> Int64
streamIdToInt (StreamId value) = value

streamVersionToInt :: StreamVersion -> Int64
streamVersionToInt (StreamVersion value) = value

snapshotWriteParams :: SnapshotWrite -> (Int64, Int64, Value, Int64, Text)
snapshotWriteParams snapshot =
    ( streamIdToInt (snapshot ^. #streamId)
    , streamVersionToInt (snapshot ^. #streamVersion)
    , snapshot ^. #state
    , Prelude.fromIntegral (snapshot ^. #stateCodecVersion)
    , snapshot ^. #regfileShapeHash
    )
