-- | Mount already allocated applications. This router owns no runtime resources.
module Keiro.Ops.Http.Compose
  ( SurfacePrefix,
    mkSurfacePrefix,
    surfacePrefixText,
    keiroPrefix,
    kirokuPrefix,
    shibuyaPrefix,
    pgmqPrefix,
    MountedSurface (..),
    ComposeConfig (..),
    defaultComposeConfig,
    ComposeError (..),
    renderComposeError,
    composeSurfaces,
    stripSurfacePrefix,
    composedCorsMiddleware,
  )
where

import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as Bytes
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Ops.Http.Application (OpsHttpError (..), errorResponse)
import Keiro.Ops.Http.Cors (corsMiddleware)
import Network.HTTP.Types
import Network.Wai

newtype SurfacePrefix = SurfacePrefix Text
  deriving stock (Eq, Ord, Show)

mkSurfacePrefix :: Text -> Either ComposeError SurfacePrefix
mkSurfacePrefix value
  | not (Text.null value), not (Text.isPrefixOf "-" value), Text.all valid value = Right (SurfacePrefix value)
  | otherwise = Left (InvalidPrefix value)
  where
    valid c = c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-'

surfacePrefixText :: SurfacePrefix -> Text
surfacePrefixText (SurfacePrefix value) = value

keiroPrefix, kirokuPrefix, shibuyaPrefix, pgmqPrefix :: SurfacePrefix
keiroPrefix = SurfacePrefix "keiro"
kirokuPrefix = SurfacePrefix "kiroku"
shibuyaPrefix = SurfacePrefix "shibuya"
pgmqPrefix = SurfacePrefix "pgmq"

data MountedSurface = MountedSurface
  { prefix :: !SurfacePrefix,
    application :: !Application
  }

newtype ComposeConfig = ComposeConfig {allowedOrigins :: [Text]}
  deriving stock (Eq, Show)

defaultComposeConfig :: ComposeConfig
defaultComposeConfig = ComposeConfig []

data ComposeError = InvalidPrefix !Text | DuplicatePrefix !Text | NoSurfaces
  deriving stock (Eq, Show)

renderComposeError :: ComposeError -> Text
renderComposeError = \case
  InvalidPrefix value -> "invalid surface prefix: " <> value
  DuplicatePrefix value -> "duplicate surface prefix: " <> value
  NoSurfaces -> "at least one inspection surface must be mounted"

composeSurfaces :: ComposeConfig -> [MountedSurface] -> Either ComposeError Application
composeSurfaces _ [] = Left NoSurfaces
composeSurfaces config surfaces = do
  mounts <- foldl add (Right Map.empty) surfaces
  let names = map (surfacePrefixText . (.prefix)) surfaces
      index =
        responseLBS status200 [(hContentType, "application/json; charset=utf-8")] $
          encode (object ["surfaces" .= map (\name -> object ["prefix" .= name, "path" .= ("/" <> name)]) names])
      router req respond = case pathInfo req of
        [] | requestMethod req == methodGet -> respond index
        [] -> respond $ mapResponseHeaders ((hAllow, "GET") :) $ errorResponse (OpsHttpError status405 "method_not_allowed" "the composed root answers GET only" Nothing)
        name : _ -> case Map.lookup name mounts of
          Just surface -> case stripSurfacePrefix surface.prefix req of
            Just relative -> surface.application relative respond
            Nothing -> respond (errorResponse (OpsHttpError status400 "invalid_path" "inconsistent encoded request path" Nothing))
          Nothing -> respond (errorResponse (OpsHttpError status404 "surface_not_mounted" ("no surface is mounted at /" <> name) (Just (object ["mounted" .= names]))))
  pure (composedCorsMiddleware config.allowedOrigins router)
  where
    add result surface = do
      mounts <- result
      let name = surfacePrefixText surface.prefix
      if Map.member name mounts then Left (DuplicatePrefix name) else Right (Map.insert name surface mounts)

-- | Strip exactly one raw segment, preserving every remaining byte and query.
-- Only the mount root's trailing slash is normalized. Inconsistent synthetic
-- WAI requests are rejected rather than routed to a different target.
stripSurfacePrefix :: SurfacePrefix -> Request -> Maybe Request
stripSurfacePrefix prefix req = case pathInfo req of
  name : rest
    | name == surfacePrefixText prefix,
      Bytes.isPrefixOf "/" (rawPathInfo req),
      decodePathSegments (rawPathInfo req) == pathInfo req ->
        let remainder = Bytes.dropWhile (/= 47) (Bytes.drop 1 (rawPathInfo req))
            raw = if Bytes.null remainder then "/" else remainder
            segments = if rest == [""] then [] else rest
         in Just req {pathInfo = segments, rawPathInfo = raw}
  _ -> Nothing

-- | Use the same exact-origin, duplicate-safe policy as standalone HTTP.
composedCorsMiddleware :: [Text] -> Middleware
composedCorsMiddleware = corsMiddleware
