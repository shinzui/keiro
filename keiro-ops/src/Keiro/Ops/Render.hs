module Keiro.Ops.Render
  ( OpsOutcome (..),
    OpsResult (..),
    emptyResult,
    messageResult,
    renderHuman,
    renderResult,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (transpose)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))

data OpsResult = OpsResult
  { headers :: ![Text],
    rows :: ![[Text]],
    jsonValue :: !Value
  }
  deriving stock (Eq, Show)

data OpsOutcome
  = Succeeded !OpsResult
  | PreviewRequired !OpsResult !Text
  | Failed !Text
  deriving stock (Eq, Show)

emptyResult :: OpsResult
emptyResult = OpsResult [] [] (Aeson.Array mempty)

messageResult :: Text -> OpsResult
messageResult message =
  OpsResult
    { headers = ["message"],
      rows = [[message]],
      jsonValue = object ["message" .= message]
    }

renderResult :: OpsEnv -> OpsResult -> IO ()
renderResult env result =
  case env.outputMode of
    HumanTable -> Text.IO.putStrLn (renderHuman result)
    Json -> LazyByteString.putStrLn (Aeson.encode result.jsonValue)

renderHuman :: OpsResult -> Text
renderHuman OpsResult {headers, rows}
  | null headers = ""
  | otherwise =
      Text.unlines
        ( renderRow widths headers
            : renderSeparator widths
            : map (renderRow widths . normalizeRow (length headers)) rows
        )
  where
    normalizedRows = map (normalizeRow (length headers)) rows
    columns = transpose (headers : normalizedRows)
    widths = map (maximum . map Text.length) columns

normalizeRow :: Int -> [Text] -> [Text]
normalizeRow width row = take width (row <> repeat "")

renderRow :: [Int] -> [Text] -> Text
renderRow widths cells =
  Text.intercalate "  " (zipWith pad widths cells)
  where
    pad width cell = cell <> Text.replicate (width - Text.length cell) " "

renderSeparator :: [Int] -> Text
renderSeparator = Text.intercalate "  " . map (`Text.replicate` "-")
