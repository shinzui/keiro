module Keiro.Codec
  ( Codec (..)
  , Upcaster
  , CodecError (..)
  , encodeForAppend
  , encodeForAppendWithMetadata
  , decodeRecorded
  , decodeRaw
  , migrateToCurrent
  , extractSchemaVersion
  , metadataFor
  )
where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Scientific as Scientific
import qualified Prelude
import Keiro.Prelude
import Kiroku.Store.Types
  ( EventData (..)
  , EventType (..)
  , RecordedEvent (..)
  )

type Upcaster = (Int, Value -> Either Text Value)

data Codec e = Codec
  { eventTypes :: !(NonEmpty Text)
  , eventType :: !(e -> Text)
  , schemaVersion :: !Int
  , encode :: !(e -> Value)
  , decode :: !(Value -> Either Text e)
  , upcasters :: ![Upcaster]
  }
  deriving stock (Generic)

data CodecError
  = UnknownEventType !EventType ![Text]
  | InvalidSchemaVersion !Int
  | UnknownVersion !Int
  | UpcasterError !Int !Text
  | DecodeFailed !Text
  | GapInUpcasterChain !Int !Int
  deriving stock (Generic, Eq, Show)

schemaVersionKey :: Key.Key
schemaVersionKey = "schemaVersion"

encodeForAppend :: Codec e -> e -> Either CodecError EventData
encodeForAppend codec value = encodeForAppendWithMetadata codec Nothing value

encodeForAppendWithMetadata :: Codec e -> Maybe Value -> e -> Either CodecError EventData
encodeForAppendWithMetadata codec metadata value = do
  unless (codec ^. #schemaVersion > 0) $
    Left (InvalidSchemaVersion (codec ^. #schemaVersion))
  let selectedType = codec ^. #eventType $ value
  unless (selectedType `List.elem` NonEmpty.toList (codec ^. #eventTypes)) $
    Left (UnknownEventType (EventType selectedType) (NonEmpty.toList (codec ^. #eventTypes)))
  pure EventData
    { eventId = Nothing
    , eventType = EventType selectedType
    , payload = codec ^. #encode $ value
    , metadata = Just (metadataFor (codec ^. #schemaVersion) metadata)
    , causationId = Nothing
    , correlationId = Nothing
    }

metadataFor :: Int -> Maybe Value -> Value
metadataFor version existing =
  Object $
    baseObject existing
      & KeyMap.insert schemaVersionKey (Number (Prelude.fromIntegral version))
  where
    baseObject (Just (Object object)) = object
    baseObject _ = KeyMap.empty

decodeRecorded :: Codec e -> RecordedEvent -> Either CodecError e
decodeRecorded codec recorded = do
  unless (isKnownEventType (recorded ^. #eventType) codec) $
    Left (UnknownEventType (recorded ^. #eventType) (NonEmpty.toList (codec ^. #eventTypes)))
  decodeRaw codec (extractSchemaVersion recorded) (recorded ^. #payload)

decodeRaw :: Codec e -> Int -> Value -> Either CodecError e
decodeRaw codec version payload = do
  migrated <- migrateToCurrent codec version payload
  case codec ^. #decode $ migrated of
    Right value -> Right value
    Left message -> Left (DecodeFailed message)

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

extractSchemaVersion :: RecordedEvent -> Int
extractSchemaVersion recorded =
  fromMaybe 1 $ do
    Object object <- recorded ^. #metadata
    Number number <- KeyMap.lookup schemaVersionKey object
    Scientific.toBoundedInteger number

isKnownEventType :: EventType -> Codec e -> Bool
isKnownEventType (EventType selectedType) codec =
  selectedType `List.elem` NonEmpty.toList (codec ^. #eventTypes)
