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
Decoding additionally surfaces migration faults: a missing rung in the
upcaster chain ('GapInUpcasterChain'), an upcaster that rejected its input
('UpcasterError'), a stored future version ('VersionAhead'), an out-of-range
stored version ('UnknownVersion'), or a payload the current decoder rejects
('DecodeFailed').
-}
module Keiro.Codec (
    -- * Codec
    Codec (..),
    Upcaster,
    EventType (..),
    CodecError (..),
    CodecConfigError (..),
    mkCodec,

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
import Data.Maybe qualified as Maybe
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
into the version-@(n+1)@ shape. The stored event-type tag is supplied so
multi-event codecs can migrate by the authoritative wire tag rather than a
payload discriminator. A migration may reject malformed input with a 'Left'.
-}
type Upcaster = (Int, EventType -> Value -> Either Text Value)

{- | Everything a stream needs to serialize and deserialize its events.

* 'eventTypes' - the complete set of event-type tags this codec owns.
  Encoding and decoding reject any tag outside this set, so it doubles as
  the stream's event-type allow-list.
* 'eventType' - projects a domain value to its wire tag (must land in
  'eventTypes').
* 'schemaVersion' - the current payload version; must be @>= 1@. Stamped
  into event metadata on append and used as the migration target on read.
* 'encode' / 'decode' - the current-version JSON serialization. 'decode'
  receives the stored event-type tag and only sees payloads already migrated
  to 'schemaVersion'.
* 'upcasters' - migrations keyed by source version. To read a
  version-@n@ payload the codec applies the @n@, @n+1@, ... rungs in
  sequence until it reaches 'schemaVersion'; a missing rung is a
  'GapInUpcasterChain' or 'IncompleteUpcasterChain'.
-}
data Codec e = Codec
    { eventTypes :: !(NonEmpty EventType)
    , eventType :: !(e -> EventType)
    , schemaVersion :: !Int
    , encode :: !(e -> Value)
    , decode :: !(EventType -> Value -> Either Text e)
    , upcasters :: ![Upcaster]
    }
    deriving stock (Generic)

-- | Why an encode or decode could not be completed.
data CodecError
    = {- | The event-type tag is not one of the codec's 'eventTypes' (carries
      the offending tag and the allowed set).
      -}
      UnknownEventType !EventType ![EventType]
    | -- | The codec's 'schemaVersion' is not @>= 1@.
      InvalidSchemaVersion !Int
    | -- | A stored payload declared a version below @1@.
      UnknownVersion !Int
    | -- | A stored payload was written by a newer codec version.
      VersionAhead !Int !Int
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
    | -- | The upcaster chain ended before reaching the codec's target version.
      IncompleteUpcasterChain !Int !Int
    | -- | A present schema-version stamp was malformed.
      MalformedSchemaVersionStamp !Value
    | -- | Caller-supplied metadata was not a JSON object.
      NonObjectCallerMetadata !Value
    deriving stock (Generic, Eq, Show)

-- | Why a raw 'Codec' record did not satisfy the construction invariants.
data CodecConfigError
    = CodecSchemaVersionInvalid !Int
    | CodecDuplicateEventTypes ![EventType]
    | CodecDuplicateUpcasterSources ![Int]
    | CodecUpcasterSourceOutOfRange !Int !Int
    | CodecUpcasterChainIncomplete ![Int] !Int
    deriving stock (Generic, Eq, Show)

schemaVersionKey :: Key.Key
schemaVersionKey = "schemaVersion"

{- | Validate a raw 'Codec' record before exposing it to runtime use.

The raw 'Codec' constructor remains exported as an escape hatch for tests and
low-level callers, but production definitions should prefer 'mkCodec' so
misconfigured schema versions and upcaster chains fail at construction time.
-}
mkCodec :: Codec e -> Either CodecConfigError (Codec e)
mkCodec codec
    | codec ^. #schemaVersion < 1 =
        Left (CodecSchemaVersionInvalid (codec ^. #schemaVersion))
    | Prelude.not (Prelude.null duplicateTypes) =
        Left (CodecDuplicateEventTypes duplicateTypes)
    | Prelude.not (Prelude.null duplicateSources) =
        Left (CodecDuplicateUpcasterSources duplicateSources)
    | Just source <- outOfRangeSource =
        Left (CodecUpcasterSourceOutOfRange source (codec ^. #schemaVersion))
    | Prelude.not (Prelude.null missingSources) =
        Left (CodecUpcasterChainIncomplete missingSources (codec ^. #schemaVersion))
    | otherwise =
        Right codec
  where
    sources = List.sort [source | (source, _) <- codec ^. #upcasters]
    expectedSources = [1 .. (codec ^. #schemaVersion) Prelude.- 1]
    duplicateTypes = duplicates (NonEmpty.toList (codec ^. #eventTypes))
    duplicateSources = duplicates sources
    outOfRangeSource =
        List.find
            (\source -> source < 1 Prelude.|| source >= codec ^. #schemaVersion)
            sources
    missingSources = expectedSources List.\\ sources

duplicates :: (Ord a) => [a] -> [a]
duplicates =
    Maybe.mapMaybe duplicateHead
        . List.group
        . List.sort
  where
    duplicateHead (x : _ : _) = Just x
    duplicateHead _ = Nothing

{- | Encode a domain event into 'EventData' ready for append, stamping the
codec's 'schemaVersion' into fresh metadata. Equivalent to
'encodeForAppendWithMetadata' with no caller metadata.
-}
encodeForAppend :: Codec e -> e -> Either CodecError EventData
encodeForAppend codec value = encodeForAppendWithMetadata codec Nothing value

{- | Encode a domain event into 'EventData', merging the codec's
'schemaVersion' into the supplied metadata object (if any).

Fails with 'InvalidSchemaVersion' when the codec's version is not @>= 1@,
'UnknownEventType' when 'eventType' produces a tag outside 'eventTypes', or
'NonObjectCallerMetadata' when the caller supplies non-object metadata. The
schema-version key always wins over any clashing key in the caller's metadata
so the stamp on disk is authoritative.
-}
encodeForAppendWithMetadata :: Codec e -> Maybe Value -> e -> Either CodecError EventData
encodeForAppendWithMetadata codec metadata value = do
    unless (codec ^. #schemaVersion > 0)
        $ Left (InvalidSchemaVersion (codec ^. #schemaVersion))
    let selectedType = codec ^. #eventType $ value
    unless (selectedType `List.elem` NonEmpty.toList (codec ^. #eventTypes))
        $ Left (UnknownEventType selectedType (NonEmpty.toList (codec ^. #eventTypes)))
    stampedMetadata <- metadataFor (codec ^. #schemaVersion) metadata
    pure
        EventData
            { eventId = Nothing
            , eventType = selectedType
            , payload = codec ^. #encode $ value
            , metadata = Just stampedMetadata
            , causationId = Nothing
            , correlationId = Nothing
            }

{- | Build the metadata object stored alongside an event, inserting the schema
version under the @schemaVersion@ key. A non-object @existing@ value is rejected
with 'NonObjectCallerMetadata'.
-}
metadataFor :: Int -> Maybe Value -> Either CodecError Value
metadataFor version existing =
    case existing of
        Just object@(Object _) ->
            Right (insertVersion object)
        Nothing ->
            Right (insertVersion (Object KeyMap.empty))
        Just value ->
            Left (NonObjectCallerMetadata value)
  where
    insertVersion (Object object) =
        Object
            $ object
            & KeyMap.insert schemaVersionKey (Number (Prelude.fromIntegral version))
    insertVersion value = value

{- | Decode a stored 'RecordedEvent' into a domain value. Reads the schema
version stamped in the event's metadata (defaulting to @1@ when absent),
migrates the payload up to the codec's current version, then runs 'decode'.
Rejects events whose type tag is not in 'eventTypes'.
-}
decodeRecorded :: Codec e -> RecordedEvent -> Either CodecError e
decodeRecorded codec recorded = do
    unless (isKnownEventType (recorded ^. #eventType) codec)
        $ Left (UnknownEventType (recorded ^. #eventType) (NonEmpty.toList (codec ^. #eventTypes)))
    version <- extractSchemaVersion recorded
    decodeRaw codec (recorded ^. #eventType) version (recorded ^. #payload)

{- | Decode a raw JSON payload whose source schema version and event type are
already known. Migrates from @version@ to the codec's current version and runs
'decode'. Useful when the version comes from somewhere other than
recorded-event metadata (e.g. a snapshot, job envelope, or replay tool).
-}
decodeRaw :: Codec e -> EventType -> Int -> Value -> Either CodecError e
decodeRaw codec selectedType version payload = do
    unless (isKnownEventType selectedType codec)
        $ Left (UnknownEventType selectedType (NonEmpty.toList (codec ^. #eventTypes)))
    migrated <- migrateToCurrent codec selectedType version payload
    case (codec ^. #decode) selectedType migrated of
        Right value -> Right value
        Left message -> Left (DecodeFailed message)

{- | Replay the upcaster chain to bring a payload from @sourceVersion@ up to
the codec's current 'schemaVersion'.

A payload exactly at the current version is returned unchanged. A payload from a
future version fails with 'VersionAhead'. Each step looks up the upcaster keyed
by the current version and applies it; the walk stops with
'GapInUpcasterChain' if a later rung exists but an earlier rung is missing,
'IncompleteUpcasterChain' if the chain ends early, 'UpcasterError' if a
migration rejects its input, or 'UnknownVersion' for a source version below @1@.
-}
migrateToCurrent :: Codec e -> EventType -> Int -> Value -> Either CodecError Value
migrateToCurrent codec selectedType sourceVersion payload
    | sourceVersion == codec ^. #schemaVersion = Right payload
    | sourceVersion > codec ^. #schemaVersion = Left (VersionAhead sourceVersion (codec ^. #schemaVersion))
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
                        Nothing -> Left (IncompleteUpcasterChain version (codec ^. #schemaVersion))
                Just upcast ->
                    case upcast selectedType current of
                        Left message -> Left (UpcasterError version message)
                        Right next -> go (version Prelude.+ 1) next

    nextChainStart version =
        case [next | (next, _) <- codec ^. #upcasters, next > version] of
            next : _ -> Just next
            [] -> Nothing

{- | Read the schema version stamped into a recorded event's metadata. Defaults
to @1@ when metadata is absent or the object lacks the @schemaVersion@ key.
Present-but-malformed metadata fails with 'MalformedSchemaVersionStamp'.
-}
extractSchemaVersion :: RecordedEvent -> Either CodecError Int
extractSchemaVersion recorded =
    case recorded ^. #metadata of
        Nothing -> Right 1
        Just (Object object) ->
            case KeyMap.lookup schemaVersionKey object of
                Nothing -> Right 1
                Just stamp@(Number number) ->
                    maybe
                        (Left (MalformedSchemaVersionStamp stamp))
                        Right
                        (Scientific.toBoundedInteger number)
                Just stamp -> Left (MalformedSchemaVersionStamp stamp)
        Just metadata -> Left (MalformedSchemaVersionStamp metadata)

isKnownEventType :: EventType -> Codec e -> Bool
isKnownEventType selectedType codec =
    selectedType `List.elem` NonEmpty.toList (codec ^. #eventTypes)
