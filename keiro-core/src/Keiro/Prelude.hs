{- | The curated prelude shared across the Keiro packages.

Re-exports a deliberately small slice of @base@, @aeson@, @text@, @time@,
and the full @lens@ surface so modules can open with a single
@import Keiro.Prelude@ and get a consistent, explicit set of names. The
implicit @base@ @Prelude@ is expected to be disabled
(@NoImplicitPrelude@); only the names listed here are in scope, which
keeps event-sourcing code uniform and avoids accidental partial functions.

The @generic-lens@ @Data.Generics.Labels@ orphan instances are imported
for their effect only, enabling the @^. #field@ overloaded-label optics
used throughout the codebase.
-}
module Keiro.Prelude (
    module X,
    module Control.Lens,
)
where

import "aeson" Data.Aeson as X (
    FromJSON,
    Options,
    SumEncoding (..),
    ToJSON,
    Value,
    defaultOptions,
    fromJSON,
    genericParseJSON,
    genericToEncoding,
    genericToJSON,
    parseJSON,
    toEncoding,
    toJSON,
 )
import "aeson-casing" Data.Aeson.Casing as X (aesonDrop, aesonPrefix, camelCase, pascalCase, snakeCase, trainCase)
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.Bool as X (Bool (..), otherwise)
import "base" Data.Either as X (Either (..), either)
import "base" Data.Eq as X (Eq (..))
import "base" Data.Foldable as X (foldl', for_, traverse_)
import "base" Data.Function as X (($), (&), (.))
import "base" Data.Functor as X (Functor (..), (<$>))
import "base" Data.Int as X (Int, Int64)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (Maybe (..), fromMaybe, isJust, isNothing, maybe)
import "base" Data.Ord as X (Ord (..))
import "base" Data.Proxy as X (Proxy (..))
import "base" Data.Semigroup as X (Semigroup (..))
import "base" Data.String as X (String)
import "base" GHC.Generics as X (Generic)
import "generic-lens" Data.Generics.Labels ()
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)
import "base" Prelude as X (
    Applicative (..),
    Bounded (..),
    Enum (..),
    IO,
    Monad (..),
    Show (..),
    error,
    pure,
 )
