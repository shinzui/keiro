module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend (parseSurfaceSource, renderFrontendFailure)
import Keiro.Dsl.LanguageVersion (ParsedSource)
import Keiro.Dsl.Parser (parseSource, renderParseFailure)
import Keiro.Dsl.Syntax (SurfaceSource)
import Keiro.Dsl.Workspace
  ( ContentSource (..),
    WorkspaceSpec,
    loadWorkspace,
    renderWorkspaceFailure,
  )
import Test.Tasty.Bench (Benchmark, bench, bgroup, defaultMain, whnf, whnfIO)

data SourceFixture = SourceFixture
  { fixtureConstructCount :: !Int,
    fixtureSource :: !Text
  }

data WorkspaceFixture = WorkspaceFixture
  { fixtureMemberCount :: !Int,
    fixtureTotalConstructCount :: !Int,
    fixtureManifestPath :: !FilePath,
    fixtureContents :: !(Map FilePath Text)
  }

main :: IO ()
main = do
  let sourceFixtures = map sourceFixture sourceSizes
      workspaceFixtures = map (uncurry workspaceFixture) workspaceShapes
  -- Build and force immutable inputs directly before registering benchmarks.
  -- tasty-bench's env accessor is deliberately unnecessary here and would
  -- reintroduce a lazy resource thunk around these already prepared values.
  forceFixtures sourceFixtures workspaceFixtures
  preflightFixtures sourceFixtures workspaceFixtures
  defaultMain (benchmarks sourceFixtures workspaceFixtures)

sourceSizes :: [Int]
sourceSizes = [32, 64, 128, 256]

workspaceShapes :: [(Int, Int)]
workspaceShapes = [(1, 32), (2, 32), (4, 32), (8, 32)]

forceFixtures :: [SourceFixture] -> [WorkspaceFixture] -> IO ()
forceFixtures sourceFixtures workspaceFixtures = do
  forM_ sourceFixtures $ \SourceFixture {fixtureSource} ->
    evaluate (force fixtureSource)
  forM_ workspaceFixtures $ \WorkspaceFixture {fixtureContents} ->
    evaluate (force fixtureContents)

preflightFixtures :: [SourceFixture] -> [WorkspaceFixture] -> IO ()
preflightFixtures sourceFixtures workspaceFixtures = do
  forM_ sourceFixtures $ \SourceFixture {fixtureConstructCount, fixtureSource} -> do
    _ <- evaluate (parseSurfaceOrFail (sourcePath fixtureConstructCount) fixtureSource)
    _ <- evaluate (parseCompatibilityOrFail (sourcePath fixtureConstructCount) fixtureSource)
    pure ()
  forM_ workspaceFixtures loadWorkspaceOrFail

benchmarks :: [SourceFixture] -> [WorkspaceFixture] -> [Benchmark]
benchmarks sourceFixtures workspaceFixtures =
  -- Weak-head evaluation is sufficient: producing the outer Right requires
  -- each Megaparsec route to consume its explicit eof, and loadWorkspace does
  -- all member reads, parses, and composition before returning its Either.
  -- The public parse results intentionally have no NFData instance.
  [ bgroup "surface-source" (map surfaceBenchmark sourceFixtures),
    bgroup "compatibility-source" (map compatibilityBenchmark sourceFixtures),
    bgroup "workspace" (map workspaceBenchmark workspaceFixtures)
  ]

surfaceBenchmark :: SourceFixture -> Benchmark
surfaceBenchmark SourceFixture {fixtureConstructCount, fixtureSource} =
  bench (sourceLabel fixtureConstructCount fixtureSource) $
    whnf (parseSurfaceSource (sourcePath fixtureConstructCount)) fixtureSource

compatibilityBenchmark :: SourceFixture -> Benchmark
compatibilityBenchmark SourceFixture {fixtureConstructCount, fixtureSource} =
  bench (sourceLabel fixtureConstructCount fixtureSource) $
    whnf (parseSource (sourcePath fixtureConstructCount)) fixtureSource

workspaceBenchmark :: WorkspaceFixture -> Benchmark
workspaceBenchmark fixture@WorkspaceFixture {fixtureMemberCount, fixtureTotalConstructCount, fixtureContents} =
  bench
    ( "members-"
        <> show fixtureMemberCount
        <> "-aggregates-"
        <> show fixtureTotalConstructCount
        <> "-chars-"
        <> show (sum (map T.length (Map.elems fixtureContents)))
    )
    (whnfIO (loadWorkspaceOrFail fixture))

sourceFixture :: Int -> SourceFixture
sourceFixture fixtureConstructCount =
  SourceFixture
    { fixtureConstructCount,
      fixtureSource = nestedSpecification "parser-bench" 0 fixtureConstructCount
    }

sourceLabel :: Int -> Text -> String
sourceLabel constructCount source =
  "nested-aggregates-"
    <> show constructCount
    <> "-chars-"
    <> show (T.length source)

sourcePath :: Int -> FilePath
sourcePath constructCount = "parser-bench-" <> show constructCount <> ".keiro"

nestedSpecification :: Text -> Int -> Int -> Text
nestedSpecification contextName firstConstruct constructCount =
  T.unlines
    [ "language keiro-dsl 4",
      "context " <> contextName
    ]
    <> T.concat [aggregateDefinition index | index <- [firstConstruct .. firstConstruct + constructCount - 1]]

aggregateDefinition :: Int -> Text
aggregateDefinition index =
  T.unlines
    [ "",
      "aggregate " <> aggregateName,
      "  regs",
      "    count Natural = 0",
      "    limit Natural = 100",
      "    label Text = \"ready # literal\"",
      "  states Empty Active Closed!",
      "  command Advance { amount:Natural delta:Natural note:Text }",
      "  event Advanced = fields(Advance)",
      "  Empty -- Advance -->",
      "    guard cmd.amount + cmd.delta > reg.count && reg.limit >= cmd.amount",
      "    write count := reg.count + cmd.amount",
      "    write limit := reg.limit + cmd.delta",
      "    write label := cmd.note",
      "    emit Advanced",
      "    goto Active"
    ]
  where
    aggregateName = "BenchAggregate" <> paddedDecimal index

paddedDecimal :: Int -> Text
paddedDecimal number =
  let rendered = T.pack (show number)
   in T.replicate (6 - T.length rendered) "0" <> rendered

workspaceFixture :: Int -> Int -> WorkspaceFixture
workspaceFixture memberCount totalConstructCount
  | totalConstructCount `mod` memberCount /= 0 =
      error "workspace fixture construct count must divide evenly across members"
  | otherwise =
      WorkspaceFixture
        { fixtureMemberCount = memberCount,
          fixtureTotalConstructCount = totalConstructCount,
          fixtureManifestPath = manifestPath,
          fixtureContents = Map.insert manifestPath manifest members
        }
  where
    manifestPath = "service.keiro-workspace"
    constructsPerMember = totalConstructCount `div` memberCount
    memberRows =
      [ ( memberPath memberIndex,
          workspaceSpecification
            "parser-bench-workspace"
            (memberIndex * constructsPerMember)
            constructsPerMember
        )
      | memberIndex <- [0 .. memberCount - 1]
      ]
    members = Map.fromList memberRows
    manifest =
      T.unlines
        ( "service parser-bench-workspace"
            : ["spec " <> T.pack path | (path, _) <- memberRows]
        )

memberPath :: Int -> FilePath
memberPath memberIndex = "member-" <> T.unpack (paddedDecimal memberIndex) <> ".keiro"

workspaceSpecification :: Text -> Int -> Int -> Text
workspaceSpecification contextName firstConstruct constructCount =
  T.unlines
    [ "language keiro-dsl 4",
      "context " <> contextName
    ]
    <> T.concat [wideAggregateDefinition index | index <- [firstConstruct .. firstConstruct + constructCount - 1]]

wideAggregateDefinition :: Int -> Text
wideAggregateDefinition index =
  T.unlines
    ( [ "",
        "aggregate " <> aggregateName,
        "  regs"
      ]
        <> ["    value" <> paddedDecimal fieldIndex <> " Natural = 0" | fieldIndex <- fieldIndexes]
        <> [ "    label Text = \"ready # literal\"",
             "  states Empty Active Closed!",
             "  command Advance {"
           ]
        <> ["    field" <> paddedDecimal fieldIndex <> ":Natural" | fieldIndex <- fieldIndexes]
        <> [ "    note:Text",
             "  }",
             "  event Advanced = fields(Advance)",
             "  Empty -- Advance -->",
             "    guard " <> guardExpression
           ]
        <> [ "    write value"
               <> paddedDecimal fieldIndex
               <> " := reg.value"
               <> paddedDecimal fieldIndex
               <> " + cmd.field"
               <> paddedDecimal fieldIndex
           | fieldIndex <- fieldIndexes
           ]
        <> [ "    write label := cmd.note",
             "    emit Advanced",
             "    goto Active"
           ]
    )
  where
    aggregateName = "WorkspaceAggregate" <> paddedDecimal index
    fieldIndexes = [0 .. 15]
    guardExpression =
      T.intercalate
        " && "
        [ "cmd.field"
            <> paddedDecimal fieldIndex
            <> " + reg.value"
            <> paddedDecimal fieldIndex
            <> " > 0"
        | fieldIndex <- fieldIndexes
        ]

parseSurfaceOrFail :: FilePath -> Text -> SurfaceSource
parseSurfaceOrFail path source =
  case parseSurfaceSource path source of
    Left failure -> error (T.unpack (renderFrontendFailure failure))
    Right parsed -> parsed

parseCompatibilityOrFail :: FilePath -> Text -> ParsedSource
parseCompatibilityOrFail path source =
  case parseSource path source of
    Left failure -> error (T.unpack (renderParseFailure failure))
    Right parsed -> parsed

loadWorkspaceOrFail :: WorkspaceFixture -> IO WorkspaceSpec
loadWorkspaceOrFail WorkspaceFixture {fixtureManifestPath, fixtureContents} = do
  result <- loadWorkspace contentSource fixtureManifestPath
  case result of
    Left failure -> error (T.unpack (T.unlines (renderWorkspaceFailure fixtureManifestPath failure)))
    Right workspace -> pure workspace
  where
    contentSource =
      ContentSource
        { csRead = \path ->
            pure $
              maybe
                (Left ("missing in-memory benchmark fixture: " <> T.pack path))
                Right
                (Map.lookup path fixtureContents)
        }
