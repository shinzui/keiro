{- | A phantom-typed handle to a single event stream.

'Stream' wraps a 'StreamName' but carries a phantom type parameter @a@
identifying /which/ aggregate or event stream the name belongs to. This
lets the rest of the framework demand, say, a @Stream Order@ rather than a
bare 'StreamName', so a name for one aggregate cannot be passed where
another is expected. The wrapper is otherwise transparent — use 'stream'
to construct one and 'streamName' to recover the underlying name.
-}
module Keiro.Stream (
    Stream (..),
    stream,
    streamName,
    mapStreamName,

    -- * Safe, category-based construction
    StreamCategory,
    categoryText,
    CategoryError (..),
    category,
    categoryUnsafe,
    categoryName,
    StreamIdSegment (..),
    entityStream,
    entityStreamId,
)
where

import Data.Char qualified as Char
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Keiro.Prelude
import Kiroku.Store.Types (CategoryName (..), StreamName (..))
import Kiroku.Store.Types qualified as Store

-- | A 'StreamName' tagged with the phantom type @a@ of the stream it names.
newtype Stream a = Stream
    { name :: StreamName
    }
    deriving stock (Generic, Eq, Ord, Show)

-- | Build a 'Stream' handle from a raw stream-name 'Text'.
stream :: Text -> Stream a
stream name = Stream{name = StreamName name}

-- | Recover the underlying 'StreamName' from a 'Stream' handle.
streamName :: Stream a -> StreamName
streamName value = value ^. #name

{- | Transform the underlying 'StreamName' while preserving the phantom
type. Handy for namespacing or prefixing a stream name without losing the
compile-time tag.
-}
mapStreamName :: (StreamName -> StreamName) -> Stream a -> Stream a
mapStreamName f value = value & #name %~ f

{- | A validated stream /category/: the prefix that precedes the first @-@ in
every stream name belonging to this family. Kiroku defines a stream's category
as the substring before its first @-@ (see 'Kiroku.Store.Types.categoryName'),
so a category must itself contain no @-@. Carries the same phantom type @a@ as
the 'Stream' handles it produces. Write a compound category in camelCase (e.g.
@"hospitalSurge"@ for a saga over hospital surges); @:@ is reserved for the
workflow stream family (@wf:\<name\>@).

Named 'StreamCategory' (not @Category@) to avoid clashing with the
'Kiroku.Store.Subscription.Types.Category' subscription-target constructor,
which consumer code commonly imports alongside this module.
-}
newtype StreamCategory a = StreamCategory {categoryTextOf :: Text}
    deriving stock (Generic, Eq, Ord, Show)

-- | Why a 'Text' is not a valid 'StreamCategory'.
data CategoryError
    = -- | the empty string
      CategoryEmpty
    | -- | contains the reserved @-@ category/id boundary
      CategoryContainsSeparator !Text
    | -- | equals a store-reserved name (@$all@)
      CategoryReserved !Text
    | -- | contains whitespace or a control character
      CategoryContainsIllegalChar !Char !Text
    deriving stock (Eq, Show, Generic)

{- | Validate a 'Text' as a 'Category'. Rejects the empty string, any text
containing @-@ (Kiroku's category/id boundary, which would make 'categoryName'
ambiguous), whitespace/control characters, and the reserved name @$all@.
-}
category :: Text -> Either CategoryError (StreamCategory a)
category t
    | Text.null t = Left CategoryEmpty
    | t == "$all" = Left (CategoryReserved t)
    | Text.isInfixOf "-" t = Left (CategoryContainsSeparator t)
    | Just illegal <- Text.find (\c -> Char.isSpace c || Char.isControl c) t =
        Left (CategoryContainsIllegalChar illegal t)
    | otherwise = Right (StreamCategory t)

-- | Recover the validated category text.
categoryText :: StreamCategory a -> Text
categoryText (StreamCategory t) = t

{- | Partial constructor for static, known-good category literals at definition
sites. Calls 'error' on an invalid category; never pass user input. Intended for
top-level @fooCategory = categoryUnsafe "foo"@.
-}
categoryUnsafe :: (HasCallStack) => Text -> StreamCategory a
categoryUnsafe t =
    case category t of
        Right value -> value
        Left err -> error ("Keiro.Stream.categoryUnsafe: invalid category " <> show t <> ": " <> show err)

{- | The 'CategoryName' for category-scoped reads
('Kiroku.Store.Read.readCategory') and category subscription targets. For any
@cat@ and id segment, @categoryName cat@ equals
@Kiroku.Store.Types.categoryName (streamName (entityStream cat id))@ — the
category rule is single-sourced in kiroku.
-}
categoryName :: StreamCategory a -> CategoryName
categoryName (StreamCategory t) = CategoryName t

{- | Render a value as the /id segment/ of a stream name (the part after the
first @-@). The id may itself contain @-@ without corrupting the leading
category, but must be non-blank to keep the stream name distinct from a bare
category read.
-}
class StreamIdSegment i where
    renderIdSegment :: i -> Text

instance StreamIdSegment Text where
    renderIdSegment = id

instance StreamIdSegment String where
    renderIdSegment = Text.pack

{- | Build the per-entity 'Stream' handle for an aggregate instance, rendering
@\<category\>-\<id\>@. The phantom type is carried from the 'StreamCategory', so
the result is correctly tagged. The actual name mechanics are delegated to
kiroku's 'Store.streamNameInCategory', keeping the category rule single-sourced
in the store.
-}
entityStream :: (HasCallStack) => StreamCategory a -> Text -> Stream a
entityStream (StreamCategory c) idSeg =
    if Text.null (Text.strip idSeg)
        then error ("Keiro.Stream.entityStream: blank id segment for category " <> show c)
        else Stream{name = Store.streamNameInCategory (CategoryName c) idSeg}

{- | 'entityStream' for a typed id with a 'StreamIdSegment' instance. Domain id
types typically add @instance StreamIdSegment FooId where renderIdSegment =
Text.pack . show@.
-}
entityStreamId :: (HasCallStack, StreamIdSegment i) => StreamCategory a -> i -> Stream a
entityStreamId c = entityStream c . renderIdSegment
