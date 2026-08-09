{-# LANGUAGE NoFieldSelectors #-}

module Keiro.Dsl.FrontendSurface (frontendSurfaceSpec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend
import Keiro.Dsl.FrontendCompatibility
  ( CompatibilityManifest (..),
    SourceExpectation (..),
    readCompatibilityManifest,
    readRepoText,
  )
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser (parseSource, parseSourceDocument)
import Keiro.Dsl.Source
import Keiro.Dsl.SourceIndex
import Keiro.Dsl.Syntax
import Test.Hspec hiding (Spec)
import Prelude hiding (span)

frontendSurfaceSpec :: SpecWith ()
frontendSurfaceSpec = do
  describe "source spans" $ do
    it "rejects invalid points and backwards spans" $ do
      mkSourcePoint (-1) 1 1 `shouldBe` Nothing
      mkSourcePoint 0 0 1 `shouldBe` Nothing
      mkSourcePoint 0 1 0 `shouldBe` Nothing
      let start = SourcePoint {offset = 3, line = 2, column = 2}
          end = SourcePoint {offset = 2, line = 2, column = 1}
      mkSourceSpan "invalid.keiro" start end `shouldBe` Nothing

    it "locates Unicode-prefixed syntax and excludes trailing comments" $ do
      let leading = "# λ🙂\n"
          preambleText = "language keiro-dsl 2"
          contextText = "context spans"
          idText = "id ThingId prefix=thing"
          source = leading <> preambleText <> "\n" <> contextText <> "\n" <> idText <> "   # trailing\n\n"
      parsed <- parseSurfaceRight "unicode.keiro" source
      case parsed of
        SurfaceSource
          { preamble = Just (Located {span = preambleSpan}),
            spec =
              Located
                { span = bodySpan,
                  value =
                    SurfaceSpec
                      { context = Located {span = contextSpan},
                        items = [Located {span = idSpan, value = SurfaceId _}]
                      }
                }
          } -> do
            spanPoints preambleSpan `shouldBe` (pointAfter leading, pointAfter (leading <> preambleText))
            spanPoints contextSpan
              `shouldBe` ( pointAfter (leading <> preambleText <> "\n"),
                           pointAfter (leading <> preambleText <> "\n" <> contextText)
                         )
            spanPoints idSpan
              `shouldBe` ( pointAfter (leading <> preambleText <> "\n" <> contextText <> "\n"),
                           pointAfter (leading <> preambleText <> "\n" <> contextText <> "\n" <> idText)
                         )
            spanPoints bodySpan `shouldBe` (fst (spanPoints contextSpan), snd (spanPoints idSpan))
        other -> expectationFailure ("unexpected surface shape: " <> show other)

    it "covers a complete multi-line aggregate and an empty document body" $ do
      aggregateSource <- readRepoText "keiro-dsl/test/fixtures/aggregate-scalars.keiro"
      aggregateSurface <- parseSurfaceRight "aggregate-scalars.keiro" aggregateSource
      let aggregateStart = T.length (fst (T.breakOn "aggregate ScalarLedger" aggregateSource))
          aggregateEnd = T.length (T.stripEnd aggregateSource)
      case aggregateSurface of
        SurfaceSource
          { spec =
              Located
                { value =
                    SurfaceSpec
                      { items = [Located {span = aggregateSpan, value = SurfaceNode (NAggregate _)}],
                        elements
                      }
                }
          } -> do
            spanOffsets aggregateSpan `shouldBe` (aggregateStart, aggregateEnd)
            let fields = [(name, spanText aggregateSource fieldSpan) | Located {span = fieldSpan, value = SurfaceField name} <- elements]
                expressions = [spanText aggregateSource expressionSpan | Located {span = expressionSpan, value = SurfaceExpression _} <- elements]
            fields `shouldContain` [("observedAt", "observedAt:Time")]
            expressions `shouldContain` ["cmd.observedAt >= reg.observedAt && cmd.revision >= reg.revision"]
        other -> expectationFailure ("unexpected aggregate surface shape: " <> show other)
      emptySurface <- parseSurfaceRight "empty.keiro" "context empty   # trailing\n"
      case emptySurface of
        SurfaceSource
          { spec =
              Located
                { span = bodySpan,
                  value = SurfaceSpec {context = Located {span = contextSpan}, items = []}
                }
          } -> bodySpan `shouldBe` contextSpan
        other -> expectationFailure ("unexpected empty surface shape: " <> show other)

    it "owns exact terminal-state and complete generated, replay-only, Hole, and adjacent transition syntax" $ do
      let source =
            T.unlines
              [ "language keiro-dsl 2",
                "context semantic-source-index",
                "aggregate Journey",
                "  regs",
                "    count Natural = 0",
                "  states Empty Active Closed!",
                "  command Start { amount:Natural }",
                "  event Started = fields(Start)",
                "  Empty -- Start -->",
                "    guard cmd.amount > 0",
                "    write count := cmd.amount",
                "    emit Started",
                "    goto Active",
                "  replay-only Empty -- Start -->",
                "    implementation hole",
                "    goto Active",
                "  Active -- Start --> implementation hole; goto Closed",
                "  Closed -- Start --> implementation hole; goto Closed # trailing"
              ]
      surface <- parseSurfaceRight "semantic-source-index.keiro" source
      let SurfaceSource {spec = Located {value = SurfaceSpec {elements}}} = surface
          stateSpans =
            [ (aggregateName, stateName, spanText source stateSpan)
            | Located {span = stateSpan, value = SurfaceAggregateState aggregateName stateName} <- elements
            ]
          transitionSpans =
            [ (aggregateName, ordinal, spanText source transitionSpan)
            | Located {span = transitionSpan, value = SurfaceAggregateTransition aggregateName ordinal} <- elements
            ]
      stateSpans
        `shouldBe` [ ("Journey", "Empty", "Empty"),
                     ("Journey", "Active", "Active"),
                     ("Journey", "Closed", "Closed!")
                   ]
      transitionSpans
        `shouldBe` [ ( "Journey",
                       0,
                       "Empty -- Start -->\n    guard cmd.amount > 0\n    write count := cmd.amount\n    emit Started\n    goto Active"
                     ),
                     ( "Journey",
                       1,
                       "replay-only Empty -- Start -->\n    implementation hole\n    goto Active"
                     ),
                     ("Journey", 2, "Active -- Start --> implementation hole; goto Closed"),
                     ("Journey", 3, "Closed -- Start --> implementation hole; goto Closed")
                   ]
      document <- case parseSourceDocument "semantic-source-index.keiro" source of
        Left failure -> expectationFailure (show failure) >> fail "unreachable"
        Right value -> pure value
      let ParsedSourceDocument {documentParsedSource, documentSourceIndex} = document
      parseSource "semantic-source-index.keiro" source `shouldBe` Right documentParsedSource
      length (semanticSourceEntries documentSourceIndex) `shouldBe` 7
      case lookupSourceSpan (AggregateStateSubject "Journey" "Closed") documentSourceIndex of
        Just (ExactSourcePosition, SourceSpan {source = spanSource, start = SourcePoint {line, column}}) -> do
          spanSource `shouldBe` "semantic-source-index.keiro"
          (line, column) `shouldBe` (6, 23)
        other -> expectationFailure ("expected exact terminal-state location, got " <> show other)
      case lookupSourceSpan (AggregateTransitionSubject "Journey" (TransitionOrdinal 1)) documentSourceIndex of
        Just (ExactSourcePosition, SourceSpan {start = SourcePoint {line, column}}) ->
          (line, column) `shouldBe` (14, 3)
        other -> expectationFailure ("expected exact replay-only transition location, got " <> show other)

    it "refuses incomplete and duplicate semantic source indices" $ do
      let subject = AggregateStateSubject "Journey" "Empty"
          point = SourcePoint {offset = 0, line = 1, column = 1}
          sourceSpan = SourceSpan {source = "index.keiro", start = point, end = point}
      exactSemanticSourceIndex "index.keiro" [subject] []
        `shouldSatisfy` isFailure MissingSourceSubject
      exactSemanticSourceIndex "index.keiro" [subject] [(subject, sourceSpan), (subject, sourceSpan)]
        `shouldSatisfy` isFailure DuplicateSourceSubject

  describe "surface lowering" $ do
    it "preserves top-level source order before grouping the semantic graph" $ do
      let source = T.unlines ["context ordering", "id FirstId prefix=first", "enum Mode { On=on Off=off }", "id SecondId prefix=second"]
      surface <- parseSurfaceRight "ordering.keiro" source
      case surface of
        SurfaceSource {spec = Located {value = SurfaceSpec {items}}} ->
          map topItemKind items `shouldBe` ["id", "enum", "id"]
      lowered <- lowerRight surface
      map idName (specIds (parsedSpec lowered)) `shouldBe` ["FirstId", "SecondId"]
      map enumName (specEnums (parsedSpec lowered)) `shouldBe` ["Mode"]

    it "refuses surface evidence attributed to another source" $ do
      surface <- parseSurfaceRight "owned.keiro" "context owned\n"
      let corrupted = case surface of
            SurfaceSource {source, language, preamble, spec = Located {span = SourceSpan {start, end}, value}} ->
              SurfaceSource
                { source,
                  language,
                  preamble,
                  spec = Located {span = SourceSpan {source = "other.keiro", start, end}, value}
                }
      case lowerSurfaceSource corrupted of
        Left LoweringFailure {code = SourceNameMismatch} -> pure ()
        other -> expectationFailure ("expected source ownership failure, got " <> show other)

    it "lowers every accepted 0.7 fixture to the compatibility result" $ do
      manifest <- readCompatibilityManifest
      forM_ [row | row <- manifestSources manifest, sourceResult row == "accept"] $ \row -> do
        source <- readRepoText (sourcePath row)
        surface <- parseSurfaceRight (sourcePath row) source
        lowered <- lowerRight surface
        parseSource (sourcePath row) source `shouldBe` Right lowered

  describe "parser module boundaries" $ do
    it "keeps the public parser facade free of Megaparsec and grammar productions" $ do
      facade <- readRepoText "keiro-dsl/src/Keiro/Dsl/Parser.hs"
      facade `shouldNotSatisfy` T.isInfixOf "Text.Megaparsec"
      facade `shouldNotSatisfy` T.isInfixOf "keyword ::"
      facade `shouldNotSatisfy` T.isInfixOf "pAggregate ::"
      facade `shouldNotSatisfy` T.isInfixOf "    parseSurfaceSource,"

    it "keeps internal grammar modules from importing the public facade" $
      forM_ parserModulePaths $ \path -> do
        source <- readRepoText path
        filter isFacadeImport (T.lines source) `shouldBe` []

    it "keeps source, syntax, and semantic graph modules Megaparsec-free" $
      forM_ semanticModulePaths $ \path -> do
        source <- readRepoText path
        source `shouldNotSatisfy` T.isInfixOf "Text.Megaparsec"

    it "keeps semantic consumers independent of surface syntax and internal parsers" $
      forM_ semanticConsumerPaths $ \path -> do
        source <- readRepoText path
        source `shouldNotSatisfy` T.isInfixOf "import Keiro.Dsl.Syntax"
        source `shouldNotSatisfy` T.isInfixOf "import Keiro.Dsl.Parser."

    it "keeps workspace loading and parser internals on opposite sides of the facade" $ do
      workspace <- readRepoText "keiro-dsl/src/Keiro/Dsl/Workspace.hs"
      workspace `shouldNotSatisfy` T.isInfixOf "import Keiro.Dsl.Parser."
      forM_ parserModulePaths $ \path -> do
        source <- readRepoText path
        forM_ forbiddenParserDependencies $ \dependency ->
          source `shouldNotSatisfy` T.isInfixOf ("import Keiro.Dsl." <> dependency)

parseSurfaceRight :: FilePath -> Text -> IO SurfaceSource
parseSurfaceRight sourceName source =
  case parseSurfaceSource sourceName source of
    Left failure -> expectationFailure (T.unpack (renderFrontendFailure failure)) >> fail "unreachable"
    Right value -> pure value

lowerRight :: SurfaceSource -> IO ParsedSource
lowerRight source =
  case lowerSurfaceSource source of
    Left failure -> expectationFailure (T.unpack (renderLoweringFailure failure)) >> fail "unreachable"
    Right value -> pure value

spanOffsets :: SourceSpan -> (Int, Int)
spanOffsets SourceSpan {start = SourcePoint {offset = startOffset}, end = SourcePoint {offset = endOffset}} =
  (startOffset, endOffset)

spanPoints :: SourceSpan -> ((Int, Int, Int), (Int, Int, Int))
spanPoints SourceSpan {start, end} = (pointTuple start, pointTuple end)

pointTuple :: SourcePoint -> (Int, Int, Int)
pointTuple SourcePoint {offset, line, column} = (offset, line, column)

pointAfter :: Text -> (Int, Int, Int)
pointAfter prefix =
  ( T.length prefix,
    length linesFound,
    T.length (last linesFound) + 1
  )
  where
    linesFound = T.splitOn "\n" prefix

topItemKind :: Located SurfaceTopItem -> Text
topItemKind Located {value} = case value of
  SurfaceId _ -> "id"
  SurfaceEnum _ -> "enum"
  SurfaceRule _ -> "rule"
  SurfaceNominalScalar _ -> "nominal"
  SurfaceMapped _ -> "mapped"
  SurfaceNode _ -> "node"

spanText :: Text -> SourceSpan -> Text
spanText source SourceSpan {start = SourcePoint {offset = startOffset}, end = SourcePoint {offset = endOffset}} =
  T.take (endOffset - startOffset) (T.drop startOffset source)

isFailure :: SourceIndexFailureCode -> Either SourceIndexFailure value -> Bool
isFailure expected = \case
  Left SourceIndexFailure {failureCode} -> failureCode == expected
  Right _ -> False

isFacadeImport :: Text -> Bool
isFacadeImport line =
  let stripped = T.strip line
   in stripped == "import Keiro.Dsl.Parser"
        || "import Keiro.Dsl.Parser " `T.isPrefixOf` stripped

parserModulePaths :: [FilePath]
parserModulePaths =
  map
    ("keiro-dsl/src/Keiro/Dsl/Parser/" <>)
    [ "Aggregate.hs",
      "Coordination.hs",
      "Core.hs",
      "Declaration.hs",
      "Document.hs",
      "Expression.hs",
      "Integration.hs",
      "Mapped.hs",
      "Preamble.hs",
      "Queue.hs",
      "ReadModel.hs",
      "Workflow.hs"
    ]

semanticModulePaths :: [FilePath]
semanticModulePaths =
  map
    ("keiro-dsl/src/Keiro/Dsl/" <>)
    [ "Source.hs",
      "SourceIndex.hs",
      "Syntax.hs",
      "Grammar.hs",
      "Validate.hs"
    ]

semanticConsumerPaths :: [FilePath]
semanticConsumerPaths =
  map
    ("keiro-dsl/src/Keiro/Dsl/" <>)
    [ "Grammar.hs",
      "Validate.hs",
      "SemanticContract.hs",
      "Scaffold.hs",
      "Diff.hs",
      "FoldFingerprint.hs",
      "ReplayImpact.hs"
    ]

forbiddenParserDependencies :: [Text]
forbiddenParserDependencies =
  [ "Workspace",
    "Validate",
    "Scaffold",
    "Diff",
    "FoldFingerprint",
    "ReplayImpact"
  ]
