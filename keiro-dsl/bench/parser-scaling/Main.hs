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
  { fixtureAggregateCount :: !Int,
    fixtureConstructCount :: !Int,
    fixtureSource :: !Text
  }

data WorkspaceFixture = WorkspaceFixture
  { fixtureMemberCount :: !Int,
    fixtureAggregateCount :: !Int,
    fixtureTotalConstructCount :: !Int,
    fixtureManifestPath :: !FilePath,
    fixtureContents :: !(Map FilePath Text)
  }

main :: IO ()
main = do
  let sourceFixtures = map (uncurry sourceFixture) sourceShapes
      workspaceFixtures =
        [ workspaceFixture memberCount aggregateCount transitionsPerAggregate
        | (memberCount, aggregateCount, transitionsPerAggregate) <- workspaceShapes
        ]
  -- Build and force immutable inputs directly before registering benchmarks.
  -- tasty-bench's env accessor is deliberately unnecessary here and would
  -- reintroduce a lazy resource thunk around these already prepared values.
  forceFixtures sourceFixtures workspaceFixtures
  preflightFixtures sourceFixtures workspaceFixtures
  defaultMain (benchmarks sourceFixtures workspaceFixtures)

sourceShapes :: [(Int, Int)]
sourceShapes = [(8, 4), (8, 8), (8, 16), (8, 32)]

workspaceShapes :: [(Int, Int, Int)]
workspaceShapes = [(1, 8, 16), (2, 8, 16), (4, 8, 16), (8, 8, 16)]

forceFixtures :: [SourceFixture] -> [WorkspaceFixture] -> IO ()
forceFixtures sourceFixtures workspaceFixtures = do
  forM_ sourceFixtures $ \SourceFixture {fixtureSource} ->
    evaluate (force fixtureSource)
  forM_ workspaceFixtures $ \WorkspaceFixture {fixtureContents} ->
    evaluate (force fixtureContents)

preflightFixtures :: [SourceFixture] -> [WorkspaceFixture] -> IO ()
preflightFixtures sourceFixtures workspaceFixtures = do
  forM_ sourceFixtures $ \fixture@SourceFixture {fixtureSource} -> do
    _ <- evaluate (parseSurfaceOrFail (sourcePath fixture) fixtureSource)
    _ <- evaluate (parseCompatibilityOrFail (sourcePath fixture) fixtureSource)
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
surfaceBenchmark fixture@SourceFixture {fixtureSource} =
  bench (sourceLabel fixture) $
    whnf (parseSurfaceSource (sourcePath fixture)) fixtureSource

compatibilityBenchmark :: SourceFixture -> Benchmark
compatibilityBenchmark fixture@SourceFixture {fixtureSource} =
  bench (sourceLabel fixture) $
    whnf (parseSource (sourcePath fixture)) fixtureSource

workspaceBenchmark :: WorkspaceFixture -> Benchmark
workspaceBenchmark fixture@WorkspaceFixture {fixtureMemberCount, fixtureAggregateCount, fixtureTotalConstructCount, fixtureContents} =
  bench
    ( "members-"
        <> show fixtureMemberCount
        <> "-aggregates-"
        <> show fixtureAggregateCount
        <> "-transitions-"
        <> show fixtureTotalConstructCount
        <> "-chars-"
        <> show (sum (map T.length (Map.elems fixtureContents)))
    )
    (whnfIO (loadWorkspaceOrFail fixture))

sourceFixture :: Int -> Int -> SourceFixture
sourceFixture fixtureAggregateCount fixtureTransitionsPerAggregate =
  SourceFixture
    { fixtureAggregateCount,
      fixtureConstructCount = fixtureAggregateCount * fixtureTransitionsPerAggregate,
      fixtureSource = nestedSpecification "parser-bench" 0 fixtureAggregateCount fixtureTransitionsPerAggregate
    }

sourceLabel :: SourceFixture -> String
sourceLabel SourceFixture {fixtureAggregateCount, fixtureConstructCount, fixtureSource} =
  "aggregates-"
    <> show fixtureAggregateCount
    <> "-transitions-"
    <> show fixtureConstructCount
    <> "-chars-"
    <> show (T.length fixtureSource)

sourcePath :: SourceFixture -> FilePath
sourcePath SourceFixture {fixtureConstructCount} = "parser-bench-" <> show fixtureConstructCount <> ".keiro"

nestedSpecification :: Text -> Int -> Int -> Int -> Text
nestedSpecification contextName firstAggregate aggregateCount transitionsPerAggregate =
  T.unlines
    [ "language keiro-dsl 4",
      "context " <> contextName
    ]
    <> T.concat
      [ aggregateDefinition index transitionsPerAggregate
      | index <- [firstAggregate .. firstAggregate + aggregateCount - 1]
      ]

aggregateDefinition :: Int -> Int -> Text
aggregateDefinition index transitionCount =
  T.unlines
    ( [ "",
        "aggregate " <> aggregateName,
        "  regs",
        "    count Natural = 0",
        "    limit Natural = 100",
        "    label Text = \"ready # literal\"",
        "  states " <> T.unwords [stateName stateIndex <> terminalMarker stateIndex | stateIndex <- [0 .. transitionCount]]
      ]
        <> concatMap commandAndEvent transitionIndexes
        <> concatMap transition transitionIndexes
    )
  where
    aggregateName = "BenchAggregate" <> paddedDecimal index
    transitionIndexes = [0 .. transitionCount - 1]
    stateName stateIndex = "State" <> paddedDecimal stateIndex
    terminalMarker stateIndex
      | stateIndex == transitionCount = "!"
      | otherwise = ""
    commandName transitionIndex = "Advance" <> paddedDecimal transitionIndex
    eventName transitionIndex = "Advanced" <> paddedDecimal transitionIndex
    commandAndEvent transitionIndex =
      [ "  command " <> commandName transitionIndex <> " { amount:Natural delta:Natural note:Text }",
        "  event " <> eventName transitionIndex <> " = fields(" <> commandName transitionIndex <> ")"
      ]
    transition transitionIndex =
      [ "  " <> stateName transitionIndex <> " -- " <> commandName transitionIndex <> " -->",
        "    guard cmd.amount + cmd.delta > reg.count && reg.limit >= cmd.amount",
        "    write count := reg.count + cmd.amount",
        "    write limit := reg.limit + cmd.delta",
        "    write label := cmd.note",
        "    emit " <> eventName transitionIndex,
        "    goto " <> stateName (transitionIndex + 1)
      ]

paddedDecimal :: Int -> Text
paddedDecimal number =
  let rendered = T.pack (show number)
   in T.replicate (6 - T.length rendered) "0" <> rendered

workspaceFixture :: Int -> Int -> Int -> WorkspaceFixture
workspaceFixture memberCount aggregateCount transitionsPerAggregate
  | aggregateCount `mod` memberCount /= 0 =
      error "workspace fixture aggregate count must divide evenly across members"
  | otherwise =
      WorkspaceFixture
        { fixtureMemberCount = memberCount,
          fixtureAggregateCount = aggregateCount,
          fixtureTotalConstructCount = aggregateCount * transitionsPerAggregate,
          fixtureManifestPath = manifestPath,
          fixtureContents = Map.insert manifestPath manifest members
        }
  where
    manifestPath = "service.keiro-workspace"
    aggregatesPerMember = aggregateCount `div` memberCount
    memberRows =
      [ ( memberPath memberIndex,
          nestedSpecification
            "parser-bench-workspace"
            (memberIndex * aggregatesPerMember)
            aggregatesPerMember
            transitionsPerAggregate
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
