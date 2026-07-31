{- | Versioned event-payload fixtures captured at spec-diff time.

The current aggregate specification cannot reconstruct an older payload shape,
so golden payloads are synthesized while both the old and new specifications
are available. Existing files are never overwritten: a hand-captured
production payload is always more authoritative than a synthesized sample.
-}
module Keiro.Dsl.Goldens (
    GoldenEvidence (..),
    GoldenPayload (..),
    goldensForDiff,
    emitGoldenPayloads,
    loadGoldenPayloads,
    goldenRelativePath,
) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Text qualified as AesonText
import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.Scaffold (Agg (..), ResolvedCtor (..), defaultContext, resolveAgg)
import Keiro.Dsl.TypeGraph
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath (dropTrailingPathSeparator, takeDirectory, takeFileName, (</>))

data GoldenEvidence = SynthesizedWeakStandIn | FileOwnedFixture
    deriving stock (Eq, Show)

data GoldenPayload = GoldenPayload
    { goldenContext :: !Text
    , goldenAggregate :: !Text
    , goldenEvent :: !Text
    , goldenVersion :: !Int
    , goldenJson :: !Text
    , goldenEvidence :: !GoldenEvidence
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
        , goldenEvidence = SynthesizedWeakStandIn
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
                        , goldenEvidence = FileOwnedFixture
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

renderGolden :: Spec -> Agg -> ResolvedCtor -> Text
renderGolden spec aggregate event =
    TL.toStrict (AesonText.encodeToLazyText (Object (KeyMap.fromList entries))) <> "\n"
  where
    graph = either (const Nothing) Just (resolveTypeGraph spec)
    entries =
        (Key.fromText "kind", String (rcName event))
            : [(Key.fromText fieldName, sampleValue graph spec aggregate fieldType) | (fieldName, fieldType) <- rcFields event]

sampleValue :: Maybe TypeGraph -> Spec -> Agg -> ResolvedAggregateType -> Value
sampleValue graph spec _aggregate resolvedType =
    case resolvedType of
        AggregateNominal nominal -> case resolvedNominalRepresentation nominal of
            IdRepresentation prefix -> String (prefix <> "_01hzy3v7q2e8kaw2m5x0d41n9c")
            EnumRepresentation constructors -> String (snd (NE.head constructors))
            ScalarRepresentation NominalText -> String "sample"
            ScalarRepresentation NominalInt -> Number 1
            ScalarRepresentation NominalNatural -> Number 1
            ScalarRepresentation NominalBool -> Bool True
            ScalarRepresentation NominalTime -> String "2026-01-02T03:04:05.123456789012Z"
        AggregateVertex vertexType ->
            String
                ( fromMaybe
                    "sample"
                    ( stName
                        <$> ( find ((== vertexType) . (<> "Vertex") . aggName) aggregates
                                >>= listToMaybe . aggStates
                            )
                    )
                )
        AggregateMapped key
            | Just resolved <- graph
            , Just declaration <- Map.lookup key (tgDeclarations resolved) ->
                sampleMappedDeclaration resolved declaration
            | otherwise -> emptyObject
        AggregateInt -> Number 1
        AggregateInteger -> Number 1
        AggregateNatural -> Number 1
        AggregateBool -> Bool True
        AggregateTime -> String "2026-01-02T03:04:05.123456789012Z"
        AggregateText -> String "sample"
  where
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]

sampleMappedDeclaration :: TypeGraph -> ResolvedMappedDecl -> Value
sampleMappedDeclaration graph =
    foldMappedDecl
        MappedDeclAlgebra
            { onStructuralDecl = \_ -> sampleMappedShape graph
            , onOpaqueDecl = const emptyObject
            }

sampleMappedShape :: TypeGraph -> ResolvedMappedShape -> Value
sampleMappedShape graph =
    foldMappedShape
        MappedShapeAlgebra
            { onRecord = \_ _ fields ->
                Object . KeyMap.fromList $
                    [ (Key.fromText (rwfKey field), sampleMappedExpression graph (rwfType field))
                    | field <- fields
                    , includeField field
                    ]
            , onEnum = \entries -> case entries of
                firstEntry : _ -> String (weTag firstEntry)
                [] -> String "sample"
            , onUnion = \encoding arms -> case arms of
                firstArm : _ ->
                    Object . KeyMap.fromList $
                        [(Key.fromText (ueTagField encoding), String (rwaTag firstArm))]
                            <> [ (Key.fromText (ueContentsField encoding), sampleMappedExpression graph payload)
                               | payload <- maybeToList (rwaPayload firstArm)
                               ]
                [] -> emptyObject
            }
  where
    includeField field = case rwfPresence field of
        PRequired -> True
        POptional -> isNothingValue (rwfOnMissing field)

sampleMappedExpression :: TypeGraph -> ResolvedTypeExpr -> Value
sampleMappedExpression graph =
    foldTypeExpr
        TypeExprAlgebra
            { onText = String "sample"
            , onInt = Number 1
            , onInteger = Number 1
            , onBool = Bool True
            , onNatural = Number 1
            , onTime = String "2026-01-01T00:00:00Z"
            , onJson = emptyObject
            , onOptional = id
            , onList = \value -> Array (pure value)
            , onMap = \value -> Object (KeyMap.singleton (Key.fromText "sample") value)
            , onRef = \key -> maybe emptyObject (sampleMappedDeclaration graph) (Map.lookup key (tgDeclarations graph))
            }

emptyObject :: Value
emptyObject = Object KeyMap.empty

maybeToList :: Maybe a -> [a]
maybeToList = maybe [] pure

isNothingValue :: Maybe a -> Bool
isNothingValue Nothing = True
isNothingValue Just{} = False
