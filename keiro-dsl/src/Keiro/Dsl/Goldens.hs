{- | Versioned event-payload fixtures captured at spec-diff time.

The current aggregate specification cannot reconstruct an older payload shape,
so golden payloads are synthesized while both the old and new specifications
are available. Existing files are never overwritten: a hand-captured
production payload is always more authoritative than a synthesized sample.
-}
module Keiro.Dsl.Goldens (
    GoldenPayload (..),
    goldensForDiff,
    emitGoldenPayloads,
    loadGoldenPayloads,
    goldenRelativePath,
) where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Grammar
import Keiro.Dsl.Scaffold (Agg (..), ResolvedCtor (..), defaultContext, resolveAgg)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath (dropTrailingPathSeparator, takeDirectory, takeFileName, (</>))

data GoldenPayload = GoldenPayload
    { goldenContext :: !Text
    , goldenAggregate :: !Text
    , goldenEvent :: !Text
    , goldenVersion :: !Int
    , goldenJson :: !Text
    }
    deriving stock (Eq, Show)

{- | Synthesize one old-shape payload for each event whose version increases.
The result is deterministic and ordered like the old specification.
-}
goldensForDiff :: Spec -> Spec -> [GoldenPayload]
goldensForDiff oldSpec newSpec =
    [ GoldenPayload
        { goldenContext = specContext oldSpec
        , goldenAggregate = aggName oldAggregate
        , goldenEvent = evName oldEvent
        , goldenVersion = evVersion oldEvent
        , goldenJson = renderGolden oldSpec oldResolved oldResolvedEvent
        }
    | oldAggregate <- aggregates oldSpec
    , Just newAggregate <- [find ((== aggName oldAggregate) . aggName) (aggregates newSpec)]
    , let oldResolved = resolveAgg (defaultContext (specContext oldSpec)) oldSpec oldAggregate
    , oldEvent <- aggEvents oldAggregate
    , Just newEvent <- [find ((== evName oldEvent) . evName) (aggEvents newAggregate)]
    , evVersion newEvent > evVersion oldEvent
    , Just oldResolvedEvent <- [find ((== evName oldEvent) . rcName) (aEvents oldResolved)]
    ]
  where
    aggregates spec = [aggregate | NAggregate aggregate <- specNodes spec]

{- | Write newly synthesized fixtures below
@<root>/<context>/<aggregate>/<event>.v<version>.json@. Existing files are
left untouched and omitted from the returned path list.
-}
emitGoldenPayloads :: FilePath -> Spec -> Spec -> IO [FilePath]
emitGoldenPayloads root oldSpec newSpec =
    fmap concat . traverse writeIfMissing $ goldensForDiff oldSpec newSpec
  where
    writeIfMissing golden = do
        let path = root </> goldenRelativePath golden
        exists <- doesFileExist path
        if exists
            then pure []
            else do
                createDirectoryIfMissing True (takeDirectory path)
                TIO.writeFile path (goldenJson golden)
                pure [path]

{- | Load only the fixtures relevant to declared upcasters in @spec@.
@root@ may name the global golden root or its context child directory.
-}
loadGoldenPayloads :: FilePath -> Spec -> IO [GoldenPayload]
loadGoldenPayloads root spec = do
    contextRoot <- resolveContextRoot root (T.unpack (specContext spec))
    fmap concat . traverse (loadAggregate contextRoot) $ aggregates spec
  where
    aggregates current = [aggregate | NAggregate aggregate <- specNodes current]

    loadAggregate contextRoot aggregate =
        fmap concat . traverse (loadEvent contextRoot aggregate) $ aggEvents aggregate

    loadEvent contextRoot aggregate event = case evUpcastFrom event of
        Nothing -> pure []
        Just (sourceVersion, _) -> do
            let golden =
                    GoldenPayload
                        { goldenContext = specContext spec
                        , goldenAggregate = aggName aggregate
                        , goldenEvent = evName event
                        , goldenVersion = sourceVersion
                        , goldenJson = ""
                        }
                path = contextRoot </> aggregateRelativePath golden
            exists <- doesFileExist path
            if exists
                then do
                    contents <- TIO.readFile path
                    pure [golden{goldenJson = contents}]
                else pure []

goldenRelativePath :: GoldenPayload -> FilePath
goldenRelativePath golden =
    T.unpack (goldenContext golden) </> aggregateRelativePath golden

aggregateRelativePath :: GoldenPayload -> FilePath
aggregateRelativePath golden =
    T.unpack (goldenAggregate golden)
        </> T.unpack (goldenEvent golden)
            <> ".v"
            <> show (goldenVersion golden)
            <> ".json"

resolveContextRoot :: FilePath -> FilePath -> IO FilePath
resolveContextRoot root contextName = do
    let nested = root </> contextName
    nestedExists <- doesDirectoryExist nested
    pure $
        if nestedExists
            then nested
            else
                if takeFileName (dropTrailingPathSeparator root) == contextName
                    then root
                    else nested

data SampleValue = SampleText !Text | SampleInt !Int | SampleBool !Bool

renderGolden :: Spec -> Agg -> ResolvedCtor -> Text
renderGolden spec aggregate event =
    T.unlines $
        ["{"]
            <> zipWith renderEntry [0 :: Int ..] entries
            <> ["}"]
  where
    entries =
        ("kind", SampleText (rcName event))
            : [(fieldName, sampleValue spec aggregate fieldType) | (fieldName, fieldType) <- rcFields event]
    lastIndex = length entries - 1
    renderEntry index (fieldName, value) =
        "  "
            <> quote fieldName
            <> ": "
            <> renderSample value
            <> if index == lastIndex then "" else ","

sampleValue :: Spec -> Agg -> Text -> SampleValue
sampleValue spec _aggregate fieldType
    | Just identifier <- find ((== fieldType) . idName) (specIds spec) =
        SampleText (idPrefix identifier <> "_01hzy3v7q2e8kaw2m5x0d41n9c")
    | Just enum <- find ((== fieldType) . enumName) (specEnums spec)
    , (_, wireValue) : _ <- enumCtors enum =
        SampleText wireValue
    | fieldType == "Int" = SampleInt 1
    | fieldType == "Bool" = SampleBool True
    | fieldType == "Time" = SampleText "2026-01-01T00:00:00Z"
    | otherwise = SampleText "sample"

renderSample :: SampleValue -> Text
renderSample (SampleText value) = quote value
renderSample (SampleInt value) = T.pack (show value)
renderSample (SampleBool True) = "true"
renderSample (SampleBool False) = "false"

quote :: Text -> Text
quote = T.pack . show
