{- | Versioned, dependency-free persistence for the files produced by one
successful scaffold run. Unknown header fields are ignored so v1 readers can
consume records extended by later tool versions.
-}
module Keiro.Dsl.ScaffoldRecord (
    ScaffoldRecord (..),
    renderRecord,
    parseRecord,
    recordFileName,
) where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Scaffold (ModuleKind (..))
import System.FilePath (isAbsolute, splitDirectories)

data ScaffoldRecord = ScaffoldRecord
    { recSpecPath :: !Text
    , recModuleRoot :: !Text
    , recLayout :: !Text
    , recFiles :: ![(ModuleKind, FilePath)]
    }
    deriving stock (Eq, Show)

renderRecord :: ScaffoldRecord -> Text
renderRecord record =
    T.unlines $
        [ "keiro-dsl scaffold record v1"
        , "spec: " <> recSpecPath record
        , "module-root: " <> rootLabel
        , "layout: " <> recLayout record
        ]
            <> map renderFile (recFiles record)
  where
    rootLabel = if T.null (recModuleRoot record) then "(none)" else recModuleRoot record
    renderFile (Generated, path) = "generated " <> T.pack path
    renderFile (HoleStub, path) = "hole " <> T.pack path

{- | Parse a v1 record. The version header and the three required fields must
be present exactly once. Unknown lines are ignored for forward compatibility;
unsafe file paths are rejected rather than joined to a scaffold output root.
-}
parseRecord :: Text -> Maybe ScaffoldRecord
parseRecord contents = case T.lines contents of
    header : rows
        | header == "keiro-dsl scaffold record v1" -> do
            specPath <- exactlyOne "spec: " rows
            rootLabel <- exactlyOne "module-root: " rows
            layout <- exactlyOne "layout: " rows
            files <- traverse parseFile (filter isFileRow rows)
            pure
                ScaffoldRecord
                    { recSpecPath = specPath
                    , recModuleRoot = if rootLabel == "(none)" then "" else rootLabel
                    , recLayout = layout
                    , recFiles = files
                    }
    _ -> Nothing
  where
    exactlyOne prefix rows = case [value | row <- rows, Just value <- [T.stripPrefix prefix row]] of
        [value] -> Just value
        _ -> Nothing
    isFileRow row = "generated " `T.isPrefixOf` row || "hole " `T.isPrefixOf` row
    parseFile row
        | Just path <- T.stripPrefix "generated " row = checkedFile Generated path
        | Just path <- T.stripPrefix "hole " row = checkedFile HoleStub path
        | otherwise = Nothing
    checkedFile fileKind pathText =
        let path = T.unpack pathText
         in if null path || isAbsolute path || ".." `elem` splitDirectories path
                then Nothing
                else Just (fileKind, path)

recordFileName :: Text -> FilePath
recordFileName context = "keiro-dsl-scaffold-record." <> T.unpack context <> ".txt"
