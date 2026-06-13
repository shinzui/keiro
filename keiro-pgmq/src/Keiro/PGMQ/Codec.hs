{- | How a job payload is turned into PGMQ JSON and back.

PGMQ stores message bodies as JSON ('Data.Aeson.Value'). A 'JobCodec' is the
adapter between a domain payload type @p@ and that JSON. Two are provided:

  * 'aesonJobCodec' - raw @aeson@ encode/decode. A drop-in match for apps that
    already use @ToJSON@/@FromJSON@ payloads, so migrating to @keiro-pgmq@ is
    mechanical.
  * 'keiroJobCodec' - the versioned upgrade. It bridges keiro's
    'Keiro.Codec.Codec' by wrapping payloads in a @{ "v": <version>, "data":
    <payload> }@ envelope and replaying the codec's upcaster chain on decode,
    giving job payloads the same schema-evolution story event streams have.

When raising a 'keiroJobCodec' schema version, deploy upgraded workers before
upgraded producers. A worker that sees an envelope from a future schema version
returns 'JobPayloadFromFuture', and the job runner retries it after the queue's
default retry delay so a rolling deploy can complete. Those retries still
consume delivery attempts, so size @maxRetries * defaultRetryDelay@ to cover
the deploy window.

Do not switch a non-empty queue directly from 'aesonJobCodec' to
'keiroJobCodec': the wire shape changes from the bare payload to the
@{"v","data"}@ envelope. Drain the queue first or use a transitional codec that
accepts both shapes; otherwise old in-flight messages are malformed and will be
dead-lettered.
-}
module Keiro.PGMQ.Codec (
    JobCodec (..),
    JobDecodeError (..),
    mkJobCodec,
    aesonJobCodec,
    keiroJobCodec,
) where

import "aeson" Data.Aeson (FromJSON, ToJSON, Value, object, parseJSON, toJSON, withObject, (.:), (.=))
import "aeson" Data.Aeson.Types (parseEither)
import "base" Data.Bifunctor (first)
import "keiro-core" Keiro.Codec (Codec)
import "keiro-core" Keiro.Codec qualified as Codec
import "text" Data.Text (Text)
import "text" Data.Text qualified as Text

-- | Why a job payload could not be decoded.
data JobDecodeError
    = -- | The payload is malformed for this codec: poison, dead-letter it.
      JobPayloadMalformed !Text
    | {- | The payload was written by a newer schema version than this worker knows.
      Carries payload version, then this codec's version. This is transient
      during a rolling deploy: retry it, do not dead-letter it.
      -}
      JobPayloadFromFuture !Int !Int
    deriving stock (Eq, Show)

-- | How a job payload is turned into PGMQ JSON and back.
data JobCodec p = JobCodec
    { encodeJob :: p -> Value
    , decodeJob :: Value -> Either JobDecodeError p
    }

-- | Build a 'JobCodec' from an encoder and a legacy text-returning decoder.
mkJobCodec :: (p -> Value) -> (Value -> Either Text p) -> JobCodec p
mkJobCodec encode decode =
    JobCodec
        { encodeJob = encode
        , decodeJob = first JobPayloadMalformed . decode
        }

{- | The default codec: raw @aeson@. Use this when the payload type already has
@ToJSON@/@FromJSON@ instances and you do not need versioned schema evolution.
-}
aesonJobCodec :: (ToJSON p, FromJSON p) => JobCodec p
aesonJobCodec = mkJobCodec toJSON (first Text.pack . parseEither parseJSON)

{- | Versioned bridge to keiro's 'Keiro.Codec.Codec'. On encode it produces
@{ "v": <schemaVersion>, "data": <encode codec p> }@; on decode it reads the
version, runs the codec's upcaster chain up to the current version via
'Keiro.Codec.migrateToCurrent', then runs the codec's current decoder. Codec
migration faults are surfaced as 'JobPayloadMalformed' (via 'show' of the
'Keiro.Codec.CodecError'), except for a future envelope version, which surfaces
as 'JobPayloadFromFuture'.
-}
keiroJobCodec :: Codec p -> JobCodec p
keiroJobCodec codec =
    JobCodec
        { encodeJob = \p ->
            object
                [ "v" .= Codec.schemaVersion codec
                , "data" .= Codec.encode codec p
                ]
        , decodeJob = \value -> do
            (version, dataValue) <- parseEnvelope value
            let currentVersion = Codec.schemaVersion codec
            if version > currentVersion
                then Left (JobPayloadFromFuture version currentVersion)
                else pure ()
            migrated <-
                first (JobPayloadMalformed . Text.pack . show) $
                    Codec.migrateToCurrent codec version dataValue
            first JobPayloadMalformed (Codec.decode codec migrated)
        }

-- | Parse the @{ "v", "data" }@ envelope, surfacing aeson failures as malformed payloads.
parseEnvelope :: Value -> Either JobDecodeError (Int, Value)
parseEnvelope =
    first (JobPayloadMalformed . Text.pack) . parseEither parser
  where
    parser = withObject "Keiro.PGMQ.Codec envelope" $ \o -> do
        version <- o .: "v"
        dataValue <- o .: "data"
        pure (version, dataValue)
