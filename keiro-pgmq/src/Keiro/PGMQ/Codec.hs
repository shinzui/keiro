{- | How a job payload is turned into PGMQ JSON and back.

PGMQ stores message bodies as JSON ('Data.Aeson.Value'). A 'JobCodec' is the
adapter between a domain payload type @p@ and that JSON. Two are provided:

  * 'aesonJobCodec' — raw @aeson@ encode/decode. A drop-in match for apps that
    already use @ToJSON@/@FromJSON@ payloads, so migrating to @keiro-pgmq@ is
    mechanical.
  * 'keiroJobCodec' — the versioned upgrade. It bridges keiro's
    'Keiro.Codec.Codec' by wrapping payloads in a @{ "v": <version>, "data":
    <payload> }@ envelope and replaying the codec's upcaster chain on decode,
    giving job payloads the same schema-evolution story event streams have.
-}
module Keiro.PGMQ.Codec (
    JobCodec (..),
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

-- | How a job payload is turned into PGMQ JSON and back.
data JobCodec p = JobCodec
    { encodeJob :: p -> Value
    , decodeJob :: Value -> Either Text p
    }

{- | The default codec: raw @aeson@. Use this when the payload type already has
@ToJSON@/@FromJSON@ instances and you do not need versioned schema evolution.
-}
aesonJobCodec :: (ToJSON p, FromJSON p) => JobCodec p
aesonJobCodec =
    JobCodec
        { encodeJob = toJSON
        , decodeJob = first Text.pack . parseEither parseJSON
        }

{- | Versioned bridge to keiro's 'Keiro.Codec.Codec'. On encode it produces
@{ "v": <schemaVersion>, "data": <encode codec p> }@; on decode it reads the
version, runs the codec's upcaster chain up to the current version via
'Keiro.Codec.migrateToCurrent', then runs the codec's current decoder. Codec
migration faults are surfaced as 'Text' (via 'show' of the 'Keiro.Codec.CodecError').
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
            migrated <-
                first (Text.pack . show) (Codec.migrateToCurrent codec version dataValue)
            Codec.decode codec migrated
        }

-- | Parse the @{ "v", "data" }@ envelope, surfacing aeson failures as 'Text'.
parseEnvelope :: Value -> Either Text (Int, Value)
parseEnvelope =
    first Text.pack . parseEither parser
  where
    parser = withObject "Keiro.PGMQ.Codec envelope" $ \o -> do
        version <- o .: "v"
        dataValue <- o .: "data"
        pure (version, dataValue)
