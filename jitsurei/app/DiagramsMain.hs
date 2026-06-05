module Main (
    main,
)
where

import Control.Monad (foldM, unless, when)
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Jitsurei.Diagrams (
    escalationStreamMermaid,
    fulfillmentStreamMermaid,
    incidentStreamMermaid,
    orderStreamMermaid,
    pageStreamMermaid,
 )
import System.Environment (getArgs)
import System.Exit (die, exitFailure)

data Mode
    = Check
    | Write
    deriving stock (Eq, Show)

data Diagram = Diagram
    { name :: !Text
    , path :: !FilePath
    , body :: !Text
    }

main :: IO ()
main = do
    mode <- parseMode =<< getArgs
    stale <- applyDiagrams mode diagrams
    unless (null stale) do
        putStrLn ("Stale generated diagrams: " <> intercalate ", " stale)
        putStrLn "Run: cabal run jitsurei:exe:jitsurei-diagrams -- --write"
        exitFailure
    when (mode == Check) $
        putStrLn "All generated jitsurei diagrams are up to date."

parseMode :: [String] -> IO Mode
parseMode = \case
    ["--check"] -> pure Check
    ["--write"] -> pure Write
    _ -> die "Usage: jitsurei-diagrams --check | --write"

diagrams :: [Diagram]
diagrams =
    [ Diagram
        { name = "order-stream"
        , path = "docs/guides/build-the-command-side.md"
        , body = orderStreamMermaid
        }
    , Diagram
        { name = "fulfillment-stream"
        , path = "docs/guides/process-managers-and-timers.md"
        , body = fulfillmentStreamMermaid
        }
    , Diagram
        { name = "incident-stream"
        , path = incidentGuide
        , body = incidentStreamMermaid
        }
    , Diagram
        { name = "page-stream"
        , path = incidentGuide
        , body = pageStreamMermaid
        }
    , Diagram
        { name = "escalation-stream"
        , path = incidentGuide
        , body = escalationStreamMermaid
        }
    ]
  where
    incidentGuide =
        "docs/guides/coordinating-incident-response-with-routers-and-process-managers.md"

applyDiagrams :: Mode -> [Diagram] -> IO [String]
applyDiagrams mode =
    foldM applyDiagram []
  where
    applyDiagram stale diagram = do
        original <- Text.IO.readFile diagram.path
        updated <- replaceDiagram diagram original
        let diagramName = Text.unpack diagram.name
        case mode of
            Check ->
                pure
                    if updated == original
                        then stale
                        else stale <> [diagramName]
            Write -> do
                when (updated /= original) $
                    Text.IO.writeFile diagram.path updated
                pure stale

replaceDiagram :: Diagram -> Text -> IO Text
replaceDiagram diagram content = do
    let start = marker diagram.name "begin"
        end = marker diagram.name "end"
        (beforeStart, fromStart) = Text.breakOn start content
    when (Text.null fromStart) $
        die ("Missing diagram start marker " <> Text.unpack start <> " in " <> diagram.path)
    let afterStart = Text.drop (Text.length start) fromStart
        (_inside, fromEnd) = Text.breakOn end afterStart
    when (Text.null fromEnd) $
        die ("Missing diagram end marker " <> Text.unpack end <> " in " <> diagram.path)
    let afterEnd = Text.drop (Text.length end) fromEnd
        replacement = "\n" <> renderMermaidBlock diagram.body <> "\n"
    pure (beforeStart <> start <> replacement <> end <> afterEnd)

marker :: Text -> Text -> Text
marker diagramName boundary =
    "<!-- jitsurei-diagram: " <> diagramName <> " " <> boundary <> " -->"

renderMermaidBlock :: Text -> Text
renderMermaidBlock mermaid =
    "```mermaid\n" <> Text.stripEnd mermaid <> "\n```"
