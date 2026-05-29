module Keiro.ReadModel.Schema
  ( ReadModelMetadata (..)
  , ReadModelStatus (..)
  , registerReadModel
  , lookupReadModel
  , markRebuilding
  , markLive
  , markAbandoned
  )
where

import Contravariant.Extras (contrazip3, contrazip4)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Prelude qualified

data ReadModelStatus
  = Live
  | Rebuilding
  | Paused
  | Abandoned
  deriving stock (Generic, Eq, Show)

data ReadModelMetadata = ReadModelMetadata
  { name :: !Text
  , version :: !Int
  , shapeHash :: !Text
  , lastBuiltAt :: !(Maybe UTCTime)
  , status :: !ReadModelStatus
  }
  deriving stock (Generic, Eq, Show)

registerReadModel :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
registerReadModel name version shapeHash =
  runTransaction $
    Tx.statement
      (name, Prelude.fromIntegral version, shapeHash)
      registerReadModelStmt

lookupReadModel :: (Store :> es) => Text -> Eff es (Maybe ReadModelMetadata)
lookupReadModel name =
  runTransaction $
    Tx.statement name lookupReadModelStmt

markRebuilding :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
markRebuilding name version shapeHash =
  runTransaction $
    Tx.statement
      (name, Prelude.fromIntegral version, shapeHash, statusToText Rebuilding)
      transitionReadModelStmt

markLive :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
markLive name version shapeHash =
  runTransaction $
    Tx.statement
      (name, Prelude.fromIntegral version, shapeHash, statusToText Live)
      transitionReadModelStmt

markAbandoned :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
markAbandoned name version shapeHash =
  runTransaction $
    Tx.statement
      (name, Prelude.fromIntegral version, shapeHash, statusToText Abandoned)
      transitionReadModelStmt

registerReadModelStmt :: Statement (Text, Int64, Text) ReadModelMetadata
registerReadModelStmt =
  preparable
    """
    WITH inserted AS (
      INSERT INTO keiro_read_models (name, version, shape_hash, status, last_built_at)
      VALUES ($1, $2, $3, 'live', now())
      ON CONFLICT (name) DO NOTHING
      RETURNING name, version, shape_hash, last_built_at, status
    )
    SELECT name, version, shape_hash, last_built_at, status
    FROM inserted
    UNION ALL
    SELECT name, version, shape_hash, last_built_at, status
    FROM keiro_read_models
    WHERE name = $1
    LIMIT 1
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
    )
    readModelMetadataSingle

lookupReadModelStmt :: Statement Text (Maybe ReadModelMetadata)
lookupReadModelStmt =
  preparable
    """
    SELECT name, version, shape_hash, last_built_at, status
    FROM keiro_read_models
    WHERE name = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe readModelMetadataDecoder)

transitionReadModelStmt :: Statement (Text, Int64, Text, Text) ReadModelMetadata
transitionReadModelStmt =
  preparable
    """
    INSERT INTO keiro_read_models (name, version, shape_hash, status, last_built_at, updated_at)
    VALUES ($1, $2, $3, $4, now(), now())
    ON CONFLICT (name) DO UPDATE
      SET version = EXCLUDED.version,
          shape_hash = EXCLUDED.shape_hash,
          status = EXCLUDED.status,
          last_built_at = CASE
            WHEN EXCLUDED.status = 'live' THEN now()
            ELSE keiro_read_models.last_built_at
          END,
          updated_at = now()
    RETURNING name, version, shape_hash, last_built_at, status
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    readModelMetadataSingle

readModelMetadataSingle :: D.Result ReadModelMetadata
readModelMetadataSingle =
  D.singleRow readModelMetadataDecoder

readModelMetadataDecoder :: D.Row ReadModelMetadata
readModelMetadataDecoder =
  ReadModelMetadata
    <$> D.column (D.nonNullable D.text)
    <*> (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> (statusFromText <$> D.column (D.nonNullable D.text))

statusToText :: ReadModelStatus -> Text
statusToText = \case
  Live -> "live"
  Rebuilding -> "rebuilding"
  Paused -> "paused"
  Abandoned -> "abandoned"

statusFromText :: Text -> ReadModelStatus
statusFromText = \case
  "live" -> Live
  "rebuilding" -> Rebuilding
  "paused" -> Paused
  "abandoned" -> Abandoned
  _ -> Paused
