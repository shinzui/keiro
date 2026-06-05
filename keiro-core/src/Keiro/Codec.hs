{- | Versioned encode/decode contract between a domain event type and its
stored JSON payload.

A 'Codec' is the single place a stream declares how its events are named,
serialized, and migrated. It pairs a current 'schemaVersion' with a chain
of 'Upcaster's so that payloads written under older versions are
transparently brought up to the current shape on read. Producers call
'encodeForAppend' (which stamps the schema version into event metadata);
consumers call 'decodeRecorded', which reads that stamp back, replays the
upcaster chain via 'migrateToCurrent', and then runs the current 'decode'.

Encoding can fail only with a misconfigured codec ('InvalidSchemaVersion')
or an event whose type tag is not in 'eventTypes' ('UnknownEventType').
Decoding additionally surfaces migration faults — a missing rung in the
upcaster chain ('GapInUpcasterChain'), an upcaster that rejected its input
('UpcasterError'), an out-of-range stored version ('UnknownVersion'), or a
payload the current decoder rejects ('DecodeFailed').
-}
module Keiro.Codec (
    -- * Codec
    Codec (..),
    Upcaster,
    CodecError (..),

    -- * Encoding
    encodeForAppend,
    encodeForAppendWithMetadata,

    -- * Decoding
    decodeRecorded,
    decodeRaw,
    migrateToCurrent,

    -- * Metadata helpers
    extractSchemaVersion,
    metadataFor,
)
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Scientific qualified as Scientific
import Keiro.Prelude
import Kiroku.Store.Types (
    EventData (..),
    EventType (..),
    RecordedEvent (..),
 )
import Prelude qualified

{- | One rung of an upcaster chain: the source schema version it upgrades
/from/, paired with a pure migration that rewrites a version-@n@ payload
into the version-@(n+1)@ shape. A migration may reject malformed input
with a 'Left'.
-}
type Upcaster = (Int, Value -> Either Text Value)

{- | Everything a stream needs to serialize and deserialize its events.

* 'eventTypes' — the complete set of event-type tags this codec owns.
  Encoding and decoding reject any tag outside this set, so it doubles as
  the stream's event-type allow-list.
* 'eventType' — projects a domain value to its wire tag (must land in
  'eventTypes').
* 'schemaVersion' — the current payload version; must be @>= 1@. Stamped
  into event metadata on append and used as the migration target on read.
* 'encode' \/ 'decode' — the current-version JSON serialization. 'decode'
  only ever sees payloads already migrated to 'schemaVersion'.
* 'upcasters' — migrations keyed by source version. To read a
  version-@n@ payload the codec applies the @n@, @n+1@, … rungs in
  sequence until it reaches 'schemaVersion'; a missing rung is a
  'GapInUpcasterChain'.
-}
data Codec e = Codec
    { eventTypes :: !(NonEmpty Text)
    , eventType :: !(e -> Text)
    , schemaVersion :: !Int
    , encode :: !(e -> Value)
    , decode :: !(Value -> Either Text e)
    , upcasters :: ![Upcaster]
    }
    deriving stock (Generic)

-- | Why an encode or decode could not be completed.
data CodecError
    = {- | The event-type tag is not one of the codec's 'eventTypes' (carries
      the offending tag and the allowed set).
      -}
      UnknownEventType !EventType ![Text]
    | -- | The codec's 'schemaVersion' is not @>= 1@.
      InvalidSchemaVersion !Int
    | {- | A stored payload declared a version the chain cannot reach (e.g.
      @< 1@, or beyond the available upcasters).
      -}
      UnknownVersion !Int
    | {- | An upcaster rejected its input; carries the source version and the
      migration's error message.
      -}
      UpcasterError !Int !Text
    | -- | The current 'decode' rejected an already-migrated payload.
      DecodeFailed !Text
    | {- | The upcaster chain is missing a rung: migration reached version
      @n@ but the next available upcaster starts at a later version.
      -}
      GapInUpcasterChain !Int !Int
    deriving stock (Generic, Eq, Show)

schemaVersionKey :: Key.Key
schemaVersionKey = "schemaVersion"

{- | Encode a domain event into 'EventData' ready for append, stamping the
codec's 'schemaVersion' into fresh metadata. Equivalent to
'encodeForAppendWithMetadata' with no caller metadata.
-}
encodeForAppend :: Codec e -> e -> Either CodecError EventData
encodeForAppend codec value = encodeForAppendWithMetadata codec Nothing value

{- | Encode a domain event into 'EventData', merging the codec's
'schemaVersion' into the supplied metadata object (if any).

Fails with 'InvalidSchemaVersion' when the codec's version is not @>= 1@,
or 'UnknownEventType' when 'eventType' produces a tag outside
'eventTypes'. The schema-version key always wins over any clashing key in
the caller's metadata so the stamp on disk is authoritative.
-}
encodeForAppendWithMetadata :: Codec e -> Maybe Value -> e -> Either CodecError EventData
encodeForAppendWithMetadata codec metadata value = do
    unless (codec ^. #schemaVersion > 0)
        $ Left (InvalidSchemaVersion (codec ^. #schemaVersion))
    let selectedType = codec ^. #eventType $ value
    unless (selectedType `List.elem` NonEmpty.toList (codec ^. #eventTypes))
        $ Left (UnknownEventType (EventType selectedType) (NonEmpty.toList (codec ^. #eventTypes)))
    pure
        EventData
            { eventId = Nothing
            , eventType = EventType selectedType
            , payload = codec ^. #encode $ value
            , metadata = Just (metadataFor (codec ^. #schemaVersion) metadata)
            , causationId = Nothing
            , correlationId = Nothing
            }

{- | Build the metadata object stored alongside an event, inserting the
schema version under the @schemaVersion@ key. A non-object @existing@
value is discarded and replaced with a fresh object carrying just the
version.
-}
metadataFor :: Int -> Maybe Value -> Value
metadataFor version existing =
    Object
        $ baseObject existing
        & KeyMap.insert schemaVersionKey (Number (Prelude.fromIntegral version))
  where
    baseObject (Just (Object object)) = object
    baseObject _ = KeyMap.empty

{- | Decode a stored 'RecordedEvent' into a domain value. Reads the schema
version stamped in the event's metadata (defaulting to @1@ when absent),
migrates the payload up to the codec's current version, then runs
'decode'. Rejects events whose type tag is not in 'eventTypes'.
-}
decodeRecorded :: Codec e -> RecordedEvent -> Either CodecError e
decodeRecorded codec recorded = do
    unless (isKnownEventType (recorded ^. #eventType) codec)
        $ Left (UnknownEventType (recorded ^. #eventType) (NonEmpty.toList (codec ^. #eventTypes)))
    decodeRaw codec (extractSchemaVersion recorded) (recorded ^. #payload)

{- | Decode a raw JSON payload whose source schema version is already
known. Migrates from @version@ to the codec's current version and runs
'decode'. Useful when the version comes from somewhere other than
recorded-event metadata (e.g. a snapshot or a replay tool).
-}
decodeRaw :: Codec e -> Int -> Value -> Either CodecError e
decodeRaw codec version payload = do
    migrated <- migrateToCurrent codec version payload
    case codec ^. #decode $ migrated of
        Right value -> Right value
        Left message -> Left (DecodeFailed message)

{- | Replay the upcaster chain to bring a payload from @sourceVersion@ up
to the codec's current 'schemaVersion'.

A payload already at or beyond the current version is returned unchanged.
Each step looks up the upcaster keyed by the current version and applies
it; the walk stops with 'GapInUpcasterChain' if a rung is missing,
'UpcasterError' if a migration rejects its input, or 'UnknownVersion' for
a source version below @1@.
-}
migrateToCurrent :: Codec e -> Int -> Value -> Either CodecError Value
migrateToCurrent codec sourceVersion payload
    | sourceVersion >= codec ^. #schemaVersion = Right payload
    | sourceVersion < 1 = Left (UnknownVersion sourceVersion)
    | otherwise = go sourceVersion payload
  where
    go version current
        | version >= codec ^. #schemaVersion = Right current
        | otherwise =
            case Prelude.lookup version (codec ^. #upcasters) of
                Nothing ->
                    case nextChainStart version of
                        Just nextVersion -> Left (GapInUpcasterChain version nextVersion)
                        Nothing -> Left (UnknownVersion version)
                Just upcast ->
                    case upcast current of
                        Left message -> Left (UpcasterError version message)
                        Right next -> go (version Prelude.+ 1) next

    nextChainStart version =
        case [next | (next, _) <- codec ^. #upcasters, next > version] of
            next : _ -> Just next
            [] -> Nothing

{- | Read the schema version stamped into a recorded event's metadata.
Defaults to @1@ when the metadata is absent, is not an object, lacks the
@schemaVersion@ key, or holds a value that is not a bounded integer.
-}
extractSchemaVersion :: RecordedEvent -> Int
extractSchemaVersion recorded =
    fromMaybe 1 $ do
        Object object <- recorded ^. #metadata
        Number number <- KeyMap.lookup schemaVersionKey object
        Scientific.toBoundedInteger number

isKnownEventType :: EventType -> Codec e -> Bool
isKnownEventType (EventType selectedType) codec =
    selectedType `List.elem` NonEmpty.toList (codec ^. #eventTypes)
