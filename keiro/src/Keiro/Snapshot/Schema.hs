module Keiro.Snapshot.Schema
  ( SnapshotRow (..)
  , SnapshotWrite (..)
  , initializeSnapshotSchema
  , lookupSnapshot
  , writeSnapshotRow
  )
where

import Contravariant.Extras (contrazip3, contrazip5)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (StreamId (..), StreamVersion (..))
import Prelude qualified

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

data SnapshotWrite = SnapshotWrite
  { streamId :: !StreamId
  , streamVersion :: !StreamVersion
  , state :: !Value
  , stateCodecVersion :: !Int
  , regfileShapeHash :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Compatibility helper for development and tests.
--
-- Production deployments should run @keiro-migrate@ before application startup.
initializeSnapshotSchema :: (Store :> es) => Eff es ()
initializeSnapshotSchema =
  runTransaction $
    Tx.sql
      """
      CREATE TABLE IF NOT EXISTS keiro_snapshots (
        stream_id BIGINT PRIMARY KEY,
        stream_version BIGINT NOT NULL,
        state JSONB NOT NULL,
        state_codec_version BIGINT NOT NULL,
        regfile_shape_hash TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS keiro_snapshots_compat_idx
        ON keiro_snapshots (stream_id, state_codec_version, regfile_shape_hash, stream_version DESC);
      """

lookupSnapshot ::
  (Store :> es) =>
  StreamId ->
  Int ->
  Text ->
  Eff es (Maybe SnapshotRow)
lookupSnapshot streamId version shapeHash =
  runTransaction $
    Tx.statement
      (streamIdToInt streamId, Prelude.fromIntegral version, shapeHash)
      lookupSnapshotStmt

writeSnapshotRow ::
  (Store :> es) =>
  SnapshotWrite ->
  Eff es ()
writeSnapshotRow snapshot =
  runTransaction $
    Tx.statement (snapshotWriteParams snapshot) writeSnapshotStmt

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
