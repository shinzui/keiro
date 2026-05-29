{- | A phantom-typed handle to a single event stream.

'Stream' wraps a 'StreamName' but carries a phantom type parameter @a@
identifying /which/ aggregate or event stream the name belongs to. This
lets the rest of the framework demand, say, a @Stream Order@ rather than a
bare 'StreamName', so a name for one aggregate cannot be passed where
another is expected. The wrapper is otherwise transparent — use 'stream'
to construct one and 'streamName' to recover the underlying name.
-}
module Keiro.Stream
  ( Stream (..)
  , stream
  , streamName
  , mapStreamName
  )
where

import Keiro.Prelude
import Kiroku.Store.Types (StreamName (..))

-- | A 'StreamName' tagged with the phantom type @a@ of the stream it names.
newtype Stream a = Stream
  { name :: StreamName
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | Build a 'Stream' handle from a raw stream-name 'Text'.
stream :: Text -> Stream a
stream name = Stream { name = StreamName name }

-- | Recover the underlying 'StreamName' from a 'Stream' handle.
streamName :: Stream a -> StreamName
streamName value = value ^. #name

{- | Transform the underlying 'StreamName' while preserving the phantom
type. Handy for namespacing or prefixing a stream name without losing the
compile-time tag.
-}
mapStreamName :: (StreamName -> StreamName) -> Stream a -> Stream a
mapStreamName f value = value & #name %~ f
