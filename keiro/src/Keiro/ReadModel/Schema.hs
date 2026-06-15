{- | The @keiro_read_models@ registry: schema identity and lifecycle status.

Every read model registers a row recording its 'version', 'shapeHash', and
'ReadModelStatus'. The registry is what lets 'Keiro.ReadModel.runQuery'
refuse to serve a model whose code-side schema has drifted from the table on
disk, or one that is mid-rebuild. The status transitions ('markRebuilding',
'markLive', 'markAbandoned') drive the rebuild workflow in
"Keiro.ReadModel.Rebuild".

All operations run as single-statement 'Hasql.Transaction.Transaction's
against the @keiro_read_models@ table; an unrecognized stored status decodes
to 'UnknownStatus' so callers see the raw database value instead of a silent
fallback.
-}
module Keiro.ReadModel.Schema (
    -- * Metadata
    ReadModelMetadata (..),
    ReadModelStatus (..),

    -- * Registration and lookup
    registerReadModel,
    lookupReadModel,

    -- * Status transitions
    markRebuilding,
    markLive,
    markAbandoned,
)
where

import Contravariant.Extras (contrazip3, contrazip4)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

{- | Lifecycle status of a registered read model.

* 'Live' — current and queryable.
* 'Rebuilding' — being repopulated from the event log; not yet queryable.
* 'Paused' — temporarily not served.
* 'Abandoned' — a rebuild that was given up on.
* 'UnknownStatus' — a database value this library version does not recognize.
-}
data ReadModelStatus
    = Live
    | Rebuilding
    | Paused
    | Abandoned
    | UnknownStatus !Text
    deriving stock (Generic, Eq, Show)

{- | One row of the @keiro_read_models@ registry: a model's name, schema
identity ('version' and 'shapeHash'), the time it was last (re)built, and
its current 'status'.
-}
data ReadModelMetadata = ReadModelMetadata
    { name :: !Text
    , version :: !Int
    , shapeHash :: !Text
    , lastBuiltAt :: !(Maybe UTCTime)
    , status :: !ReadModelStatus
    }
    deriving stock (Generic, Eq, Show)

{- | Register a read model, inserting a 'Live' row if none exists. Idempotent:
an existing registration is returned unchanged (the @version@ and
@shapeHash@ are /not/ overwritten), so a query can compare them and detect
schema drift.
-}
registerReadModel :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
registerReadModel name version shapeHash =
    runTransaction
        $ Tx.statement
            (name, Prelude.fromIntegral version, shapeHash)
            registerReadModelStmt

-- | Look up a read model's registry row by name, if it exists.
lookupReadModel :: (Store :> es) => Text -> Eff es (Maybe ReadModelMetadata)
lookupReadModel name =
    runTransaction
        $ Tx.statement name lookupReadModelStmt

{- | Upsert the registry row to 'Rebuilding' at the given schema identity.
Marks the model as being repopulated so queries stop serving it until
'markLive'.
-}
markRebuilding :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
markRebuilding name version shapeHash =
    runTransaction
        $ Tx.statement
            (name, Prelude.fromIntegral version, shapeHash, statusToText Rebuilding)
            transitionReadModelStmt

{- | Upsert the registry row to 'Live' at the given schema identity, stamping
@last_built_at@. Makes the model queryable again after a rebuild.
-}
markLive :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
markLive name version shapeHash =
    runTransaction
        $ Tx.statement
            (name, Prelude.fromIntegral version, shapeHash, statusToText Live)
            transitionReadModelStmt

{- | Upsert the registry row to 'Abandoned' at the given schema identity,
recording that a rebuild was given up on.
-}
markAbandoned :: (Store :> es) => Text -> Int -> Text -> Eff es ReadModelMetadata
markAbandoned name version shapeHash =
    runTransaction
        $ Tx.statement
            (name, Prelude.fromIntegral version, shapeHash, statusToText Abandoned)
            transitionReadModelStmt

registerReadModelStmt :: Statement (Text, Int64, Text) ReadModelMetadata
registerReadModelStmt =
    preparable
        """
        INSERT INTO keiro_read_models (name, version, shape_hash, status, last_built_at)
        VALUES ($1, $2, $3, 'live', now())
        ON CONFLICT (name) DO UPDATE
          SET name = EXCLUDED.name
        RETURNING name, version, shape_hash, last_built_at, status
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
    UnknownStatus raw -> raw

statusFromText :: Text -> ReadModelStatus
statusFromText = \case
    "live" -> Live
    "rebuilding" -> Rebuilding
    "paused" -> Paused
    "abandoned" -> Abandoned
    raw -> UnknownStatus raw
