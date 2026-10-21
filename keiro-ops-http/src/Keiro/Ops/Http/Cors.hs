module Keiro.Ops.Http.Cors (corsMiddleware) where

import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Types
import Network.Wai

-- | Exact origins only, no credentials. Existing surface CORS headers win so
-- that composition can apply this middleware once without duplicating them.
corsMiddleware :: [Text] -> Middleware
corsMiddleware [] = id
corsMiddleware origins = \app request respond ->
  case lookup "Origin" (requestHeaders request) of
    Just origin
      | origin `elem` map encodeUtf8 origins ->
          let add headers
                | any ((== "Access-Control-Allow-Origin") . fst) headers = headers
                | otherwise = ("Access-Control-Allow-Origin", origin) : ("Vary", "Origin") : headers
           in if requestMethod request == methodOptions && any ((== "Access-Control-Request-Method") . fst) (requestHeaders request)
                then respond (responseLBS status204 (add [("Access-Control-Allow-Methods", "GET, POST, OPTIONS"), ("Access-Control-Allow-Headers", maybe "Content-Type" id (lookup "Access-Control-Request-Headers" (requestHeaders request))), ("Access-Control-Max-Age", "600")]) "")
                else app request (respond . mapResponseHeaders add)
    _ -> app request respond
