-- | Additive process-manager reactions with target-keyed dispatch identity.
--
-- Reaction dispatches deliberately use a distinct UUIDv5 family from both the
-- positional process-manager ids and router ids. The physical target stream
-- and its zero-based occurrence among commands to that same stream are part of
-- the seed, so reordering different targets preserves identity.
module Keiro.ProcessManager.Reaction
  ( deterministicReactionCommandId,
  )
where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Coerce (coerce)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Keiro.Prelude
import Kiroku.Store.Types (EventId (..), StreamName (..))

-- | Derive the stable first-event id for one reaction target command.
--
-- Every field is encoded as its decimal UTF-8 byte length, a colon, and the
-- bytes. The fields are, in order: @keiro@, @process-reaction@, manager name,
-- correlation id, canonical source UUID text, physical target stream name, and
-- decimal zero-based occurrence among commands to that target.
deterministicReactionCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
deterministicReactionCommandId managerName correlationId sourceEventId targetStreamName occurrence =
  EventId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      ByteString.unpack $
        ByteString.concat $
          fmap
            encodeField
            [ "keiro",
              "process-reaction",
              managerName,
              correlationId,
              UUID.toText (coerce sourceEventId),
              coerce targetStreamName,
              Text.pack (show occurrence)
            ]
  where
    encodeField field =
      let bytes = Text.Encoding.encodeUtf8 field
       in ByteString.concat
            [ ByteString.Char8.pack (show (ByteString.length bytes)),
              ByteString.singleton 58,
              bytes
            ]
