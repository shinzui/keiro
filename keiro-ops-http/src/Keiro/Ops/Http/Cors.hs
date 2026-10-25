module Keiro.Ops.Http.Cors (corsMiddleware, originAllowed) where

import Control.Monad (guard)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Bytes
import Data.Char (isAlphaNum, isAscii, toLower)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Types
import Network.URI (URI (..), URIAuth (..), parseURI)
import Network.Wai
import Text.Read (readMaybe)

data Origin = Origin String String Int deriving stock (Eq)

-- A serialized HTTP origin contains only scheme, host and optional port.
-- No user information, path, query, fragment, opaque/null or origin list.
parseOrigin :: ByteString -> Maybe Origin
parseOrigin bytes = do
  uri <- parseURI (Bytes.unpack bytes)
  let scheme = map toLower uri.uriScheme
  defaultPort <- case scheme of "http:" -> Just 80; "https:" -> Just 443; _ -> Nothing
  authority <- uri.uriAuthority
  guard (null uri.uriPath && null uri.uriQuery && null uri.uriFragment && null authority.uriUserInfo)
  let host = map toLower authority.uriRegName
  guard (not (null host) && all (\c -> isAscii c && (isAlphaNum c || c `elem` (".-:[]" :: String))) host)
  port <- case authority.uriPort of
    "" -> Just defaultPort
    ':' : digits | not (null digits) && all (\c -> c >= '0' && c <= '9') digits -> readMaybe digits
    _ -> Nothing
  guard (port >= 0 && port <= 65535)
  pure (Origin scheme host port)

allowedCorsOrigin :: [Text] -> RequestHeaders -> Maybe ByteString
allowedCorsOrigin origins headers = do
  [raw] <- pure [value | (key, value) <- headers, key == "Origin"]
  origin <- parseOrigin raw
  guard (any ((== Just origin) . parseOrigin . encodeUtf8) origins)
  pure raw

-- HTTP mutations and WebSocket upgrades use exactly the same origin policy.
-- Forwarded headers are deliberately excluded: TLS proxies allow-list HTTPS.
originAllowed :: [Text] -> Bool -> RequestHeaders -> Bool
originAllowed origins secure headers = case [value | (key, value) <- headers, key == "Origin"] of
  [] -> True
  [raw] -> case parseOrigin raw of
    Nothing -> False
    Just origin ->
      any ((== Just origin) . parseOrigin . encodeUtf8) origins
        || case [host | (key, host) <- headers, key == hHost] of
          [host] -> parseOrigin ((if secure then "https://" else "http://") <> host) == Just origin
          _ -> False
  _ -> False

-- No credentials. Composition preserves already supplied surface CORS headers.
corsMiddleware :: [Text] -> Middleware
corsMiddleware [] = id
corsMiddleware origins = \app request respond ->
  case allowedCorsOrigin origins (requestHeaders request) of
    Just origin ->
      let add headers
            | any ((== "Access-Control-Allow-Origin") . fst) headers = headers
            | otherwise = ("Access-Control-Allow-Origin", origin) : ("Vary", "Origin") : headers
       in if requestMethod request == methodOptions && any ((== "Access-Control-Request-Method") . fst) (requestHeaders request)
            then respond (responseLBS status204 (add [("Access-Control-Allow-Methods", "GET, POST, OPTIONS"), ("Access-Control-Allow-Headers", maybe "Content-Type" id (lookup "Access-Control-Request-Headers" (requestHeaders request))), ("Access-Control-Max-Age", "600")]) "")
            else app request (respond . mapResponseHeaders add)
    Nothing -> app request respond
